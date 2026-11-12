#if canImport(XCTest)
import Foundation
import XCTest

/// Pure-logic coverage for the seven-language voice page and simultaneous
/// interpretation. These tests never touch the microphone, Speech, or the
/// Translation framework, so they also run on simulators without language packs.
final class VoiceLanguageFeatureTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "liana.voice.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSevenRecognitionLanguagesHaveStableIdentifiers() {
        XCTAssertEqual(VoiceLanguage.allCases.count, 7)
        XCTAssertEqual(VoiceLanguage.allCases.map(\.identifier), ["zh-CN", "en-US", "ja-JP", "ko-KR", "ru-RU", "fr-FR", "es-ES"])
        XCTAssertEqual(VoiceLanguage.zhCN.translationIdentifier, "zh-Hans")
        XCTAssertEqual(VoiceLanguage.enUS.translationIdentifier, "en-US")
        for language in VoiceLanguage.allCases {
            XCTAssertFalse(language.nativeName.isEmpty)
            XCTAssertFalse(language.chineseName.isEmpty)
            XCTAssertTrue(language.menuTitle.contains(" · "))
            XCTAssertEqual(language.locale.identifier, language.identifier)
        }
    }

    func testRecognitionSelectionPersistsAndFallsBackToChinese() {
        XCTAssertEqual(VoiceLanguageSettings.recognition(from: defaults), .zhCN)
        XCTAssertEqual(VoiceLanguageSettings.saveRecognition(.jaJP, to: defaults), .jaJP)
        XCTAssertEqual(VoiceLanguageSettings.recognition(from: defaults), .jaJP)
        defaults.set("xx-YY", forKey: VoiceLanguageSettings.recognitionKey)
        XCTAssertEqual(VoiceLanguageSettings.recognition(from: defaults), .zhCN)
    }

    func testTranslationPreferencesPersistAndNeverTargetTheSource() {
        XCTAssertTrue(VoiceLanguageSettings.translationTarget(from: defaults, source: .zhCN) == .enUS)
        XCTAssertTrue(VoiceLanguageSettings.translationTarget(from: defaults, source: .enUS) == .zhCN)
        VoiceLanguageSettings.saveTranslationTarget(.frFR, to: defaults)
        XCTAssertEqual(VoiceLanguageSettings.translationTarget(from: defaults, source: .zhCN), .frFR)
        VoiceLanguageSettings.saveTranslationTarget(.zhCN, to: defaults)
        XCTAssertEqual(VoiceLanguageSettings.translationTarget(from: defaults, source: .zhCN), .enUS)
        XCTAssertFalse(VoiceLanguageSettings.translationEnabled(from: defaults))
        VoiceLanguageSettings.saveTranslationEnabled(true, to: defaults)
        XCTAssertTrue(VoiceLanguageSettings.translationEnabled(from: defaults))
    }

    func testThrottleDebouncesAndDeduplicatesPartials() {
        var throttle = VoiceTranslationThrottle(debounce: 0.8)
        XCTAssertFalse(throttle.offer("   ", at: 10))
        XCTAssertTrue(throttle.offer(" 你好 ", at: 10))
        XCTAssertFalse(throttle.offer("你好", at: 10.2))
        XCTAssertNil(throttle.take(at: 10.3))
        XCTAssertNil(throttle.take(at: 10.79, tolerance: 0))
        XCTAssertEqual(throttle.take(at: 10.8, tolerance: 0), "你好")
        XCTAssertFalse(throttle.offer("你好", at: 11))
        XCTAssertTrue(throttle.offer("你好世界", at: 12))
        XCTAssertEqual(throttle.take(at: 12.8, tolerance: 0), "你好世界")
        XCTAssertFalse(throttle.hasPending)
    }

    func testThrottleCanForceTheFinalTextAndRetryAFailedTranslation() {
        var throttle = VoiceTranslationThrottle(debounce: 0.8)
        XCTAssertTrue(throttle.offer("第一句", at: 1))
        XCTAssertEqual(throttle.take(at: 1.05, force: true), "第一句")
        throttle.failed("第一句")
        XCTAssertTrue(throttle.offer("第一句", at: 2))
        XCTAssertEqual(throttle.take(at: 2.02, force: true), "第一句")
        throttle.reset()
        XCTAssertNil(throttle.pendingText)
        XCTAssertNil(throttle.requestedText)
    }

    func testTranscriptComposerSeparatesOriginalAndTranslation() {
        XCTAssertEqual(VoiceTranscriptComposer.compose(original: "你好", translation: nil, target: .enUS), "你好")
        XCTAssertEqual(VoiceTranscriptComposer.compose(original: "你好", translation: "   ", target: .enUS), "你好")
        XCTAssertEqual(
            VoiceTranscriptComposer.compose(original: "你好\n", translation: " Hello ", target: .enUS),
            "你好\n\n【译文 · English】\nHello"
        )
        XCTAssertEqual(
            VoiceTranscriptComposer.compose(original: "你好", translation: "こんにちは", target: .jaJP),
            "你好\n\n【译文 · 日本語】\nこんにちは"
        )
        XCTAssertEqual(
            VoiceTranscriptComposer.compose(original: "", translation: "Hello", target: .enUS),
            "【译文 · English】\nHello"
        )
    }

    func testComposedTextStillUsesTheExistingKeyboardTextPayload() throws {
        let text = VoiceTranscriptComposer.compose(original: "原文", translation: "translated", target: .enUS)
        let item = try KeyboardPayload(kind: "text", text: text).pasteboardItem()
        XCTAssertEqual(item["public.utf8-plain-text"] as? String, text)
        let data = try XCTUnwrap(item[KeyboardPayload.pasteboardType] as? Data)
        let decoded = try JSONDecoder().decode(KeyboardPayload.self, from: data)
        XCTAssertEqual(decoded.kind, "text")
        XCTAssertEqual(decoded.text, text)
        XCTAssertTrue(decoded.text?.contains("原文") == true)
        XCTAssertTrue(decoded.text?.contains("translated") == true)
    }
}
#endif
