import Foundation
import Security

/// 制作配置与形象包分离：包只能含数据，API Key 与可执行工具永不进入包。
struct PetStudioConfig: Codable {
    var provider = "minimax"
    var baseURL = "https://api.minimax.io/v1"
    var model = ""
    var codexExecutable = ""
    var executable = ""
    var arguments = "[]"
    static let key = "LianaPetStudio"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return config
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }
}

enum PetStudioSecret {
    static func get(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.liana.pet.studio", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func set(_ key: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.liana.pet.studio", kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

struct PetMotionSettings {
    var intensity = 1.0
    var speed = 1.0
    var gaze = 1.0
    var reduced = false
    var json: [String: Any] { ["intensity": intensity, "speed": speed, "gaze": gaze, "reduced": reduced] }
    init() {}
    init(json: [String: Any]) {
        func bounded(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = (json[key] as? NSNumber)?.doubleValue ?? fallback
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        intensity = bounded("intensity", 1, 0...2)
        speed = bounded("speed", 1, 0.25...2)
        gaze = bounded("gaze", 1, 0...2)
        reduced = json["reduced"] as? Bool ?? false
    }
}

/// AI 只能返回有限关键帧，既不执行代码，也不让它决定调用哪个本地工具。
enum PetStudioPlan {
    static let channels: [String: ClosedRange<Double>] = [
        "head.rot": -0.4...0.4, "head.ty": -0.05...0.05, "head.tx": -0.05...0.05,
        "lean": -0.2...0.2, "root.ty": -0.05...0.25, "root.tx": -0.3...0.3,
        "root.rot": -0.35...0.35, "root.sy": -0.3...0.3, "root.sx": -2...0.3, "alpha": -1...0]
    static let triggers: Set<String> = ["click", "double_click", "hover", "commit", "idle", "wake", "drop",
        "greet", "milestone", "break", "scene_game", "scene_music", "scene_coding", "scene_office",
        "scene_video", "scene_chat", "scene_design", "scene_meeting", "scene_reading", "scene_browse"]
    static let instructions = """
    Return ONLY a JSON object describing desktop pet motion. No code, markdown or tool calls.
    Schema: {"actions":{"studio_unique_id":{"name":"short name","duration":1.0,
    "tracks":{"head.rot":[[0,0],[0.4,0.12],[1,0]]},"say":["optional short line"]}},
    "triggers":{"click":["studio_unique_id"]},"lines":{"greet":["hello"]}}
    Up to 12 actions. Each action lasts 0.1 to 12 seconds, with 2 to 32 strictly increasing keyframes per track.
    All actions must begin and end at neutral (0). No images needed. Use only these channels and limits:
    head.rot ±0.4, head.tx/head.ty ±0.05, lean ±0.2, root.ty -0.05...0.25, root.tx ±0.3,
    root.rot ±0.35, root.sy ±0.3, root.sx -2...0.3, alpha -1...0.
    Allowed triggers: click,double_click,hover,commit,idle,wake,drop,greet,milestone,break,
    scene_game,scene_music,scene_coding,scene_office,scene_video,scene_chat,scene_design,scene_meeting,scene_reading,scene_browse.
    Every trigger action reference must be in actions. Use short Chinese names and lines unless requested otherwise.
    """
    static func validate(_ text: String) throws -> [String: Any] {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```"), clean.hasSuffix("```"), let newline = clean.firstIndex(of: "\n") {
            clean = String(clean[clean.index(after: newline)..<clean.index(clean.endIndex, offsetBy: -3)])
        }
        guard clean.utf8.count <= 256_000,
              let data = clean.data(using: .utf8),
              let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(plan.keys).isSubset(of: ["actions", "triggers", "lines"]),
              let actions = plan["actions"] as? [String: [String: Any]], !actions.isEmpty, actions.count <= 12 else {
            throw failure("需要含 1–12 个动作的 JSON；仅支持 actions、triggers、lines。")
        }
        for (id, action) in actions {
            guard id.range(of: "^studio_[a-zA-Z0-9_]{1,48}$", options: .regularExpression) != nil,
                  Set(action.keys).isSubset(of: ["name", "duration", "tracks", "say", "effect"]),
                  let name = action["name"] as? String, !name.isEmpty, name.count <= 40,
                  let duration = action["duration"] as? Double, duration.isFinite, (0.1...12).contains(duration),
                  let tracks = action["tracks"] as? [String: [[Double]]], !tracks.isEmpty else {
                throw failure("动作 \(id) 的名称、时长或轨道不合法。ID 应以 studio_ 开头。")
            }
            for (channel, frames) in tracks {
                guard let range = channels[channel], (2...32).contains(frames.count) else {
                    throw failure("不支持的动作通道或关键帧数量：\(channel)")
                }
                var last = -1.0
                for frame in frames {
                    guard frame.count == 2, frame.allSatisfy(\.isFinite), frame[0] > last,
                          (0...duration).contains(frame[0]), range.contains(frame[1]) else {
                        throw failure("\(id) / \(channel)：关键帧时间须递增，数值须在允许范围内。")
                    }
                    last = frame[0]
                }
                guard frames.first == [0, 0], frames.last == [duration, 0] else {
                    throw failure("\(id) / \(channel)：起点和终点须回到原位。")
                }
            }
            if let effect = action["effect"], !["", "hearts", "sparks"].contains(effect as? String ?? "invalid") {
                throw failure("不支持的动作特效。")
            }
            if let say = action["say"] { try validateLines(say) }
        }
        for section in ["triggers", "lines"] {
            guard let value = plan[section] else { continue }
            guard let mapping = value as? [String: [String]], mapping.count <= triggers.count else {
                throw failure("\(section) 必须是名称到字符串数组的映射。")
            }
            for (key, values) in mapping {
                guard triggers.contains(key) else { throw failure("不支持的触发器：\(key)") }
                if section == "triggers" {
                    guard !values.isEmpty, values.count <= 12, values.allSatisfy({ actions[$0] != nil }) else {
                        throw failure("\(key) 引用了不存在的动作。")
                    }
                } else { try validateLines(values) }
            }
        }
        return plan
    }
    private static func validateLines(_ value: Any) throws {
        guard let lines = value as? [String], lines.count <= 12, lines.allSatisfy({ $0.count <= 120 }) else {
            throw failure("台词最多 12 条，每条最多 120 字。")
        }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "Liana.PetStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 直接传 argv，绝不经 shell 解释。任务目录由工坊创建，插件包不能声明工具。
enum PetStudioProcess {
    static func run(executable: String, arguments: [String], directory: URL, timeout: TimeInterval = 180) throws -> String {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw PetStudioPlan.failure("请选择本机可执行文件的绝对路径。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let log = directory.appendingPathComponent("tool-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw PetStudioPlan.failure("工具运行超时；请查看任务目录中的日志。")
        }
        guard process.terminationStatus == 0 else {
            throw PetStudioPlan.failure("工具退出码 \(process.terminationStatus)，详见 \(log.lastPathComponent)。")
        }
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 256_000) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum PetStudioService {
    static func generate(prompt: String, config: PetStudioConfig, key: String, directory: URL, session: URLSession = .shared,
                         completion: @escaping (Result<String, Error>) -> Void) {
        if config.provider == "codex" {
            DispatchQueue.global(qos: .userInitiated).async {
                completion(Result {
                    let output = directory.appendingPathComponent("motion.json")
                    var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "-o", output.path]
                    if !config.model.isEmpty { args += ["-m", config.model] }
                    args += [PetStudioPlan.instructions + "\nRequest: " + prompt]
                    _ = try PetStudioProcess.run(executable: config.codexExecutable, arguments: args, directory: directory)
                    return try String(contentsOf: output, encoding: .utf8)
                })
            }
            return
        }
        do {
            guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PetStudioPlan.failure("请填写服务实际提供的模型 ID。")
            }
            guard let base = URL(string: config.baseURL), let host = base.host,
                  base.scheme == "https" || (base.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
                  base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
                throw PetStudioPlan.failure("服务地址须为 HTTPS；本机服务可使用 HTTP。")
            }
            let anthropic = config.provider == "anthropic"
            let url = base.appendingPathComponent(anthropic ? "messages" : "chat/completions")
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["model": config.model, "max_tokens": 4096, "stream": false]
            if anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                body["system"] = PetStudioPlan.instructions
                body["messages"] = [["role": "user", "content": prompt]]
            } else {
                if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
                body["messages"] = [["role": "system", "content": PetStudioPlan.instructions], ["role": "user", "content": prompt]]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            session.dataTask(with: request) { data, response, error in
                completion(Result {
                    if let error { throw error }
                    guard let http = response as? HTTPURLResponse else { throw PetStudioPlan.failure("没有收到服务响应。") }
                    guard (200..<300).contains(http.statusCode) else {
                        throw PetStudioPlan.failure("服务返回 HTTP \(http.statusCode)，请检查地址、模型 ID、余额与密钥。")
                    }
                    guard let data, data.count <= 1_000_000,
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw PetStudioPlan.failure("服务响应过大或不是 JSON。")
                    }
                    if anthropic, let parts = json["content"] as? [[String: Any]] {
                        return parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                    guard let choices = json["choices"] as? [[String: Any]],
                          let message = choices.first?["message"] as? [String: Any], let text = message["content"] as? String else {
                        throw PetStudioPlan.failure("服务未返回动作文本。")
                    }
                    return text
                })
            }.resume()
        } catch { completion(.failure(error)) }
    }
}
