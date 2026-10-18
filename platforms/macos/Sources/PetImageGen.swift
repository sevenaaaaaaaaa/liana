import AppKit
import Security

/// 形象工坊的「AI 补全表情」：只有一张「平时」图时，用用户自己配置的图像生成服务按每个表情的提示词生成其余图片。
///
/// 这是松萝里**唯一会把图片上传到第三方**的功能：默认未配置；每次生成都由用户点击触发，
/// 上传的只有「平时」图（铺白底后），API Key 存在系统钥匙串，不写进偏好文件。

enum PetImageGenProvider: String, CaseIterable, Identifiable {
    case openai, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: return "OpenAI 兼容（图像编辑）"
        case .gemini: return "Google Gemini（图像模型）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-image-1"
        case .gemini: return "gemini-2.5-flash-image"
        }
    }
}

struct PetImageGenConfig {
    var provider: PetImageGenProvider = .openai
    var baseURL = ""
    var model = ""

    var effectiveBaseURL: String { baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultBaseURL : baseURL }
    var effectiveModel: String { model.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultModel : model }

    private static let key = "LianaPetImageGen"

    static func load() -> PetImageGenConfig {
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var config = PetImageGenConfig()
        config.provider = PetImageGenProvider(rawValue: dict["provider"] as? String ?? "") ?? .openai
        config.baseURL = dict["baseURL"] as? String ?? ""
        config.model = dict["model"] as? String ?? ""
        return config
    }

    func save() {
        UserDefaults.standard.set(["provider": provider.rawValue, "baseURL": baseURL, "model": model], forKey: Self.key)
    }
}

/// API Key 存钥匙串（每个服务商一条），不进 UserDefaults。
enum PetImageGenKeychain {
    private static let service = "dev.liana.pet.imagegen"

    static func get(_ provider: PetImageGenProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func set(_ value: String, for provider: PetImageGenProvider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

enum PetImageGen {
    static var isConfigured: Bool { PetImageGenKeychain.get(PetImageGenConfig.load().provider) != nil }

    /// 发给模型的提示词（英文对图像模型的遵循度更好）：严格保持人物一致，只改表情和手势。
    static func prompt(for role: PuppetRole) -> String {
        """
        Use the provided image as the exact reference. Keep the very same character: identical face and facial features, \
        hairstyle and hair color, outfit, body shape, art style and lighting. Keep the same camera distance and framing, \
        the same position and size of the character in the frame, facing the camera, centered, on a plain pure white \
        background, a single character, no text, no watermark, no extra objects. \
        Only change the facial expression and hand gesture: \(role.englishPhrase).
        """
    }

    /// 参考图：抠好的「平时」图铺白底、长边不超过 1024（上传量小，模型也更好理解）
    static func referencePNG(from png: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: png), let cg = rep.cgImage else { return nil }
        let scale = min(1, 1024 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        // 留一点白边，构图更接近一张正常的立绘
        let pad = Int(CGFloat(h) * 0.06)
        guard let ctx = CGContext(data: nil, width: w + pad * 2, height: h + pad * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w + pad * 2, height: h + pad * 2))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: pad, y: pad, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    static func generate(role: PuppetRole, reference: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        let config = PetImageGenConfig.load()
        guard let key = PetImageGenKeychain.get(config.provider) else {
            return completion(.failure(PuppetError.message("还没有配置 API Key")))
        }
        generate(role: role, reference: reference, config: config, key: key, completion: completion)
    }

    /// 指定配置与 Key（开发自检用，不读写用户的偏好与钥匙串）
    static func generate(role: PuppetRole, reference: Data, config: PetImageGenConfig, key: String,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        Task {
            let result: Result<Data, Error>
            do {
                switch config.provider {
                case .openai: result = .success(try await openAI(config, key: key, prompt: prompt(for: role), image: reference))
                case .gemini: result = .success(try await gemini(config, key: key, prompt: prompt(for: role), image: reference))
                }
            } catch {
                result = .failure(error)
            }
            await MainActor.run { completion(result) }
        }
    }

    // MARK: OpenAI 兼容：POST {base}/images/edits（multipart）

    private static func openAI(_ config: PetImageGenConfig, key: String, prompt: String, image: Data,
                               highFidelity: Bool = true) async throws -> Data {
        guard let url = URL(string: config.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/images/edits") else {
            throw PuppetError.message("服务地址无效")
        }
        let boundary = "liana-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", config.effectiveModel)
        field("prompt", prompt)
        field("n", "1")
        field("size", "1024x1536")
        if highFidelity && config.effectiveModel.hasPrefix("gpt-image") { field("input_fidelity", "high") }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(image)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            // 有的兼容服务不认 input_fidelity：去掉再试一次
            if highFidelity, status == 400, message.contains("input_fidelity") {
                return try await openAI(config, key: key, prompt: prompt, image: image, highFidelity: false)
            }
            throw PuppetError.message("生成失败：\(message)")
        }
        guard let first = (json?["data"] as? [[String: Any]])?.first else { throw PuppetError.message("服务没有返回图片") }
        if let b64 = first["b64_json"] as? String, let png = Data(base64Encoded: b64) { return png }
        if let link = first["url"] as? String, let imageURL = URL(string: link) {
            return try await URLSession.shared.data(from: imageURL).0
        }
        throw PuppetError.message("服务没有返回图片")
    }

    // MARK: Gemini：POST {base}/models/{model}:generateContent

    private static func gemini(_ config: PetImageGenConfig, key: String, prompt: String, image: Data) async throws -> Data {
        let base = config.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models/\(config.effectiveModel):generateContent") else {
            throw PuppetError.message("服务地址无效")
        }
        let payload: [String: Any] = [
            "contents": [["parts": [
                ["inline_data": ["mime_type": "image/png", "data": image.base64EncodedString()]],
                ["text": prompt],
            ]]],
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw PuppetError.message("生成失败：\(message)")
        }
        let parts = (((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        for part in parts {
            let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any]
            if let b64 = inline?["data"] as? String, let png = Data(base64Encoded: b64) { return png }
        }
        let refusal = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        throw PuppetError.message(refusal.isEmpty ? "服务没有返回图片" : "服务没有生成图片：\(refusal.prefix(120))")
    }
}
