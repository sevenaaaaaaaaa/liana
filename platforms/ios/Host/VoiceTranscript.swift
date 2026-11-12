import Foundation

/// Builds the text that is copied back to the keyboard. The original stays
/// first so the existing "copy text then paste or receive in Liana" flow keeps
/// working; a translation, when present, is appended in its own section.
enum VoiceTranscriptComposer {
    static let separator = "\n\n"

    static func translationHeader(for target: VoiceLanguage) -> String {
        "【译文 · \(target.nativeName)】"
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compose(original: String, translation: String?, target: VoiceLanguage?) -> String {
        guard let translation, let target else { return original }
        let translated = normalized(translation)
        guard !translated.isEmpty else { return original }
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return translationHeader(for: target) + "\n" + translated
        }
        return source + separator + translationHeader(for: target) + "\n" + translated
    }
}

/// Debounce and de-duplication for streaming partial recognition results.
///
/// Partial transcripts change several times per second; translating every one
/// would keep the on-device translator busy and make the UI flicker. The gate
/// only lets a changed transcript through after it has been stable for
/// `debounce` seconds, and remembers the text already submitted so identical
/// partials are not translated twice. Time is injected so tests stay instant.
struct VoiceTranslationThrottle {
    static let defaultDebounce: TimeInterval = 0.8

    let debounce: TimeInterval
    private(set) var pendingText: String?
    private(set) var requestedText: String?
    private var pendingAt: TimeInterval = 0

    init(debounce: TimeInterval = VoiceTranslationThrottle.defaultDebounce) {
        self.debounce = debounce
    }

    var hasPending: Bool { pendingText != nil }

    /// Records a new transcript. Returns `true` when the caller should schedule
    /// a translation; repeated, empty, or unchanged text returns `false`.
    @discardableResult
    mutating func offer(_ text: String, at now: TimeInterval) -> Bool {
        let normalized = VoiceTranscriptComposer.normalized(text)
        guard !normalized.isEmpty, normalized != requestedText, normalized != pendingText else { return false }
        pendingText = normalized
        pendingAt = now
        return true
    }

    /// Returns the pending transcript once the debounce window has elapsed.
    /// `force` is used for the final result when the user stops recording.
    mutating func take(at now: TimeInterval, tolerance: TimeInterval = 0.05, force: Bool = false) -> String? {
        guard let text = pendingText else { return nil }
        guard force || now - pendingAt + tolerance >= debounce else { return nil }
        pendingText = nil
        requestedText = text
        return text
    }

    /// Allows a failed translation to be retried for the same transcript.
    mutating func failed(_ text: String) {
        if requestedText == text { requestedText = nil }
    }

    mutating func reset() {
        pendingText = nil
        requestedText = nil
        pendingAt = 0
    }
}
