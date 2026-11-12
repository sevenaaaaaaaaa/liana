import Foundation

/// Speech languages supported by the Liana host app.
///
/// Recognition always runs on the device with Speech.framework; the keyboard
/// extension never records. The same seven languages are offered as
/// simultaneous-interpretation targets through Apple's on-device Translation.
enum VoiceLanguage: String, CaseIterable, Codable, Equatable {
    case zhCN = "zh-CN"
    case enUS = "en-US"
    case jaJP = "ja-JP"
    case koKR = "ko-KR"
    case ruRU = "ru-RU"
    case frFR = "fr-FR"
    case esES = "es-ES"

    static let defaultRecognition: VoiceLanguage = .zhCN

    /// Speech.framework locale identifier, also persisted in preferences.
    var identifier: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Identifier accepted by Translation.framework. Apple lists Mandarin as
    /// zh-Hans rather than the region-oriented zh-CN.
    var translationIdentifier: String { self == .zhCN ? "zh-Hans" : rawValue }

    var nativeName: String {
        switch self {
        case .zhCN: return "中文（简体）"
        case .enUS: return "English"
        case .jaJP: return "日本語"
        case .koKR: return "한국어"
        case .ruRU: return "Русский"
        case .frFR: return "Français"
        case .esES: return "Español"
        }
    }

    var chineseName: String {
        switch self {
        case .zhCN: return "中文"
        case .enUS: return "英语"
        case .jaJP: return "日语"
        case .koKR: return "韩语"
        case .ruRU: return "俄语"
        case .frFR: return "法语"
        case .esES: return "西班牙语"
        }
    }

    /// "English · 英语" — used by the recognition and target menus.
    var menuTitle: String { "\(nativeName) · \(chineseName)" }
}

/// Preferences for the voice page. Injectable defaults keep the logic testable
/// without touching the real preference domain.
enum VoiceLanguageSettings {
    static let recognitionKey = "voice.recognition.language"
    static let translationTargetKey = "voice.translation.target"
    static let translationEnabledKey = "voice.translation.enabled"

    static func recognition(from defaults: UserDefaults = .standard) -> VoiceLanguage {
        guard let raw = defaults.string(forKey: recognitionKey) else { return .defaultRecognition }
        return VoiceLanguage(rawValue: raw) ?? .defaultRecognition
    }

    @discardableResult
    static func saveRecognition(_ language: VoiceLanguage, to defaults: UserDefaults = .standard) -> VoiceLanguage {
        defaults.set(language.rawValue, forKey: recognitionKey)
        return language
    }

    /// The target language must differ from the recognition language; when no
    /// usable value is stored, fall back to a sensible counterpart.
    static func translationTarget(from defaults: UserDefaults = .standard, source: VoiceLanguage) -> VoiceLanguage {
        if let raw = defaults.string(forKey: translationTargetKey), let stored = VoiceLanguage(rawValue: raw), stored != source {
            return stored
        }
        return source == .enUS ? .zhCN : .enUS
    }

    @discardableResult
    static func saveTranslationTarget(_ language: VoiceLanguage, to defaults: UserDefaults = .standard) -> VoiceLanguage {
        defaults.set(language.rawValue, forKey: translationTargetKey)
        return language
    }

    static func translationEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: translationEnabledKey)
    }

    static func saveTranslationEnabled(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: translationEnabledKey)
    }
}
