import AppKit
import Foundation

/// 同声传译运行时：llama.cpp 的 `llama-server` 独立进程 + 127.0.0.1 回环 HTTP。
///
/// ADR-0004 边界：
/// - 运行时不由 松萝下载（用户自行 `brew install llama.cpp`），这里只做检测与引导；
/// - 模型走 `AIModelStore`（点击下载 + sha256 校验），未安装时拒绝启动；
/// - 只连接回环地址：原文与译文不离开设备，没有遥测、没有外部请求。
final class TranslateClient {
    static let shared = TranslateClient(model: { TranslateClient.translateModelPath() })
    /// 长句重排专用实例：用中文能力更好的模型（见 `rerankModelPath`），空闲一会儿自动退出释放内存
    static let rerank = TranslateClient(model: { TranslateClient.rerankModelPath() }, idleStop: 300)

    /// 这个实例用哪个模型
    private let modelPath: () -> String?
    /// 空闲多少秒后自动停掉服务（nil = 不自动停）
    private let idleStop: TimeInterval?
    private var idleWork: DispatchWorkItem?

    private init(model: @escaping () -> String?, idleStop: TimeInterval? = nil) {
        self.modelPath = model
        self.idleStop = idleStop
    }

    enum TranslateError: LocalizedError {
        case runtimeMissing
        case modelMissing
        case serverFailed(String)
        case badResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .runtimeMissing: return "未检测到 llama.cpp 运行时（终端执行 brew install llama.cpp）"
            case .modelMissing: return "未安装翻译模型（菜单「AI 增强」下载）"
            case .serverFailed(let detail): return "llama-server 启动失败：\(detail)"
            case .badResponse: return "翻译响应无法解析"
            case .timeout: return "翻译请求超时"
            }
        }
    }

    private var process: Process?
    private var port: Int?
    private var stderrTail = ""
    private var starting = false
    private var startWaiters: [(Bool) -> Void] = []
    private var queue: [(body: Data, completion: (Result<String, Error>) -> Void)] = []
    private var inflight = false
    private static var cleanupInstalled = false

    // MARK: - 探测

    /// 查找 llama-server：环境变量 → 常见路径 → PATH。
    static func findRuntime() -> String? {
        if let p = ProcessInfo.processInfo.environment["LIANA_LLAMA_SERVER"],
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        for p in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/llama-server"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 可用的翻译模型路径：优先已启用的 translate 模型，否则自动启用第一个已安装的。
    static func translateModelPath() -> String? {
        let store = AIModelStore.shared
        if let enabled = AIModelStore.enabledModel(for: "translate"), store.isInstalled(enabled) {
            return store.path(for: enabled).path
        }
        if let model = store.catalog.first(where: { $0.supports("translate") && store.isInstalled($0) }) {
            AIModelStore.setSelectedModelId(model.id, for: "translate")
            return store.path(for: model).path
        }
        return nil
    }

    /// 长句重排用的模型：只用中文能力够的（Qwen 系列；实测 Gemma 270M 会把对的句子改错）。
    /// 优先「AI 增强」里为候选优化选中的模型，否则取已安装的第一个合格模型。
    static func rerankModelPath() -> String? {
        // 开发自检用：直接指定模型文件
        if let path = ProcessInfo.processInfo.environment["LIANA_RERANK_MODEL"],
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        let store = AIModelStore.shared
        let good = { (id: String) in id.hasPrefix("qwen") }
        if let enabled = AIModelStore.enabledModel(for: "assist"), good(enabled.id), store.isInstalled(enabled) {
            return store.path(for: enabled).path
        }
        let order = ["qwen2.5-1.5b-instruct-q4", "qwen2.5-0.5b-instruct-q8", "qwen3-0.6b-q8"]
        for id in order {
            if let model = store.catalog.first(where: { $0.id == id }), store.isInstalled(model) {
                return store.path(for: model).path
            }
        }
        return nil
    }

    var isRunning: Bool { process?.isRunning == true && port != nil }

    // MARK: - 服务生命周期

    /// 预热：异步拉起服务（失败静默，真实请求时会再报错）。
    func warmup() {
        ensureServer { _ in }
    }

    private func ensureServer(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            if self.isRunning, self.process != nil {
                completion(true)
                return
            }
            self.startWaiters.append(completion)
            guard !self.starting else { return }
            self.startServerLocked()
        }
    }

    private func startServerLocked() {
        starting = true
        guard let bin = Self.findRuntime() else { flushStarters(false, error: TranslateError.runtimeMissing); return }
        guard let model = modelPath() else { flushStarters(false, error: TranslateError.modelMissing); return }
        Self.installCleanup()

        let chosen = Int.random(in: 20_480...45_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        // -np 4：重排时几条候选并行打分
        process.arguments = ["-m", model, "--host", "127.0.0.1", "--port", "\(chosen)", "-np", "4", "-c", "4096"]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        stderrTail = ""

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            self.stderrTail = (self.stderrTail + text)
            if self.stderrTail.count > 4000 {
                self.stderrTail = String(self.stderrTail.suffix(4000))
            }
        }

        do {
            try process.run()
        } catch {
            flushStarters(false, error: TranslateError.serverFailed(error.localizedDescription))
            return
        }
        self.process = process
        self.port = chosen
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                let failed = self.starting
                self.process = nil
                self.port = nil
                if failed {
                    let tail = self.stderrTail.split(separator: "\n").suffix(3).joined(separator: " | ")
                    self.flushStarters(false, error: TranslateError.serverFailed(tail.isEmpty ? "进程退出(\(proc.terminationStatus))" : tail))
                }
            }
        }

        pollHealth(tries: 160) { [weak self] ok in
            guard let self else { return }
            self.starting = false
            if !ok {
                self.stop()
                self.flushStarters(false, error: TranslateError.serverFailed(
                    self.stderrTail.split(separator: "\n").suffix(3).joined(separator: " | ")
                ))
            } else {
                self.flushStarters(true, error: nil)
                self.pump()
            }
        }
    }

    /// 轮询 `/health`：绑定成功但模型加载中会先拒绝/503，就绪后返回 200。
    private func pollHealth(tries: Int, completion: @escaping (Bool) -> Void) {
        guard let port else { completion(false); return }
        guard tries > 0 else { completion(false); return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self, self.starting else {
                    completion(response != nil)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    completion(true)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.pollHealth(tries: tries - 1, completion: completion)
                    }
                }
            }
        }.resume()
    }

    private func flushStarters(_ ok: Bool, error: Error?) {
        let waiters = startWaiters
        startWaiters = []
        starting = false
        waiters.forEach { $0(ok) }
        _ = error
    }

    /// 停止服务（释放模型内存）。进程内退出时也会尽力调用（atexit）。
    func stop() {
        DispatchQueue.main.async { self.stopLocked() }
    }

    private func stopLocked() {
        let pending = queue
        queue = []
        inflight = false
        pending.forEach { $0.completion(.failure(TranslateError.serverFailed("服务已停止"))) }
        port = nil
        if let process {
            self.process = nil
            process.terminationHandler = nil
            // 不改已 launch 的 task 配置属性（会抛 "task already launched"）
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }
        starting = false
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0(false) }
    }

    private static func installCleanup() {
        guard !cleanupInstalled else { return }
        cleanupInstalled = true
        atexit {
            // 尽力清理：IME 进程退出时杀掉 llama-server，避免孤儿进程占内存。
            TranslateClient.shared.forceStopSync()
            TranslateClient.rerank.forceStopSync()
        }
    }

    private func forceStopSync() {
        if let process {
            process.terminationHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }
        process = nil
        port = nil
    }

    // MARK: - 翻译请求（串行队列，保序）

    func translate(_ text: String, target: String, completion: @escaping (Result<String, Error>) -> Void) {
        let language = target == "ja" ? "Japanese" : "English"
        chat(
            system: "Translate the Chinese input completely into natural \(language). Never omit, summarize, or shorten any part. Output ONLY the \(language) translation, nothing else.",
            user: text,
            maxTokens: 400,
            completion: completion
        )
    }

    /// 通用对话补全（同传与喂食层 AI 提炼共用同一 llama-server 与串行队列）。
    /// 只连 127.0.0.1：输入与输出都不离开设备（ADR-0004 / ADR-0008 边界）。
    func chat(system: String, user: String, maxTokens: Int, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            guard Self.findRuntime() != nil else {
                completion(.failure(TranslateError.runtimeMissing)); return
            }
            guard Self.translateModelPath() != nil else {
                completion(.failure(TranslateError.modelMissing)); return
            }
            let payload: [String: Any] = [
                "model": "liana",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
                "temperature": 0.2,
                "max_tokens": maxTokens,
                "stream": false,
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else {
                completion(.failure(TranslateError.badResponse)); return
            }
            self.queue.append((body, completion))
            self.ensureServer { ok in
                if !ok {
                    let failed = self.queue
                    self.queue = []
                    failed.forEach { $0.completion(.failure(TranslateError.serverFailed("运行时/模型不可用"))) }
                    return
                }
                self.pump()
            }
        }
    }

    private func pump() {
        guard !inflight, !queue.isEmpty, let port,
              process?.isRunning == true else { return }
        inflight = true
        let next = queue.removeFirst()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = next.body
        let started = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight = false
                defer {
                    if self.process != nil { self.pump() }
                }
                if let error {
                    next.completion(.failure(error)); return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    next.completion(.failure(TranslateError.serverFailed("HTTP \(http.statusCode): \(body.prefix(200))")))
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    next.completion(.failure(TranslateError.badResponse)); return
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                next.completion(.success(trimmed))
                _ = started
            }
        }.resume()
    }

    // MARK: - 打分（长句重排）

    /// 用模型给几段文本打分：`prefix + 文本` 按模型自己的分词切成 token，逐个取
    /// 「在前文之后接着出现这个 token」的 log 概率（读下一个 token 的 top-40 概率表，不在表里按表尾再减 1），
    /// 累加即这段文本的得分。所有 token 请求并行发出（服务端 4 个槽、复用提示词缓存）；任何一步失败返回 nil。
    ///
    /// 不用「语法约束强制生成」：那样模型会把「有什么」拆成「有/什/么」单字生成，分数被严重低估。
    func score(_ texts: [String], prefix: String, timeout: TimeInterval, completion: @escaping ([Double]?) -> Void) {
        ensureServer { [weak self] ok in
            guard let self, ok, let port = self.port else { return completion(nil) }
            self.touchIdle()
            let base = "http://127.0.0.1:\(port)"
            let group = DispatchGroup()
            var tokenized = [[Int]?](repeating: nil, count: texts.count + 1)
            for (i, text) in ([prefix] + texts.map { prefix + $0 }).enumerated() {
                group.enter()
                Self.post(base + "/tokenize", ["content": text], timeout: timeout) { json in
                    let ids = (json?["tokens"] as? [Any])?.compactMap { item -> Int? in
                        (item as? Int) ?? ((item as? [String: Any])?["id"] as? Int)
                    }
                    DispatchQueue.main.async {
                        tokenized[i] = ids
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                guard let pre = tokenized[0], tokenized.allSatisfy({ $0 != nil }) else { return completion(nil) }
                var sums = [Double](repeating: 0, count: texts.count)
                var failed = false
                let steps = DispatchGroup()
                for (t, ids) in tokenized.dropFirst().enumerated() {
                    guard let ids else { continue }
                    // 前缀拼上文本后切分通常不变；以公共前缀长度为准
                    var k = 0
                    while k < min(pre.count, ids.count), pre[k] == ids[k] { k += 1 }
                    for j in k..<ids.count {
                        steps.enter()
                        let body: [String: Any] = [
                            "prompt": Array(ids[..<j]), "n_predict": 1, "n_probs": 40,
                            "temperature": 0, "cache_prompt": true,
                        ]
                        Self.post(base + "/completion", body, timeout: timeout) { json in
                            let top = ((json?["completion_probabilities"] as? [[String: Any]])?.first?["top_logprobs"]
                                as? [[String: Any]]) ?? []
                            let hit = top.first { $0["id"] as? Int == ids[j] }?["logprob"] as? Double
                            let floor = top.compactMap { $0["logprob"] as? Double }.min().map { $0 - 1 }
                            DispatchQueue.main.async {
                                if let value = hit ?? floor { sums[t] += value } else { failed = true }
                                steps.leave()
                            }
                        }
                    }
                }
                steps.notify(queue: .main) { completion(failed ? nil : sums) }
            }
        }
    }

    private static func post(_ url: String, _ body: [String: Any], timeout: TimeInterval,
                             completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else {
            return completion(nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request) { data, _, _ in
            completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        }.resume()
    }

    /// 有请求就推迟自动停止（只对设置了 idleStop 的实例生效）。
    private func touchIdle() {
        guard let idleStop else { return }
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopLocked() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleStop, execute: work)
    }
}
