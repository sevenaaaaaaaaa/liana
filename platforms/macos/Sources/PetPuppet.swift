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

/// 骨架点（图片归一化坐标，y 自下而上）：脖子转轴、头部范围 [x0, y0, x1, y1]、脚底线，
/// 以及可选的眼睛 / 嘴巴范围（用来自动生成闭眼图与张嘴图）。
struct PuppetRig: Equatable {
    var neck = CGPoint(x: 0.5, y: 0.66)
    var head = CGRect(x: 0.22, y: 0.64, width: 0.56, height: 0.36)
    var ground: CGFloat = 0
    var eyes: [CGRect] = []
    var mouth: CGRect?

    var json: [String: Any] {
        var out: [String: Any] = [
            "neck": [round3(neck.x), round3(neck.y)],
            "head": box(head),
            "ground": round3(ground),
        ]
        if !eyes.isEmpty { out["eyes"] = eyes.map(box) }
        if let mouth { out["mouth"] = box(mouth) }
        return out
    }

    /// 按头部范围给出眼睛 / 嘴巴的默认位置（识别不到脸时，工坊里手动拖到位）。
    mutating func addDefaultFeatures() {
        let w = head.width, h = head.height
        let eyeW = w * 0.16, eyeH = h * 0.08
        let eyeY = head.minY + h * 0.42
        eyes = [
            CGRect(x: head.minX + w * 0.3 - eyeW / 2, y: eyeY, width: eyeW, height: eyeH),
            CGRect(x: head.minX + w * 0.7 - eyeW / 2, y: eyeY, width: eyeW, height: eyeH),
        ]
        mouth = CGRect(x: head.midX - w * 0.1, y: head.minY + h * 0.2, width: w * 0.2, height: h * 0.07)
    }

    private func box(_ r: CGRect) -> [Double] {
        [round3(r.minX), round3(r.minY), round3(r.maxX), round3(r.maxY)]
    }

    private static func rect(_ any: Any?) -> CGRect? {
        guard let v = any as? [Double], v.count == 4, v[2] > v[0], v[3] > v[1] else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
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
        eyes = ((json["eyes"] as? [Any]) ?? []).compactMap(Self.rect).prefix(2).map { $0 }
        mouth = Self.rect(json["mouth"])
    }

    private func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
}

