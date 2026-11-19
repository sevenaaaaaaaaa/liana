import Foundation
import Security

/// 云端翻译配置。
///
/// 隐私边界：只有开启云端、并且填了 API Key 时才会发请求；请求内容是当前首选候选
/// 那一小段文字，不发上下文、不发输入历史。关掉云端就只用本地词表。
struct TranslationConfig: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini"
    var target: String = "en"
    var enabled: Bool = false

    static let storedKey = "keyboard.translation.config"

    /// 目标语言选项，顺序即切换顺序。
    static let targets: [(code: String, title: String, name: String)] = [
        ("en", "EN", "English"),
        ("ja", "日", "Japanese"),
        ("ko", "한", "Korean"),
        ("fr", "FR", "French"),
        ("de", "DE", "German"),
        ("es", "ES", "Spanish"),
        ("ru", "RU", "Russian"),
    ]

    static func title(for code: String) -> String {
        targets.first { $0.code == code }?.title ?? code.uppercased()
    }
    static func languageName(for code: String) -> String {
        targets.first { $0.code == code }?.name ?? "English"
    }
    static func next(after code: String) -> String {
        let codes = targets.map(\.code)
        guard let index = codes.firstIndex(of: code) else { return codes[0] }
        return codes[(index + 1) % codes.count]
    }

    var trimmedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    var endpoint: URL? { URL(string: trimmedBaseURL + "/chat/completions") }

    /// 能不能真的发请求；不能时给出人话原因。
    func unusableReason(hasKey: Bool) -> String? {
        if !enabled { return "云端翻译未开启" }
        if !hasKey { return "还没有 API Key：先在面板里从剪贴板导入配置" }
        guard let endpoint else { return "服务地址不合法" }
        guard endpoint.scheme == "https" else { return "服务地址必须是 https" }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "模型名为空" }
        return nil
    }
}

/// 配置的持久化：非敏感字段进 UserDefaults，API Key 进 Keychain。
enum TranslationConfigStore {
    static let keychainService = "dev.liana.keyboard.translation"
    static let keychainAccount = "api-key"

    static func load(from defaults: UserDefaults = .standard) -> TranslationConfig {
        guard let data = defaults.data(forKey: TranslationConfig.storedKey),
              let config = try? JSONDecoder().decode(TranslationConfig.self, from: data) else {
            return TranslationConfig()
        }
        return config
    }

    static func save(_ config: TranslationConfig, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: TranslationConfig.storedKey) }
    }

    static func apiKey() -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        query.removeAll()
        return value
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return true
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// 从剪贴板导入的 JSON：{ "base_url": "...", "model": "...", "api_key": "...", "target": "en" }
    struct ImportedConfig: Decodable {
        var base_url: String?
        var baseURL: String?
        var model: String?
        var api_key: String?
        var apiKey: String?
        var target: String?
        var enabled: Bool?
    }

    /// 返回 nil 表示 JSON 不合法。
    static func importJSON(_ data: Data) -> (config: TranslationConfig, key: String)? {
        guard let imported = try? JSONDecoder().decode(ImportedConfig.self, from: data) else { return nil }
        var config = TranslationConfig()
        if let url = imported.base_url ?? imported.baseURL { config.baseURL = url }
        if let model = imported.model { config.model = model }
        if let target = imported.target, TranslationConfig.targets.contains(where: { $0.code == target }) { config.target = target }
        config.enabled = imported.enabled ?? true
        return (config, imported.api_key ?? imported.apiKey ?? "")
    }
}

/// 请求体与响应的纯逻辑，单独可测。
enum TranslationWire {
    static func requestBody(text: String, target: String, model: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        let language = TranslationConfig.languageName(for: target)
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 200,
            "messages": [
                ["role": "system", "content": "Translate the user's Chinese text into \(language). Reply with the translation only: no quotes, no explanations, no pinyin."],
                ["role": "user", "content": trimmed],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// 解析 OpenAI 兼容响应；返回 nil 表示没有可用译文。
    static func parseResponse(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        var value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, value.count <= 300 else { return nil }
        return value
    }
}

/// 云端翻译客户端：一次请求一条候选，失败交给调用方回退本地词表。
final class CloudTranslator {
    private var task: URLSessionDataTask?
    private var generation = 0
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func cancel() { task?.cancel(); task = nil; generation += 1 }

    func translate(text: String, config: TranslationConfig, apiKey: String,
                   completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        generation += 1
        let current = generation
        guard let endpoint = config.endpoint, let body = TranslationWire.requestBody(text: text, target: config.target, model: config.model) else {
            completion(.failure(NSError(domain: "liana.translation", code: 1, userInfo: [NSLocalizedDescriptionKey: "配置或文本不可用"])))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self, current == self.generation else { return }
            let result: Result<String, Error>
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(NSError(domain: "liana.translation", code: http.statusCode,
                                          userInfo: [NSLocalizedDescriptionKey: "服务返回 \(http.statusCode)"]))
            } else if let data, let text = TranslationWire.parseResponse(data) {
                result = .success(text)
            } else {
                result = .failure(NSError(domain: "liana.translation", code: 2, userInfo: [NSLocalizedDescriptionKey: "译文为空"]))
            }
            DispatchQueue.main.async { completion(result) }
        }
        task?.resume()
    }
}
