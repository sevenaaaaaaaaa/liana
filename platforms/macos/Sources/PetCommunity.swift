import AppKit
import SwiftUI

/// 形象源：任何人都可以按开放格式发布一份 index.json（列出 .lianapet 地址与 sha256），
/// 用户自己添加想订阅的源。松萝不内置、不托管、不审核任何形象源，只提供读取与校验的能力。
///
/// - 只在用户打开形象源窗口时联网；只收 https 地址；下载必须 sha256 校验通过才导入；
/// - 会话不带 Cookie / 凭据，不向形象源暴露任何本机身份。
enum PetCommunity {
    private static let sourcesKey = "LianaPetSources"

    /// 用户添加的形象源（index.json 地址）
    static var sources: [String] {
        get { UserDefaults.standard.stringArray(forKey: sourcesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: sourcesKey) }
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
        /// 来自哪个形象源（客户端填，不在 index.json 里）
        var source: String?

        var sizeText: String {
            bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        }
    }

    struct Index: Codable {
        var format: Int
        var packs: [Pack]
    }

    private static let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return config
    }())

    /// 读取所有形象源并合并；单个源失败不影响其他源，失败的源在 `failed` 里返回。
    static func fetchAll(completion: @escaping (_ packs: [Pack], _ failed: [String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var packs: [Pack] = []
        var failed: [String] = []
        for source in sources {
            guard let url = URL(string: source), url.scheme == "https" else {
                lock.lock(); failed.append(source); lock.unlock()
                continue
            }
            group.enter()
            session.dataTask(with: url) { data, response, _ in
                defer { group.leave() }
                let host = url.host ?? source
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let index = try? JSONDecoder().decode(Index.self, from: data) else {
                    lock.lock(); failed.append(source); lock.unlock()
                    return
                }
                // 只收 https 地址、puppet- 前缀、带 sha256 的条目
                let valid = index.packs
                    .filter { $0.url.hasPrefix("https://") && $0.id.hasPrefix("puppet-") && $0.sha256.count == 64 }
                    .map { pack -> Pack in
                        var p = pack
                        p.source = host
                        return p
                    }
                lock.lock(); packs.append(contentsOf: valid); lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            completion(packs.sorted { $0.name < $1.name }, failed)
        }
    }

    /// 下载 → sha256 校验 → 按 .lianapet 白名单导入，返回包 id。
    static func install(_ pack: Pack, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: pack.url), url.scheme == "https" else {
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
                let file = temp.deletingLastPathComponent().appendingPathComponent("\(pack.id).lianapet")
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: temp, to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                return try PuppetPackStore.importPack(from: file)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

// MARK: - 形象源窗口

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
        window.title = "形象源"
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
}

final class CommunityModel: ObservableObject {
    @Published var packs: [PetCommunity.Pack] = []
    @Published var sources: [String] = PetCommunity.sources
    @Published var failed: [String] = []
    @Published var loading = false
    @Published var query = ""
    @Published var installing: Set<String> = []
    @Published var status = ""
    @Published var newSource = ""
    @Published var showSources = false

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
        sources = PetCommunity.sources
        guard !sources.isEmpty else {
            packs = []
            failed = []
            return
        }
        loading = true
        PetCommunity.fetchAll { [weak self] packs, failed in
            guard let self else { return }
            self.loading = false
            self.packs = packs
            self.failed = failed
        }
    }

    func addSource() {
        let text = newSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("https://"), URL(string: text) != nil else {
            status = "形象源地址需要以 https:// 开头"
            return
        }
        if !PetCommunity.sources.contains(text) { PetCommunity.sources.append(text) }
        newSource = ""
        refresh()
    }

    func removeSource(_ source: String) {
        PetCommunity.sources.removeAll { $0 == source }
        refresh()
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
                    .disabled(model.sources.isEmpty)
                Button("管理形象源…") { model.showSources = true }
            }
            .padding(14)
            Divider()
            content
            Divider()
            HStack {
                Text(model.status.isEmpty
                     ? "形象源由第三方发布，松萝不托管、不审核。下载都经 sha256 校验，形象包只含图片和动作数据。"
                     : model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(12)
        }
        .sheet(isPresented: $model.showSources) { SourcesSheet(model: model) }
    }

    @ViewBuilder
    private var content: some View {
        if model.sources.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("还没有添加形象源").font(.system(size: 14, weight: .semibold))
                Text("任何人都可以按开放格式发布一个 index.json 作为形象源。\n拿到地址后，点「管理形象源…」添加。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("添加形象源…") { model.showSources = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loading {
            ProgressView("正在读取形象源…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(model.packs.isEmpty ? "形象源里还没有形象" : "没有匹配的形象").foregroundStyle(.secondary)
                if !model.failed.isEmpty {
                    Text("\(model.failed.count) 个形象源读取失败").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if !model.failed.isEmpty {
                    Text("\(model.failed.count) 个形象源读取失败（在「管理形象源」里查看）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                }
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
                Text(pack.source ?? "").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

private struct SourcesSheet: View {
    @ObservedObject var model: CommunityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("形象源").font(.system(size: 16, weight: .semibold))
            Text("形象源是一个公开的 index.json，列出形象包的下载地址和 sha256（格式见松萝仓库 docs/pet-puppet-format.md）。只添加你信任的来源。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.sources, id: \.self) { source in
                HStack {
                    if model.failed.contains(source) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("读取失败")
                    }
                    Text(source).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("移除") { model.removeSource(source) }.controlSize(.small)
                }
            }
            HStack {
                TextField("https://…/index.json", text: $model.newSource)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addSource() }
                Button("添加") { model.addSource() }
            }
            HStack {
                Spacer()
                Button("完成") { model.showSources = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