/// 角色状态（图片的用途）。顺序即添加图片时自动分配的顺序。
enum PuppetRole: String, CaseIterable, Identifiable {
    case idle, happy, typing, sleep, surprised, blink, talk, shy, sad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return "平时（必需）"
        case .happy: return "开心"
        case .typing: return "打字"
        case .sleep: return "睡觉"
        case .surprised: return "惊讶"
        case .blink: return "闭眼（用于眨眼）"
        case .talk: return "张嘴（说话用）"
        case .shy: return "害羞"
        case .sad: return "委屈"
        }
    }

    /// 文件名关键词 → 角色（AI 生成的一组图常按表情命名）
    static func guess(from filename: String) -> PuppetRole? {
        let name = filename.lowercased()
        let hints: [(PuppetRole, [String])] = [
            (.blink, ["blink", "闭眼", "eyes_closed", "closed"]),
            (.talk, ["talk", "speak", "mouth_open", "张嘴", "说话"]),
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

/// 动作编辑器的通道：标题、pet.json 通道名、滑杆范围。
struct PuppetChannel {
    let key: String
    let title: String
    let range: ClosedRange<Double>

    static let all: [PuppetChannel] = [
        PuppetChannel(key: "head.rot", title: "头部转动", range: -0.4...0.4),
        PuppetChannel(key: "head.ty", title: "头部上下", range: -0.05...0.05),
        PuppetChannel(key: "head.tx", title: "头部左右", range: -0.05...0.05),
        PuppetChannel(key: "lean", title: "身体倾斜", range: -0.2...0.2),
        PuppetChannel(key: "root.ty", title: "跳起高度", range: -0.05...0.25),
        PuppetChannel(key: "root.tx", title: "左右移动", range: -0.3...0.3),
        PuppetChannel(key: "root.rot", title: "整体旋转", range: -0.35...0.35),
        PuppetChannel(key: "root.sy", title: "纵向伸缩", range: -0.3...0.3),
        PuppetChannel(key: "root.sx", title: "横向（-2 翻面）", range: -2...0.3),
        PuppetChannel(key: "alpha", title: "透明度", range: -1...0),
    ]
}

struct PuppetKeyframe: Identifiable {
    let id = UUID()
    var t: Double
    var values: [String: Double] = [:]
}

/// 用户自定义的动作（关键帧姿势序列）。只有关键帧轨道的动作能在编辑器里改，
/// 带波形 / 循环 / 溜达的动作原样保留在 `PuppetDraft.extraActions`。
struct PuppetActionDraft: Identifiable {
    var id: String
    var name: String
    var image = ""                // 动作期间的表情（"" = 不换）
    var effect = ""               // "" / hearts / sparks
    var say = ""                  // 台词，用 / 分隔
    var keyframes: [PuppetKeyframe] = [PuppetKeyframe(t: 0)]
    var returnToRest = true

    /// 写进 pet.json 的动作对象。
    var json: [String: Any] {
        var frames = keyframes.sorted { $0.t < $1.t }
        if frames.first.map({ $0.t > 0.001 }) ?? true {
            frames.insert(PuppetKeyframe(t: 0), at: 0)          // 从原位开始
        }
        let used = PuppetChannel.all.map(\.key).filter { key in
            frames.contains { abs($0.values[key] ?? 0) > 0.0005 }
        }
        if returnToRest, let last = frames.last, used.contains(where: { abs(last.values[$0] ?? 0) > 0.0005 }) {
            frames.append(PuppetKeyframe(t: last.t + 0.25))   // 结束时回到原位
        }
        var tracks: [String: Any] = [:]
        for key in used {
            tracks[key] = frames.map { [round3($0.t), round3($0.values[key] ?? 0)] }
        }
        var out: [String: Any] = [
            "name": name.isEmpty ? id : name,
            "duration": round3(max(0.1, frames.last?.t ?? 0.5)),
            "tracks": tracks,
        ]
        if !image.isEmpty { out["image"] = image }
        if !effect.isEmpty { out["effect"] = effect }
        let lines = say.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty { out["say"] = lines }
        return out
    }

    /// 从 pet.json 动作对象读回；含波形 / 循环 / 溜达的返回 nil（编辑器表达不了）。
    init?(id: String, json: [String: Any]) {
        guard json["loop"] as? Bool != true, json["walk"] == nil,
              let tracks = json["tracks"] as? [String: Any] else { return nil }
        var parsed: [String: [(Double, Double)]] = [:]
        for (key, value) in tracks {
            guard PuppetChannel.all.contains(where: { $0.key == key }),
                  let frames = value as? [[Double]] else { return nil }
            parsed[key] = frames.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        }
        // 各通道关键帧时间的并集上取值（线性插值），合成整体姿势帧
        let times = Set(parsed.values.flatMap { $0.map(\.0) }).sorted()
        self.id = id
        self.name = json["name"] as? String ?? id
        self.image = json["image"] as? String ?? ""
        self.effect = json["effect"] as? String ?? ""
        self.say = (json["say"] as? [String] ?? []).joined(separator: " / ")
        self.returnToRest = false
        self.keyframes = times.map { t in
            var values: [String: Double] = [:]
            for (key, frames) in parsed { values[key] = Self.sample(frames, at: t) }
            return PuppetKeyframe(t: t, values: values)
        }
        if keyframes.isEmpty { keyframes = [PuppetKeyframe(t: 0)] }
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    private static func sample(_ frames: [(Double, Double)], at t: Double) -> Double {
        guard let first = frames.first else { return 0 }
        if t <= first.0 { return first.1 }
        for i in 1..<frames.count where t <= frames[i].0 {
            let (t0, v0) = frames[i - 1], (t1, v1) = frames[i]
            return t1 > t0 ? v0 + (v1 - v0) * (t - t0) / (t1 - t0) : v1
        }
        return frames[frames.count - 1].1
    }

    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// 形象工坊里编辑中的形象包。
struct PuppetDraft {
    var packId: String?
    var name = "我的桌宠"
    var faces = "front"           // front | left | right
    var shareable = false         // 作者声明「原创或已获授权」：发布到松萝社区的前提（本地使用与导出不受限）
    var images: [PuppetImage] = []
    var actions: [PuppetActionDraft] = []
    /// 编辑器表达不了的包内动作（波形 / 循环 / 溜达），保存时原样写回
    var extraActions: [String: Any] = [:]
    /// 触发器覆盖：触发器名 → 动作 id 列表（没写的用预置）
    var triggers: [String: [String]] = [:]
    /// 台词覆盖：触发器名 → 台词
    var lines: [String: [String]] = [:]
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
        // 面部特征点请求同时给出人脸框，一次拿到头部、眼睛、嘴巴
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area })
        else {
            // 头身比较大的卡通形象：头部约占上 1/3
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let neckY: CGFloat = aspect > 0.75 ? 0.58 : 0.66
            rig.neck = CGPoint(x: 0.5, y: neckY)
            rig.head = CGRect(x: 0.2, y: neckY - 0.02, width: 0.6, height: 1 - neckY + 0.02)
            return rig
        }
        // Vision 的 boundingBox 本来就是归一化、原点左下
        let face = observation.boundingBox
        let x0 = max(0, face.minX - face.width * 0.35)
        let x1 = min(1, face.maxX + face.width * 0.35)
        let y0 = max(0, face.minY - face.height * 0.12)
        let y1 = min(1, face.maxY + face.height * 0.55)
        rig.head = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        rig.neck = CGPoint(x: face.midX, y: max(0.05, face.minY - face.height * 0.1))

        // 特征点坐标相对人脸框归一化 → 换算到整张图
        func region(_ r: VNFaceLandmarkRegion2D?, padX: CGFloat, padY: CGFloat) -> CGRect? {
            guard let r, r.pointCount > 2 else { return nil }
            let pts = r.normalizedPoints.map {
                CGPoint(x: face.minX + CGFloat($0.x) * face.width, y: face.minY + CGFloat($0.y) * face.height)
            }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            let w = maxX - minX, h = max(maxY - minY, w * 0.25)
            return CGRect(x: minX - w * padX, y: (minY + maxY) / 2 - h / 2 - h * padY,
                          width: w * (1 + padX * 2), height: h * (1 + padY * 2))
        }
        let landmarks = observation.landmarks
        rig.eyes = [region(landmarks?.leftEye, padX: 0.15, padY: 0.35),
                    region(landmarks?.rightEye, padX: 0.15, padY: 0.35)].compactMap { $0 }
            .sorted { $0.minX < $1.minX }
        rig.mouth = region(landmarks?.outerLips, padX: 0.05, padY: 0.1)
        return rig
    }

    // MARK: 自动生成闭眼 / 张嘴图

    /// 闭眼：用眼睛上方的眼皮颜色盖住眼睛（羽化边缘），再画一道向下弯的睫毛线。
    static func synthesizeBlink(_ png: Data, rig: PuppetRig) -> Data? {
        guard !rig.eyes.isEmpty else { return nil }
        return paint(png) { ctx, px, size in
            for eye in rig.eyes {
                let r = CGRect(x: eye.minX * size.width, y: eye.minY * size.height,
                               width: eye.width * size.width, height: eye.height * size.height)
                // 眼皮色：眼睛正上方一条带的平均色；睫毛色：眼睛范围内最暗的一批像素
                let lid = averageColor(px, size: size, in: CGRect(x: r.minX + r.width * 0.15, y: r.maxY + r.height * 0.15,
                                                                  width: r.width * 0.7, height: r.height * 0.45))
                let lash = darkColor(px, size: size, in: r)
                // 径向渐变羽化：中心实色、边缘渐隐，和周围皮肤自然过渡
                let clear = lid.copy(alpha: 0) ?? lid
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: [lid, lid, clear] as CFArray, locations: [0, 0.72, 1]) {
                    ctx.saveGState()
                    ctx.translateBy(x: r.midX, y: r.midY)
                    ctx.scaleBy(x: r.width * 0.62, y: r.height * 0.8)
                    ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                           endCenter: .zero, endRadius: 1, options: [])
                    ctx.restoreGState()
                }
                let path = CGMutablePath()
                let y = r.midY - r.height * 0.05
                path.move(to: CGPoint(x: r.minX + r.width * 0.08, y: y + r.height * 0.08))
                path.addQuadCurve(to: CGPoint(x: r.maxX - r.width * 0.08, y: y + r.height * 0.08),
                                  control: CGPoint(x: r.midX, y: y - r.height * 0.32))
                ctx.addPath(path)
                ctx.setStrokeColor(lash)
                ctx.setLineWidth(max(1.5, r.height * 0.13))
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
        }
    }

    /// 张嘴：在嘴巴中央画一个深色口腔（下半带一点舌头色），边缘轻微羽化。
    static func synthesizeTalk(_ png: Data, rig: PuppetRig) -> Data? {
        guard let mouth = rig.mouth else { return nil }
        return paint(png) { ctx, _, size in
            let m = CGRect(x: mouth.minX * size.width, y: mouth.minY * size.height,
                           width: mouth.width * size.width, height: mouth.height * size.height)
            let w = m.width * 0.56, h = max(m.height * 0.62, w * 0.32)
            let open = CGRect(x: m.midX - w / 2, y: m.midY - h * 0.62, width: w, height: h)
            let inside = CGColor(red: 0.28, green: 0.07, blue: 0.09, alpha: 1)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: h * 0.18, color: inside)
            ctx.setFillColor(inside)
            ctx.fillEllipse(in: open)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addEllipse(in: open)
            ctx.clip()
            ctx.setFillColor(CGColor(red: 0.78, green: 0.36, blue: 0.4, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: open.minX + w * 0.18, y: open.minY - h * 0.25, width: w * 0.64, height: h * 0.55))
            ctx.restoreGState()
        }
    }

    /// 在图片上作画（坐标原点左下，与骨架坐标一致），返回新 PNG。
    private static func paint(_ png: Data, draw: (CGContext, [UInt8], CGSize) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(data: png), let image = rep.cgImage, let px = rgba(image) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        // 只画在角色身上（source-atop：透明背景处不落色）
        ctx.setBlendMode(.sourceAtop)
        draw(ctx, px.data, size)
        guard let result = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }

    /// 区域平均色（rect 为左下原点像素坐标；像素数组行自上而下、预乘）。
    private static func averageColor(_ px: [UInt8], size: CGSize, in rect: CGRect) -> CGColor {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        forEachPixel(px, size: size, in: rect) { pr, pg, pb, pa in
            guard pa > 200 else { return }
            r += pr; g += pg; b += pb; n += 1
        }
        guard n > 0 else { return CGColor(red: 0.95, green: 0.82, blue: 0.75, alpha: 1) }
        return CGColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
    }

    /// 区域内最暗 15% 像素的平均色（睫毛 / 眼线）。
    private static func darkColor(_ px: [UInt8], size: CGSize, in rect: CGRect) -> CGColor {
        var samples: [(l: Double, r: Double, g: Double, b: Double)] = []
        forEachPixel(px, size: size, in: rect) { pr, pg, pb, pa in
            guard pa > 200 else { return }
            samples.append((0.3 * pr + 0.59 * pg + 0.11 * pb, pr, pg, pb))
        }
        guard !samples.isEmpty else { return CGColor(red: 0.2, green: 0.13, blue: 0.12, alpha: 1) }
        let dark = samples.sorted { $0.l < $1.l }.prefix(max(1, samples.count * 15 / 100))
        let n = Double(dark.count)
        // 再压暗一点，线条更清楚
        return CGColor(red: dark.map(\.r).reduce(0, +) / n * 0.8,
                       green: dark.map(\.g).reduce(0, +) / n * 0.8,
                       blue: dark.map(\.b).reduce(0, +) / n * 0.8, alpha: 1)
    }

    private static func forEachPixel(_ px: [UInt8], size: CGSize, in rect: CGRect,
                                     _ body: (Double, Double, Double, Double) -> Void) {
        let w = Int(size.width), h = Int(size.height)
        let x0 = max(0, Int(rect.minX)), x1 = min(w - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(h - 1, Int(rect.maxY))
        guard x1 >= x0, y1 >= y0 else { return }
        for y in y0...y1 {
            let row = (h - 1 - y) * w * 4          // 左下原点 → 行自上而下
            for x in x0...x1 {
                let i = row + x * 4
                let a = Double(px[i + 3])
                guard a > 0 else { continue }
                // 反预乘
                body(Double(px[i]) / a, Double(px[i + 1]) / a, Double(px[i + 2]) / a, a)
            }
        }
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
        // 没有自备闭眼 / 张嘴图时，按「平时」图的眼睛、嘴巴位置自动生成（标记 generated，编辑时重新生成）
        let roles = Set(draft.images.map(\.role))
        let generated: [(PuppetRole, (Data, PuppetRig) -> Data?)] = [
            (.blink, PuppetBuilder.synthesizeBlink), (.talk, PuppetBuilder.synthesizeTalk),
        ]
        for (role, make) in generated where !roles.contains(role) {
            guard let png = make(idle.png, idle.rig) else { continue }
            let file = "\(role.rawValue).png"
            try png.write(to: dir.appendingPathComponent(file))
            imageSpecs[role.rawValue] = ["src": file, "rig": idle.rig.json, "generated": true]
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
        var actions = draft.extraActions
        for action in draft.actions { actions[action.id] = action.json }
        // 空的就删掉键（不写 null）
        let sections: [(String, [String: Any])] = [
            ("actions", actions), ("triggers", draft.triggers), ("lines", draft.lines),
        ]
        for (key, value) in sections {
            if value.isEmpty { puppet.removeValue(forKey: key) } else { puppet[key] = value }
        }

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
        for (id, value) in (puppet["actions"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let json = value as? [String: Any], let action = PuppetActionDraft(id: id, json: json) {
                draft.actions.append(action)
            } else {
                draft.extraActions[id] = value
            }
        }
        // 触发器 / 台词的值可以是单个字符串或数组
        func stringLists(_ any: Any?) -> [String: [String]] {
            var out: [String: [String]] = [:]
            for (key, value) in any as? [String: Any] ?? [:] {
                if let list = value as? [String] { out[key] = list } else if let one = value as? String { out[key] = [one] }
            }
            return out
        }
        draft.triggers = stringLists(puppet["triggers"])
        draft.lines = stringLists(puppet["lines"])
        draft.faces = puppet["faces"] as? String ?? "front"
        draft.shareable = puppet["rights"] as? String == "shareable"
        if let pluginData = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
           let plugin = try? JSONSerialization.jsonObject(with: pluginData) as? [String: Any],
           let name = plugin["name"] as? String {
            draft.name = name
        }
        for role in PuppetRole.allCases {
            guard let spec = specs[role.rawValue],
                  (spec as? [String: Any])?["generated"] as? Bool != true else { continue }
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

    /// 导出 `.lianapet`（zip）。本地使用不干预：任何纸偶形象都能导出。
    static func export(packId: String, to url: URL) throws {
        guard isPuppet(packId: packId) else {
            throw PuppetError.message("只能导出纸偶形象")
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
