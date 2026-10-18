import AppKit
import CoreImage
import ImageIO
import Vision

/// 纸偶桌宠（puppet）：一张或几张图片 → 会动的桌宠。见 docs/pet-puppet-format.md。
///
/// - 图片处理全部在本机：Vision 抠图（macOS 14+ 任意主体，12+ 人像）+ 人脸定位 → 骨架点；
/// - 形象包是声明式数据（pet.json + PNG + 可选动作），运行时 `puppet/pet-puppet.js` 渲染；
/// - `.lianapet` = 形象包目录的 zip，用于分享与社区分发。

// MARK: - 数据模型

/// 骨架点（图片归一化坐标，y 自下而上）：脖子转轴、头部范围 [x0, y0, x1, y1]、脚底线。
struct PuppetRig: Equatable {
    var neck = CGPoint(x: 0.5, y: 0.66)
    var head = CGRect(x: 0.22, y: 0.64, width: 0.56, height: 0.36)
    var ground: CGFloat = 0

    var json: [String: Any] {
        [
            "neck": [round3(neck.x), round3(neck.y)],
            "head": [round3(head.minX), round3(head.minY), round3(head.maxX), round3(head.maxY)],
            "ground": round3(ground),
        ]
    }

    init() {}

    init(json: [String: Any]?) {
        guard let json else { return }
        if let n = json["neck"] as? [Double], n.count == 2 {
            neck = CGPoint(x: n[0], y: n[1])
        }
        if let h = json["head"] as? [Double], h.count == 4 {
            head = CGRect(x: h[0], y: h[1], width: max(0.05, h[2] - h[0]), height: max(0.05, h[3] - h[1]))
        }
        if let g = json["ground"] as? Double { ground = g }
    }

    private func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
}

/// 角色状态（图片的用途）。顺序即添加图片时自动分配的顺序。
enum PuppetRole: String, CaseIterable, Identifiable {
    case idle, happy, typing, sleep, surprised, blink, shy, sad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return "平时（必需）"
        case .happy: return "开心"
        case .typing: return "打字"
        case .sleep: return "睡觉"
        case .surprised: return "惊讶"
        case .blink: return "闭眼（用于眨眼）"
        case .shy: return "害羞"
        case .sad: return "委屈"
        }
    }

    /// 文件名关键词 → 角色（AI 生成的一组图常按表情命名）
    static func guess(from filename: String) -> PuppetRole? {
        let name = filename.lowercased()
        let hints: [(PuppetRole, [String])] = [
            (.blink, ["blink", "闭眼", "eyes_closed", "closed"]),
            (.sleep, ["sleep", "睡", "困"]),
            (.happy, ["happy", "smile", "开心", "笑"]),
            (.typing, ["typing", "type", "打字", "work"]),
            (.surprised, ["surprise", "shock", "惊"]),
            (.shy, ["shy", "blush", "害羞"]),
            (.sad, ["sad", "cry", "angry", "委屈", "哭", "生气"]),
            (.idle, ["idle", "normal", "default", "平时", "站"]),
        ]
        return hints.first { _, keys in keys.contains { name.contains($0) } }?.0
    }
}

struct PuppetImage: Identifiable {
    let id = UUID()
    var role: PuppetRole
    var png: Data
    var pixelSize: CGSize
    var rig: PuppetRig

    var aspect: CGFloat { pixelSize.width / max(1, pixelSize.height) }
}

/// 形象工坊里编辑中的形象包。
struct PuppetDraft {
    var packId: String?
    var name = "我的桌宠"
    var faces = "front"           // front | left | right
    var shareable = false         // 用户声明「原创或已获授权，可分享」
    var images: [PuppetImage] = []
}

enum PuppetError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

// MARK: - 图片处理（本机）

