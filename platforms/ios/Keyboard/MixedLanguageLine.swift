import Foundation

/// 翻译行的输出语言。顺序即切换顺序，与 mobile.sqlite 的 gloss 表列一致。
enum TranslateLanguage: String, CaseIterable {
    case en, ja, ko, fr, de, es, ru

    var title: String {
        switch self {
        case .en: return "EN"
        case .ja: return "日"
        case .ko: return "한"
        case .fr: return "FR"
        case .de: return "DE"
        case .es: return "ES"
        case .ru: return "RU"
        }
    }

    var column: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    /// 日文不插空格，其余语言按空格连接。
    var spaced: Bool { self != .ja }
    /// 西文首字母大写；中日韩保持原样。
    var capitalizes: Bool { self != .ja && self != .ko }

    var next: TranslateLanguage {
        let all = Self.allCases
        let index = (all.firstIndex(of: self) ?? 0) + 1
        return all[index % all.count]
    }
}

/// 候选的「目标语言一行」：中文候选 → 英/日/韩/法/德/西/俄。
///
/// 规则与 Rust 侧 liana-gloss 一致（两处实现同一套规则，便于桌面端复用）：
/// - 拉丁/数字片段（Wi-Fi、PPT、iPhone、5G）原样保留；
/// - 对照表最长匹配，空译文（的/了）直接省略；
/// - 查不到的中文原字保留，绝不丢字；英文查不到时再回退到更大的 en_glossary。
final class MixedLanguageLine {
    private let lexicon: MobileLexicon
    private let maxWordLength: Int
    var language: TranslateLanguage = .en
    private var cache: [String: String] = [:]
    private let cacheLimit = 64

    init(lexicon: MobileLexicon) {
        self.lexicon = lexicon
        self.maxWordLength = max(1, min(lexicon.glossMaxLength(), 8))
    }

    func translate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        let key = language.rawValue + "|" + trimmed
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }

        let characters = Array(trimmed)
        var pieces: [String] = []
        var pending = ""
        var index = 0

        func flushPending() {
            if !pending.isEmpty { pieces.append(pending); pending = "" }
        }

        func translated(_ term: String) -> String? {
            if let row = lexicon.gloss(term) { return row[language.column] }
            return language == .en ? lexicon.glossary(term) : nil
        }

        while index < characters.count {
            let character = characters[index]
            if Self.isLatinToken(character) {
                var end = index
                while end < characters.count, Self.isLatinToken(characters[end]) { end += 1 }
                flushPending()
                pieces.append(String(characters[index..<end]))
                index = end
                continue
            }
            var matched = false
            let reach = min(maxWordLength, characters.count - index)
            if reach >= 1 {
                for length in stride(from: reach, through: 1, by: -1) {
                    let candidate = String(characters[index..<(index + length)])
                    guard let value = translated(candidate) else { continue }
                    flushPending()
                    if !value.isEmpty { pieces.append(value) }
                    index += length
                    matched = true
                    break
                }
            }
            if matched { continue }
            pending.append(character)
            index += 1
        }
        flushPending()

        let separator = language.spaced ? " " : ""
        var output = pieces.joined(separator: separator)
        while output.contains("  ") { output = output.replacingOccurrences(of: "  ", with: " ") }
        output = output.trimmingCharacters(in: .whitespaces)
        guard !output.isEmpty else { return nil }
        if language.capitalizes, let first = output.first, first.isASCII, first.isLetter {
            output = first.uppercased() + output.dropFirst()
        }
        if trimmed.hasSuffix("？") || trimmed.hasSuffix("?") {
            if !output.hasSuffix("?") { output += "?" }
        }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = output
        return output
    }

    func invalidate() { cache.removeAll(keepingCapacity: true) }

    private static func isLatinToken(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return character == "-" || character == "_" || character == "." || character == "+" || character == "#"
    }
}


/// 双语模式的总开关。
///
/// 关掉时译文芯片整条隐藏，候选条只占一行；打开时首选候选的目标语言译文常显，
/// 点一下就插上屏。语言本身仍由 TranslationConfig.target 决定（长按芯片可换）。
enum BilingualSettings {
    static let defaultsKey = "liana.bilingual"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
