import Foundation

/// 云端翻译的纯逻辑：请求体、响应解析、配置校验、配置导入。
/// 不碰网络、不碰 Keychain，可在命令行直接跑。
@main
struct TranslationAPITests {
    static func main() {
        // 请求体：带模型、带目标语言、拒绝空文本与超长文本
        let body = TranslationWire.requestBody(text: "你好", target: "ja", model: "m1")
        precondition(body != nil, "合法文本应能构造请求体")
        let json = try! JSONSerialization.jsonObject(with: body!) as! [String: Any]
        precondition(json["model"] as? String == "m1", "模型名要进请求体")
        let messages = json["messages"] as! [[String: Any]]
        precondition(messages.count == 2, "应有一条 system + 一条 user")
        precondition((messages[0]["content"] as! String).contains("Japanese"), "目标语言要进系统提示")
        precondition(messages[1]["content"] as! String == "你好", "用户消息应是原文")
        precondition(TranslationWire.requestBody(text: "   ", target: "en", model: "m") == nil, "空文本不应发请求")
        precondition(TranslationWire.requestBody(text: String(repeating: "字", count: 201), target: "en", model: "m") == nil, "超长文本不应发请求")

        // 响应解析
        let ok = #"{"choices":[{"message":{"content":"Hello there"}}]}"#.data(using: .utf8)!
        precondition(TranslationWire.parseResponse(ok) == "Hello there", "应解析出译文")
        let quoted = #"{"choices":[{"message":{"content":"\"你好\""}}]}"#.data(using: .utf8)!
        precondition(TranslationWire.parseResponse(quoted) == "你好", "译文两侧引号应剥掉")
        precondition(TranslationWire.parseResponse(Data("not json".utf8)) == nil, "坏 JSON 不应出译文")
        let blank = #"{"choices":[{"message":{"content":"   "}}]}"#.data(using: .utf8)!
        precondition(TranslationWire.parseResponse(blank) == nil, "空译文不应上屏")

        // 配置校验
        var config = TranslationConfig()
        precondition(config.unusableReason(hasKey: true) != nil, "默认关闭时不可用")
        config.enabled = true
        precondition(config.unusableReason(hasKey: false) != nil, "没有 Key 时不可用")
        precondition(config.unusableReason(hasKey: true) == nil, "开启 + 有 Key 应可用")
        config.baseURL = "http://example.com/v1"
        precondition(config.unusableReason(hasKey: true) != nil, "非 https 地址应拒绝")
        config.baseURL = "https://example.com/v1/"
        precondition(config.endpoint?.absoluteString == "https://example.com/v1/chat/completions", "末尾斜杠要归一")
        config.model = "  "
        precondition(config.unusableReason(hasKey: true) != nil, "空模型应拒绝")

        // 语言循环
        precondition(TranslationConfig.next(after: "en") == "ja", "EN 下一个是日文")
        precondition(TranslationConfig.next(after: "ru") == "en", "俄文之后回到 EN")

        // 从剪贴板 JSON 导入（蛇形字段）
        let imported = #"{"base_url":"https://api.example.com/v1","model":"m2","api_key":"sk-test","target":"ko","enabled":true}"#.data(using: .utf8)!
        let parsed = TranslationConfigStore.importJSON(imported)
        precondition(parsed != nil, "合法配置应能导入")
        precondition(parsed!.config.baseURL == "https://api.example.com/v1", "base_url 应映射")
        precondition(parsed!.config.model == "m2", "model 应映射")
        precondition(parsed!.config.target == "ko", "target 应映射")
        precondition(parsed!.config.enabled, "enabled 应映射")
        precondition(parsed!.key == "sk-test", "api_key 应单独返回（进 Keychain）")
        precondition(TranslationConfigStore.importJSON(Data("nope".utf8)) == nil, "坏 JSON 应拒绝导入")

        print("云端翻译纯逻辑：请求体 / 响应解析 / 配置校验 / 导入 全部通过")
    }
}