enum PuppetBuilder {
    /// 输出图最大高度：够 3x 屏幕下 300pt 的桌宠用，形象包不至于太大
    private static let maxHeight: CGFloat = 1024
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 处理一组图片：抠图 → 同尺寸原图按并集裁切（保证表情切换对齐）→ 缩放 → 定位骨架。
    static func process(_ urls: [URL]) throws -> [(name: String, image: PuppetImage)] {
        var cutouts: [(name: String, image: CGImage)] = []
        for url in urls {
            guard let source = loadImage(url) else {
                throw PuppetError.message("读不了这张图：\(url.lastPathComponent)")
            }
            guard let cut = cutout(source) else {
                throw PuppetError.message("没能从「\(url.lastPathComponent)」里抠出主体：换一张主体清晰、背景简单的图，或直接用透明背景 PNG")
            }
            cutouts.append((url.deletingPathExtension().lastPathComponent, cut))
        }
        // 同一组图（同一次 AI 生成 / 连拍：尺寸相同且主体位置高度重合）用同一个裁切框，
        // 表情切换、眨眼时不跳动；同一部手机拍的不同照片尺寸也相同，但主体位置不同，不会被并组
        var groups: [(size: CGSize, box: CGRect)] = []
        var groupOf: [Int] = []
        for (_, image) in cutouts {
            guard let box = alphaBounds(image) else {
                throw PuppetError.message("抠图结果是空的：请换一张主体更明显的图")
            }
            let size = CGSize(width: image.width, height: image.height)
            if let g = groups.firstIndex(where: { $0.size == size && overlap($0.box, box) > 0.75 }) {
                groups[g].box = groups[g].box.union(box)
                groupOf.append(g)
            } else {
                groups.append((size, box))
                groupOf.append(groups.count - 1)
            }
        }
        return try cutouts.enumerated().map { index, item in
            let box = groups[groupOf[index]].box.integral
            guard let cropped = item.image.cropping(to: box) else {
                throw PuppetError.message("裁切失败：\(item.name)")
            }
            let scaled = downscale(cropped)
            guard let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
                throw PuppetError.message("编码失败：\(item.name)")
            }
            let image = PuppetImage(
                role: .idle,
                png: png,
                pixelSize: CGSize(width: scaled.width, height: scaled.height),
                rig: detectRig(scaled)
            )
            return (item.name, image)
        }
    }

    /// 交并比（IoU）。
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let union = a.area + b.area - inter.area
        return union > 0 ? inter.area / union : 0
    }

    /// 读图并按 EXIF 方向摆正，长边限制在 2048 以内。
    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 已经是透明背景（≥3% 像素透明）就直接用；否则 Vision 抠图。
    private static func cutout(_ image: CGImage) -> CGImage? {
        if transparentRatio(image) > 0.03 { return image }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if #available(macOS 14.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([request])) != nil,
               let observation = request.results?.first,
               let buffer = try? observation.generateMaskedImage(
                   ofInstances: observation.allInstances,
                   from: handler,
                   croppedToInstancesExtent: false
               ) {
                let ci = CIImage(cvPixelBuffer: buffer)
                if let cg = ciContext.createCGImage(ci, from: ci.extent) { return cg }
            }
        }
        // macOS 13 / 非人物主体识别失败：退回人像分割
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([person])) != nil,
              let mask = person.results?.first?.pixelBuffer else { return nil }
        let input = CIImage(cgImage: image)
        var maskImage = CIImage(cvPixelBuffer: mask)
        maskImage = maskImage.transformed(by: CGAffineTransform(
            scaleX: input.extent.width / maskImage.extent.width,
            y: input.extent.height / maskImage.extent.height
        ))
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(input, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return nil }
        let result = ciContext.createCGImage(output, from: input.extent)
        // 人像分割在没有人的图上会给出全空蒙版
        if let result, alphaBounds(result) != nil { return result }
        return nil
    }

    /// RGBA8 像素（预乘、行自上而下）。
    private static func rgba(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    private static func transparentRatio(_ image: CGImage) -> Double {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let px = rgba(image) else { return 0 }
        var clear = 0
        let total = px.width * px.height
        var i = 3
        while i < px.data.count {
            if px.data[i] < 16 { clear += 1 }
            i += 16    // 每 4 个像素采样一次
        }
        return Double(clear) / Double(max(1, total / 4))
    }

    /// 不透明像素的外接框（CGImage 坐标：原点左上）。
    private static func alphaBounds(_ image: CGImage) -> CGRect? {
        guard let px = rgba(image) else { return nil }
        var minX = px.width, minY = px.height, maxX = -1, maxY = -1
        for y in 0..<px.height {
            let row = y * px.width * 4
            for x in 0..<px.width where px.data[row + x * 4 + 3] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func downscale(_ image: CGImage) -> CGImage {
        let h = CGFloat(image.height)
        guard h > maxHeight else { return image }
        let scale = maxHeight / h
        let w = Int((CGFloat(image.width) * scale).rounded()), nh = Int(maxHeight)
        guard let context = CGContext(
            data: nil, width: w, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: nh))
        return context.makeImage() ?? image
    }

    /// 骨架点：真人照片用人脸框推算头部与脖子；识别不到脸（卡通/动物）按常见比例给默认值，工坊里可拖动修正。
    static func detectRig(_ image: CGImage) -> PuppetRig {
        var rig = PuppetRig()
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area })?.boundingBox
        else {
            // 头身比较大的卡通形象：头部约占上 1/3
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let neckY: CGFloat = aspect > 0.75 ? 0.58 : 0.66
            rig.neck = CGPoint(x: 0.5, y: neckY)
            rig.head = CGRect(x: 0.2, y: neckY - 0.02, width: 0.6, height: 1 - neckY + 0.02)
            return rig
        }
        // Vision 的 boundingBox 本来就是归一化、原点左下
        let x0 = max(0, face.minX - face.width * 0.35)
        let x1 = min(1, face.maxX + face.width * 0.35)
        let y0 = max(0, face.minY - face.height * 0.12)
        let y1 = min(1, face.maxY + face.height * 0.55)
        rig.head = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        rig.neck = CGPoint(x: face.midX, y: max(0.05, face.minY - face.height * 0.1))
        return rig
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

// MARK: - 形象包读写 / 导入导出

enum PuppetPackStore {
    static let fileExtension = "lianapet"
    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "json"]
    private static let maxImportBytes = 40 * 1024 * 1024

    static func isPuppet(packId: String) -> Bool {
        let pet = PluginStore.pluginsDir.appendingPathComponent(packId).appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: pet),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["renderer"] as? String == "puppet"
    }

    static func newPackId() -> String {
        "puppet-" + UUID().uuidString.lowercased().prefix(8)
    }

    /// 把草稿写成形象包目录（保留包里已有的自定义动作 / 触发 / 台词）。
    static func write(_ draft: PuppetDraft, to dir: URL, id: String) throws {
        guard let idle = draft.images.first(where: { $0.role == .idle }) else {
            throw PuppetError.message("至少需要一张「平时」图片")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 清掉旧图（换图/删图后不留垃圾）
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension.lowercased() == "png" {
                try? fm.removeItem(at: item)
            }
        }
        var imageSpecs: [String: Any] = [:]
        for image in draft.images {
            let file = "\(image.role.rawValue).png"
            try image.png.write(to: dir.appendingPathComponent(file))
            imageSpecs[image.role.rawValue] = ["src": file, "rig": image.rig.json]
        }

        // 已有 pet.json 的 puppet 段（社区包可能带自定义 actions / triggers / lines）原样保留
        var puppet: [String: Any] = [:]
        if let data = try? Data(contentsOf: dir.appendingPathComponent("pet.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = json["puppet"] as? [String: Any] {
            puppet = existing
        }
        puppet["format"] = 1
        puppet["faces"] = draft.faces
        puppet["rights"] = draft.shareable ? "shareable" : "personal"
        puppet["images"] = imageSpecs

        // 窗口：高 300，宽按「平时」图比例（留出左右摇摆的余量）
        let height = 300.0
        let width = min(380, max(150, (height * 0.86 * Double(idle.aspect)).rounded() + 48))
        let pet: [String: Any] = [
            "renderer": "puppet",
            "width": width,
            "height": height,
            "follow_cursor": false,
            "typing_bounce": true,
            "commit_particles": false,   // 庆祝特效由动作自己声明
            "puppet": puppet,
        ]
        let plugin: [String: Any] = [
            "id": id,
            "name": draft.name.isEmpty ? "我的桌宠" : draft.name,
            "version": "1.0.0",
            "kind": "pet",
            "authors": ["user"],
            "description": "用图片做的纸偶桌宠",
            "license": draft.shareable ? "user-declared-shareable" : "personal-use-only",
            "permissions": [String](),
        ]
        try jsonData(pet).write(to: dir.appendingPathComponent("pet.json"))
        try jsonData(plugin).write(to: dir.appendingPathComponent("plugin.json"))
    }

    /// 保存为已安装形象包，返回包 id。
    @discardableResult
    static func save(_ draft: PuppetDraft) throws -> String {
        let id = draft.packId ?? newPackId()
        let dir = PluginStore.pluginsDir.appendingPathComponent(id, isDirectory: true)
        try write(draft, to: dir, id: id)
        guard PetWindowController.availablePets().contains(where: { $0.id == id }) else {
            let reason = PluginStore.scan().errors.first { $0.dir.hasSuffix(id) }?.error ?? "未知原因"
            throw PuppetError.message("形象包校验未通过：\(reason)")
        }
        return id
    }

    /// 读回已安装的纸偶形象包（形象工坊「编辑当前形象」）。
    static func load(packId: String) -> PuppetDraft? {
        let dir = PluginStore.pluginsDir.appendingPathComponent(packId, isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("pet.json")),
              let pet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              pet["renderer"] as? String == "puppet",
              let puppet = pet["puppet"] as? [String: Any],
              let specs = puppet["images"] as? [String: Any] else { return nil }
        var draft = PuppetDraft(packId: packId)
        draft.faces = puppet["faces"] as? String ?? "front"
        draft.shareable = puppet["rights"] as? String == "shareable"
        if let pluginData = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
           let plugin = try? JSONSerialization.jsonObject(with: pluginData) as? [String: Any],
           let name = plugin["name"] as? String {
            draft.name = name
        }
        for role in PuppetRole.allCases {
            guard let spec = specs[role.rawValue] else { continue }
            let file = (spec as? String) ?? ((spec as? [String: Any])?["src"] as? String) ?? ""
            guard !file.isEmpty, !file.contains(".."),
                  let png = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let rep = NSBitmapImageRep(data: png) else { continue }
            draft.images.append(PuppetImage(
                role: role,
                png: png,
                pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh),
                rig: PuppetRig(json: (spec as? [String: Any])?["rig"] as? [String: Any])
            ))
        }
        return draft.images.isEmpty ? nil : draft
    }

    /// 导出 `.lianapet`（zip）。仅限用户声明了可分享的形象。
    static func export(packId: String, to url: URL) throws {
        guard let draft = load(packId: packId) else {
            throw PuppetError.message("只能导出纸偶形象")
        }
        guard draft.shareable else {
            throw PuppetError.message("这个形象标记为「仅个人使用」：确认图片是原创或已获授权后，在形象工坊勾选「可以分享」再导出")
        }
        let dir = PluginStore.pluginsDir.appendingPathComponent(packId, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try runDitto(["-c", "-k", "--norsrc", dir.path, url.path])
    }

    /// 导入 `.lianapet`：只收白名单类型的普通文件，拒绝符号链接与越界路径。返回包 id。
    @discardableResult
    static func importPack(from url: URL) throws -> String {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("liana-puppet-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try runDitto(["-x", "-k", url.path, temp.path])

        // pet.json 可能在根目录，也可能多包了一层文件夹
        var root = temp
        if !fm.fileExists(atPath: root.appendingPathComponent("pet.json").path),
           let sub = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.isDirectoryKey])
               .first(where: { $0.hasDirectoryPath && fm.fileExists(atPath: $0.appendingPathComponent("pet.json").path) }) {
            root = sub
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("pet.json")),
              let pet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              pet["renderer"] as? String == "puppet" else {
            throw PuppetError.message("不是松萝纸偶形象包（缺少 renderer=puppet 的 pet.json）")
        }

        var files: [(URL, String)] = []
        var total = 0
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
            throw PuppetError.message("读取形象包失败")
        }
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw PuppetError.message("形象包里不允许符号链接")
            }
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else {
                throw PuppetError.message("形象包里有越界路径")
            }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if relative.hasPrefix("__MACOSX") || file.lastPathComponent.hasPrefix(".") { continue }
            guard allowedExtensions.contains(file.pathExtension.lowercased()) else {
                throw PuppetError.message("形象包里有不支持的文件：\(relative)（只允许图片和 JSON）")
            }
            total += values.fileSize ?? 0
            guard total <= maxImportBytes else {
                throw PuppetError.message("形象包超过 40MB")
            }
            files.append((file, relative))
        }

        // 包 id：沿用 plugin.json 里合法的 id，否则新分配
        var id = newPackId()
        if let pluginData = try? Data(contentsOf: root.appendingPathComponent("plugin.json")),
           let plugin = try? JSONSerialization.jsonObject(with: pluginData) as? [String: Any],
           let declared = plugin["id"] as? String, declared.hasPrefix("puppet-"), isValidId(declared) {
            // 只认 puppet- 前缀：导入包不能覆盖内置或其他类型的形象包
            id = declared
        }
        let dest = PluginStore.pluginsDir.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: dest)
        for (file, relative) in files {
            let target = dest.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
        // plugin.json 缺失或 id 不一致：按导入结果重写，保证内核扫描能认出来
        if var draft = load(packId: id) {
            draft.packId = id
            if let pluginData = try? Data(contentsOf: dest.appendingPathComponent("plugin.json")),
               let plugin = try? JSONSerialization.jsonObject(with: pluginData) as? [String: Any],
               plugin["id"] as? String == id {
                // 原样保留作者信息
            } else {
                try write(draft, to: dest, id: id)
            }
        } else {
            try? fm.removeItem(at: dest)
            throw PuppetError.message("形象包里没有可用的图片")
        }
        guard PetWindowController.availablePets().contains(where: { $0.id == id }) else {
            let reason = PluginStore.scan().errors.first { $0.dir.hasSuffix(id) }?.error ?? "未知原因"
            throw PuppetError.message("形象包校验未通过：\(reason)")
        }
        return id
    }

    private static func isValidId(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.count <= 64 else { return false }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first)
            && id.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func runDitto(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw PuppetError.message("打包/解包失败（ditto 退出码 \(proc.terminationStatus)）")
        }
    }
}

// MARK: - 渲染视图

/// 桌宠纸偶视图：透明 WKWebView + `puppet/pet-puppet.js`（纯 WebGL 网格形变）。
final class PuppetPetView: PetWebView {
    init(frame: NSRect, packPath: String, zoom: Double = 1.0, roam: Bool = false, preview: Bool = false) {
        let root = PetRuntimeStore.ensurePuppet()
        let page = root.appendingPathComponent("pet-puppet.html")
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "pack", value: packPath),
            URLQueryItem(name: "zoom", value: String(zoom)),
            URLQueryItem(name: "roam", value: roam ? "1" : "0"),
            URLQueryItem(name: "preview", value: preview ? "1" : "0"),
        ]
        super.init(frame: frame, pageURL: components?.url ?? page, readRoot: root)
        routesToPet = !preview
    }

    required init?(coder: NSCoder) { nil }
}
