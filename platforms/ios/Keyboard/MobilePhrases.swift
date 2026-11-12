import Foundation

/// 常用短语：键盘沙盒里的本地列表，主 App 通过
/// KeyboardPayload(kind: "phrases", text: 每行一条) 覆盖。
enum MobilePhrases {
    static let key = "keyboard.phrases"
    static let limit = 20
    static let maxLength = 50

    /// 内置 12 条常用短语，首次使用时直接可用。
    static let builtIn = ["好的", "谢谢", "马上", "稍等", "在吗", "没问题", "收到", "辛苦了", "明天见", "晚安", "可以的", "稍后回复"]

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        guard let stored = defaults.stringArray(forKey: key) else { return builtIn }
        let cleaned = sanitize(stored)
        return cleaned.isEmpty ? builtIn : cleaned
    }

    /// 去空行、去首尾空白、去重、限制条数与单条长度。
    static func sanitize(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= maxLength, !seen.contains(value) else { continue }
            seen.insert(value)
            output.append(value)
            if output.count >= limit { break }
        }
        return output
    }

    static func sanitize(text: String) -> [String] {
        sanitize(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// 保存并返回实际生效的列表；内容为空时不覆盖内置短语。
    @discardableResult
    static func save(text: String, to defaults: UserDefaults = .standard) -> [String] {
        let values = sanitize(text: text)
        guard !values.isEmpty else { return [] }
        defaults.set(values, forKey: key)
        return values
    }

    @discardableResult
    static func save(_ values: [String], to defaults: UserDefaults = .standard) -> [String] {
        let cleaned = sanitize(values)
        guard !cleaned.isEmpty else { return [] }
        defaults.set(cleaned, forKey: key)
        return cleaned
    }
}
