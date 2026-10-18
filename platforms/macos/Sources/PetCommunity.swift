import AppKit
import SwiftUI

/// 纸偶社区：GitHub 上的公开形象目录（只是一份 index.json + .lianapet 文件，没有服务器）。
///
/// - 只在用户打开社区窗口时联网读取目录；下载必须 sha256 校验通过才导入；
/// - 投稿 = 本机打包（.lianapet + 预览图 + 目录条目）→ 打开 GitHub 投稿页，由用户自己提交。
enum PetCommunity {
    static let repoURL = URL(string: "https://github.com/sevenaaaaaaaaa/liana-pets")!
    private static let defaultIndex = "https://raw.githubusercontent.com/sevenaaaaaaaaa/liana-pets/main/index.json"
    private static let rawBase = "https://raw.githubusercontent.com/sevenaaaaaaaaa/liana-pets/main/packs/"
    private static let indexKey = "LianaPetCommunityIndex"

    /// 目录地址，可用 `defaults write <bundle-id> LianaPetCommunityIndex <url>` 换成镜像。
    static var indexURL: URL {
        let custom = UserDefaults.standard.string(forKey: indexKey) ?? ""
        return URL(string: custom.hasPrefix("https://") ? custom : defaultIndex)!
    }

    struct Pack: Codable, Identifiable {
        var id: String
        var name: String
        var author: String
        var license: String
        var description: String?
        var url: String
        var sha256: String
        var bytes: Int64?
        var preview: String?
        var tags: [String]?

        var sizeText: String {
            bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        }
    }

    struct Index: Codable {
        var format: Int
        var packs: [Pack]
    }

