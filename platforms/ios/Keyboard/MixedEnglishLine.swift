import Foundation

/// 候选的「英文一行」：把当前中文候选按本地对照表做最长匹配翻译。
///
/// 规则：
/// - 拉丁/数字片段（Wi-Fi、PPT、iPhone、5G）原样保留，不做二次翻译；
/// - 对照表里收录的词按最长优先匹配，英文为空表示虚词（的/了/吧），直接省略；
/// - 未收录的中文原字保留，交给调用方的在线 API 兜底重译，绝不丢字。
final class MixedEnglishLine {
    private let lexicon: MobileLexicon
    private let maxWordLength: Int
    private var cache: [String: String] = [:]
    private let cacheLimit = 64

    init(lexicon: MobileLexicon) {
        self.lexicon = lexicon
        self.maxWordLength = max(1, min(lexicon.glossaryMaxLength(), 8))
    }

    /// 中文候选 → 英文一行；没有可翻译的内容时返回 nil。
    func translate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        if let hit = cache[trimmed] { return hit.isEmpty ? nil : hit }

        let characters = Array(trimmed)
        var pieces: [String] = []
        var pending = ""
        var index = 0

        func flushPending() {
            if !pending.isEmpty { pieces.append(pending); pending = "" }
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
                    guard let english = lexicon.glossary(candidate) else { continue }
                    flushPending()
                    if !english.isEmpty { pieces.append(english) }
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

        var output = pieces.joined(separator: " ")
        while output.contains("  ") { output = output.replacingOccurrences(of: "  ", with: " ") }
        output = output.trimmingCharacters(in: .whitespaces)
        guard !output.isEmpty else { return nil }
        if let first = output.first, first.isLetter { output = first.uppercased() + output.dropFirst() }
        if trimmed.hasSuffix("？") || trimmed.hasSuffix("?") {
            if !output.hasSuffix("?") { output += "?" }
        }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[trimmed] = output
        return output
    }

    private static func isLatinToken(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return character == "-" || character == "_" || character == "." || character == "+" || character == "#"
    }
}
