import AppKit
import CryptoKit
import Foundation

/// 在线更新：用户点「检查更新」才联网，从 GitHub Releases 取最新正式版（可选 Nightly），
/// 下载 DMG → 用同一 Release 里的 `.sha256` 校验 → 挂载 → 替换输入法本体与词库 / 搭配模型 → 重启输入法。
///
/// 边界（见 docs/threat-model.md T7）：
/// - 从不在后台自己检查或下载；只连 api.github.com 与 GitHub 的下载地址，不上传任何东西；
/// - sha256 对不上就整个放弃；
/// - 新包的 bundle id 与正在运行的不同（本机开发版）、或装在需要管理员权限的目录时不自动替换，改为打开 DMG 手动装。
enum LianaUpdater {
    static let repo = "sevenaaaaaaaaa/liana"
    private static let nightlyKey = "LianaUpdateNightly"

    /// 是否也接收 Nightly（每日构建）
    static var includeNightly: Bool {
        get { UserDefaults.standard.bool(forKey: nightlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: nightlyKey) }
    }

    static var currentVersion: String {
        // 开发自检用：假装是某个旧版本
        if let fake = ProcessInfo.processInfo.environment["LIANA_FAKE_VERSION"] { return fake }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    struct Release {
        let version: String
        let title: String
        let notes: String
        let page: URL
        let dmg: URL
        let checksum: URL
        let size: Int64
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case noAsset
        case checksum
        case mount(String)
        case install(String)

        var errorDescription: String? {
            switch self {
            case .network(let detail): return "连不上 GitHub：\(detail)"
            case .noAsset: return "这个版本没有 macOS 安装包"
            case .checksum: return "安装包校验失败（sha256 不一致），已放弃"
            case .mount(let detail): return "打开安装包失败：\(detail)"
            case .install(let detail): return "安装失败：\(detail)"
            }
        }
    }

    enum Outcome {
        /// 已经装好，输入法马上重启
        case installed(String)
        /// 不能自动替换，已打开安装包（原因）
        case manual(String)
    }

    // MARK: 检查

    /// 查最新版本：有更新返回 Release，已是最新返回 nil。
    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        var endpoints = ["https://api.github.com/repos/\(repo)/releases/latest"]
        if includeNightly { endpoints.append("https://api.github.com/repos/\(repo)/releases/tags/nightly") }
        var found: [Release] = []
        var failure: Error?
        let group = DispatchGroup()
        for endpoint in endpoints {
            group.enter()
            fetchJSON(endpoint) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let json): if let release = parse(json) { found.append(release) }
                    case .failure(let error): failure = error
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if found.isEmpty, let failure { return completion(.failure(failure)) }
            let newest = found.max { compareVersions($0.version, $1.version) < 0 }
            if let newest, compareVersions(newest.version, currentVersion) > 0 {
                completion(.success(newest))
            } else {
                completion(.success(nil))
            }
        }
    }

    private static func fetchJSON(_ url: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Liana/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(UpdateError.network(error.localizedDescription))) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return completion(.failure(UpdateError.network("HTTP \(status)")))
            }
            completion(.success(json))
        }.resume()
    }

    /// Release JSON → 版本号取自安装包文件名 `Liana-<版本>-universal.dmg`（Nightly 的 tag 固定是 nightly）。
    private static func parse(_ json: [String: Any]) -> Release? {
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let dmgAsset = assets.first(where: {
            let name = $0["name"] as? String ?? ""
            return name.hasPrefix("Liana-") && name.hasSuffix(".dmg")
        }),
              let dmgName = dmgAsset["name"] as? String,
              let dmgURL = (dmgAsset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let sumAsset = assets.first(where: { $0["name"] as? String == dmgName + ".sha256" }),
              let sumURL = (sumAsset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        var version = String(dmgName.dropFirst("Liana-".count).dropLast(".dmg".count))
        if let dash = version.range(of: "-universal") ?? version.range(of: "-arm64") ?? version.range(of: "-x86_64") {
            version = String(version[..<dash.lowerBound])
        }
        return Release(
            version: version,
            title: json["name"] as? String ?? version,
            notes: json["body"] as? String ?? "",
            page: page,
            dmg: dmgURL,
            checksum: sumURL,
            size: (dmgAsset["size"] as? NSNumber)?.int64Value ?? 0
        )
    }

    /// 语义化版本比较（含预发布：0.5.0-nightly.20261019 < 0.5.0）。
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func split(_ v: String) -> ([Int], String?) {
            let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
            let nums = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            return (nums, parts.count > 1 ? parts[1] : nil)
        }
        let (na, pa) = split(a), (nb, pb) = split(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0, y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        switch (pa, pb) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case let (x?, y?): return x == y ? 0 : (x.compare(y, options: .numeric) == .orderedAscending ? -1 : 1)
        }
    }

    // MARK: 下载与安装

    /// 下载 → 校验 → 安装；`progress` 在主线程回报 0…1。
    static func install(_ release: Release, progress: @escaping (Double) -> Void,
                        completion: @escaping (Result<Outcome, Error>) -> Void) {
        let finish = { (result: Result<Outcome, Error>) in DispatchQueue.main.async { completion(result) } }
        let downloader = Downloader(progress: progress) { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let dmg):
                fetchChecksum(release.checksum) { expected in
                    guard let expected, sha256(of: dmg) == expected else {
                        try? FileManager.default.removeItem(at: dmg)
                        return finish(.failure(UpdateError.checksum))
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        finish(Result { try apply(dmg: dmg, version: release.version) })
                    }
                }
            }
        }
        downloader.start(release.dmg)
    }

    private static func fetchChecksum(_ url: URL, completion: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(text.split(separator: " ").first.map { $0.lowercased() })
        }.resume()
    }

    private static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 挂载 DMG，替换输入法本体与数据文件；不能自动替换时打开 DMG。
    private static func apply(dmg: URL, version: String) throws -> Outcome {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("liana-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path])
        guard attach.status == 0 else { throw UpdateError.mount(attach.output) }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let newApp = mount.appendingPathComponent("Liana.app")
        let resources = mount.appendingPathComponent("松萝安装器.app/Contents/Resources")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.install("安装包里没有 Liana.app") }
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        let newId = Bundle(url: newApp)?.bundleIdentifier
        // 开发自检用：走完下载、校验、挂载，只报告不替换
        if ProcessInfo.processInfo.environment["LIANA_UPDATE_DRY"] != nil {
            let files = ["base.ifd", "base.lm"].filter { fm.fileExists(atPath: resources.appendingPathComponent($0).path) }
            return .manual("演练：校验通过，包内 \(newId ?? "?") + \(files.joined(separator: "、"))，未替换")
        }
        let manual = { (reason: String) -> Outcome in
            NSWorkspace.shared.open(dmg)
            return .manual(reason)
        }
        guard newId == Bundle.main.bundleIdentifier else {
            return manual("当前是本机开发版（\(Bundle.main.bundleIdentifier ?? "?")），已打开安装包，请手动安装")
        }
        guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            return manual("输入法装在需要管理员权限的位置，已打开安装包，请用里面的安装器更新")
        }
        // 先拷到旁边再整体替换，失败也不会留下半个输入法
        let staged = current.deletingLastPathComponent().appendingPathComponent(".Liana-\(version).app")
        try? fm.removeItem(at: staged)
        let copy = run("/usr/bin/ditto", [newApp.path, staged.path])
        guard copy.status == 0 else { throw UpdateError.install(copy.output) }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        _ = try fm.replaceItemAt(current, withItemAt: staged)

        // 词库 / 搭配模型：随安装器分发，一并更新
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Liana")
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        for name in ["base.ifd", "base.lm"] {
            let src = resources.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let tmp = data.appendingPathComponent(".\(name).new")
            try? fm.removeItem(at: tmp)
            if (try? fm.copyItem(at: src, to: tmp)) != nil {
                _ = try? fm.replaceItemAt(data.appendingPathComponent(name), withItemAt: tmp)
            }
        }
        try? fm.removeItem(at: dmg)
        return .installed(version)
    }

    /// 输入法重启：先拉起新的一份（它看到旧进程还在会只做转发、几秒后退出——所以延迟到旧进程退出后），再退出自己。
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 0.5; open \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// 带进度的下载（下到缓存目录）。
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var keepAlive: Downloader?

    init(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
    }

    func start(_ url: URL) {
        keepAlive = self
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress(value) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            completion(.failure(LianaUpdater.UpdateError.network("HTTP \(http.statusCode)")))
            return
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Liana-update")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "Liana.dmg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            completion(.success(dest))
        } catch {
            completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion(.failure(LianaUpdater.UpdateError.network(error.localizedDescription))) }
        session.finishTasksAndInvalidate()
        keepAlive = nil
    }
}
