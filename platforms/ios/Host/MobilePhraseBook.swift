import Foundation

/// Host-side rules for the configurable keyboard quick phrases.
///
/// The host and the keyboard extension do not share an App Group, so the
/// phrases are handed over explicitly with `KeyboardPayload(kind: "phrases",
/// text: ...)`: one phrase per line. This type keeps parsing, de-duplication,
/// limits, and persistence testable without UIKit.
enum MobilePhraseBook {
    /// First-launch suggestions; editing is entirely optional.
    static let defaultPhrases = [
        "好的", "谢谢", "马上", "稍等", "在吗",
        "没问题", "收到", "辛苦了", "明天见", "晚安"
    ]
    static let maximumCount = 20
    static let maximumLength = 50

    struct Result: Equatable {
        var phrases: [String]
        /// True when an input line exceeded `maximumLength` or the number of
        /// non-empty unique lines exceeded `maximumCount`.
        var truncated: Bool
    }

    /// Trims every line, drops blanks, removes duplicates (first occurrence
    /// wins), caps each phrase at 50 characters, and caps the list at 20.
    static func normalize(_ text: String) -> Result {
        var phrases: [String] = []
        var seen = Set<String>()
        var truncated = false
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.count > maximumLength {
                line = String(line.prefix(maximumLength))
                truncated = true
            }
            guard seen.insert(line).inserted else { continue }
            phrases.append(line)
        }
        if phrases.count > maximumCount {
            phrases = Array(phrases.prefix(maximumCount))
            truncated = true
        }
        return Result(phrases: phrases, truncated: truncated)
    }

    /// The on-clipboard contract shared with the keyboard: LF-separated lines.
    static func text(from phrases: [String]) -> String {
        phrases.joined(separator: "\n")
    }

    /// Convenience for reading the handoff back in tests or future importers.
    static func parse(_ text: String) -> [String] {
        normalize(text).phrases
    }
}

/// Persistence in the host app's own defaults. The keyboard keeps its own
/// sandbox, so nothing here is shared implicitly.
enum MobilePhraseBookSettings {
    static let storageKey = "host.phrases"

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.string(forKey: storageKey) else { return MobilePhraseBook.defaultPhrases }
        return MobilePhraseBook.normalize(raw).phrases
    }

    /// Saves the normalized lines and reports whether anything was truncated.
    @discardableResult
    static func save(_ text: String, to defaults: UserDefaults = .standard) -> MobilePhraseBook.Result {
        let result = MobilePhraseBook.normalize(text)
        defaults.set(MobilePhraseBook.text(from: result.phrases), forKey: storageKey)
        return result
    }
}