    /// 不带 Cookie、不带缓存凭据的会话：读目录与下载都不暴露任何本机身份
    private static let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return config
    }())

    static func fetchIndex(completion: @escaping (Result<[Pack], Error>) -> Void) {
        session.dataTask(with: indexURL) { data, response, error in
            let result = Result<[Pack], Error> {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                    throw PuppetError.message("社区目录暂时连不上")
                }
                let index = try JSONDecoder().decode(Index.self, from: data)
                // 只收 https 地址、puppet- 前缀、带 sha256 的条目
                return index.packs.filter {
                    $0.url.hasPrefix("https://") && $0.id.hasPrefix("puppet-") && $0.sha256.count == 64
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// 下载 → sha256 校验 → 按 .lianapet 白名单导入，返回包 id。
    static func install(_ pack: Pack, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: pack.url) else {
            completion(.failure(PuppetError.message("下载地址无效")))
            return
        }
        session.downloadTask(with: url) { temp, _, error in
            let result = Result<String, Error> {
                if let error { throw error }
                guard let temp else { throw PuppetError.message("下载失败") }
                defer { try? FileManager.default.removeItem(at: temp) }
                guard try PetModelInstaller.sha256(of: temp) == pack.sha256.lowercased() else {
                    throw PuppetError.message("sha256 校验失败，已丢弃")
                }
                // ditto 按扩展名无所谓，但留个正经文件名方便排查
                let file = temp.deletingLastPathComponent().appendingPathComponent("\(pack.id).lianapet")
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: temp, to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                return try PuppetPackStore.importPack(from: file)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - 投稿

    /// 已安装、声明可分享的纸偶形象（可投稿）。
    static func shareablePacks() -> [(id: String, name: String)] {
        PetWindowController.availablePets().compactMap { pack in
            guard let draft = PuppetPackStore.load(packId: pack.id), draft.shareable else { return nil }
            return (pack.id, pack.name)
        }
    }

    /// 在「下载/松萝投稿/<id>/」生成 .lianapet、预览图与目录条目，然后打开 GitHub 投稿页。
    static func prepareSubmission(packId: String, author: String, license: String) throws -> URL {
        guard let draft = PuppetPackStore.load(packId: packId) else {
            throw PuppetError.message("只能投稿纸偶形象")
        }
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let folder = downloads.appendingPathComponent("松萝投稿/\(packId)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let packFile = folder.appendingPathComponent("\(packId).lianapet")
        try PuppetPackStore.export(packId: packId, to: packFile)
        let previewFile = folder.appendingPathComponent("\(packId).png")
        if let idle = draft.images.first(where: { $0.role == .idle }) {
            try previewPNG(idle.png)?.write(to: previewFile)
        }
        let size = (try? fm.attributesOfItem(atPath: packFile.path)[.size] as? Int64) ?? nil
        let entry: [String: Any] = [
            "id": packId,
            "name": draft.name,
            "author": author,
            "license": license,
            "description": "",
            "url": rawBase + "\(packId).lianapet",
            "preview": rawBase + "\(packId).png",
            "sha256": try PetModelInstaller.sha256(of: packFile),
            "bytes": size ?? 0,
            "tags": [String](),
        ]
        let entryData = try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
        try entryData.write(to: folder.appendingPathComponent("entry.json"))

        let entryText = String(data: entryData, encoding: .utf8) ?? ""
        let body = """
        ### 投稿形象：\(draft.name)

        - [ ] 图片是我原创，或已获得授权（不含他人肖像 / 未授权角色）
        - 许可证：\(license)

        **请把「下载/松萝投稿/\(packId)/」里的 `\(packId).lianapet` 和 `\(packId).png` 拖进这个输入框上传。**

        目录条目：
        ```json
        \(entryText)
        ```
        """
        var components = URLComponents(url: repoURL.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "投稿：\(draft.name)"),
            URLQueryItem(name: "labels", value: "submission"),
            URLQueryItem(name: "body", value: body),
        ]
        NSWorkspace.shared.activateFileViewerSelecting([packFile, previewFile])
        if let url = components?.url { NSWorkspace.shared.open(url) }
        return folder
    }

    /// 预览图：高 256 的 PNG。
    private static func previewPNG(_ png: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: png), let image = rep.cgImage else { return nil }
        let h = 256, w = max(1, Int(Double(image.width) * 256 / Double(max(1, image.height))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }
}

// MARK: - 社区窗口

final class PetCommunityWindowController: NSWindowController {
    static let shared = PetCommunityWindowController()
    private let model = CommunityModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "纸偶社区"
        window.minSize = NSSize(width: 600, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: CommunityView(model: model))
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 直接打开投稿表单（形象工坊入口）。
    func showSubmit(packId: String) {
        show()
        model.submitPackId = packId
        model.showSubmit = true
    }
}

final class CommunityModel: ObservableObject {
    @Published var packs: [PetCommunity.Pack] = []
    @Published var loading = false
    @Published var error: String?
    @Published var query = ""
    @Published var installing: Set<String> = []
    @Published var status = ""
    @Published var showSubmit = false
    @Published var submitPackId = ""
    @Published var submitAuthor = NSFullUserName()
    @Published var submitLicense = "CC-BY-4.0"

    var installedIds: Set<String> { Set(PetWindowController.availablePets().map(\.id)) }

    var filtered: [PetCommunity.Pack] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return packs }
        return packs.filter {
            "\($0.name) \($0.author) \($0.description ?? "") \(($0.tags ?? []).joined(separator: " "))"
                .lowercased().contains(q)
        }
    }

    func refresh() {
        loading = true
        error = nil
        PetCommunity.fetchIndex { [weak self] result in
            guard let self else { return }
            self.loading = false
            switch result {
            case .success(let packs): self.packs = packs
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func install(_ pack: PetCommunity.Pack) {
        if installedIds.contains(pack.id) {
            use(pack.id, name: pack.name)
            return
        }
        installing.insert(pack.id)
        status = "下载 \(pack.name)…"
        PetCommunity.install(pack) { [weak self] result in
            guard let self else { return }
            self.installing.remove(pack.id)
            switch result {
            case .success(let id): self.use(id, name: pack.name)
            case .failure(let error): self.status = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    private func use(_ id: String, name: String) {
        PetWindowController.activePackId = id
        if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
        status = "已换上「\(name)」（sha256 校验通过）"
        objectWillChange.send()
    }

    func submit() {
        guard !submitPackId.isEmpty else { return }
        do {
            let folder = try PetCommunity.prepareSubmission(
                packId: submitPackId,
                author: submitAuthor.isEmpty ? "匿名" : submitAuthor,
                license: submitLicense
            )
            status = "已打包到 \(folder.path)，在打开的 GitHub 页面上传文件即可投稿"
            showSubmit = false
        } catch {
            status = error.localizedDescription
        }
    }
}

struct CommunityView: View {
    @ObservedObject var model: CommunityModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索名字、作者、标签", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("刷新") { model.refresh() }
                Button("投稿我的形象…") {
                    model.submitPackId = PetCommunity.shareablePacks().first?.id ?? ""
                    model.showSubmit = true
                }
            }
            .padding(14)
            Divider()
            content
            Divider()
            HStack {
                Text(model.status.isEmpty
                     ? "只在打开本窗口时读取社区目录；下载都经 sha256 校验，形象包只含图片和动作数据。"
                     : model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("社区仓库") { NSWorkspace.shared.open(PetCommunity.repoURL) }
                    .controlSize(.small)
            }
            .padding(12)
        }
        .sheet(isPresented: $model.showSubmit) { SubmitSheet(model: model) }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            ProgressView("正在读取社区目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(error).foregroundStyle(.secondary)
                Button("重试") { model.refresh() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(model.packs.isEmpty ? "社区里还没有形象，来做第一个投稿的人吧" : "没有匹配的形象")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                    ForEach(model.filtered) { pack in
                        card(pack)
                    }
                }
                .padding(16)
            }
        }
    }

    private func card(_ pack: PetCommunity.Pack) -> some View {
        let installed = model.installedIds.contains(pack.id)
        let active = PetWindowController.activePackId == pack.id
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08))
                if let preview = pack.preview, preview.hasPrefix("https://"), let url = URL(string: preview) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                    .padding(8)
                }
            }
            .frame(height: 170)
            Text(pack.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(pack.author) · \(pack.license)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if let description = pack.description, !description.isEmpty {
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                if model.installing.contains(pack.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(active ? "使用中" : (installed ? "使用" : "下载并使用")) { model.install(pack) }
                        .disabled(active)
                        .controlSize(.small)
                        .lianaGlassButton()
                }
                Spacer()
                Text(pack.sizeText).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SubmitSheet: View {
    @ObservedObject var model: CommunityModel
    private let licenses = ["CC-BY-4.0", "CC-BY-SA-4.0", "CC0-1.0", "CC-BY-NC-4.0"]

    var body: some View {
        let packs = PetCommunity.shareablePacks()
        VStack(alignment: .leading, spacing: 12) {
            Text("投稿到纸偶社区").font(.system(size: 16, weight: .semibold))
            if packs.isEmpty {
                Text("还没有可投稿的形象：在形象工坊里勾选「图片是我原创或已获授权，可以分享」并保存后再来。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("形象", selection: $model.submitPackId) {
                    ForEach(packs, id: \.id) { Text($0.name).tag($0.id) }
                }
                TextField("作者署名", text: $model.submitAuthor)
                Picker("许可证", selection: $model.submitLicense) {
                    ForEach(licenses, id: \.self) { Text($0).tag($0) }
                }
                Text("会在「下载/松萝投稿」里打包好形象包、预览图和目录条目，并打开 GitHub 投稿页；上传文件、提交都由你自己完成。维护者审核后收录进社区目录。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { model.showSubmit = false }
                Button("打包并打开投稿页") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(packs.isEmpty || model.submitPackId.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
