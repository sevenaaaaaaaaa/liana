#if canImport(XCTest)
import Foundation
import UIKit
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

/// Coverage for the host-side quick-phrase editor and its clipboard contract.
final class MobilePhraseBookTests: XCTestCase {
    func testDefaultsAreTenBoundedPhrases() {
        XCTAssertEqual(MobilePhraseBook.defaultPhrases.count, 10)
        XCTAssertEqual(MobilePhraseBook.defaultPhrases.first, "好的")
        XCTAssertTrue(MobilePhraseBook.defaultPhrases.contains("辛苦了"))
        for phrase in MobilePhraseBook.defaultPhrases {
            XCTAssertFalse(phrase.isEmpty)
            XCTAssertLessThanOrEqual(phrase.count, MobilePhraseBook.maximumLength)
        }
    }

    func testNormalizeTrimsDropsBlanksAndDeduplicates() {
        let result = MobilePhraseBook.normalize(" 好的 \n\n谢谢\r\n好的\n  \n收到\n")
        XCTAssertEqual(result.phrases, ["好的", "谢谢", "收到"])
        XCTAssertFalse(result.truncated)
    }

    func testNormalizeCapsLineLengthAndPhraseCount() {
        let longLine = String(repeating: "好", count: MobilePhraseBook.maximumLength + 10)
        let longResult = MobilePhraseBook.normalize(longLine)
        XCTAssertEqual(longResult.phrases.count, 1)
        XCTAssertEqual(longResult.phrases.first?.count, MobilePhraseBook.maximumLength)
        XCTAssertTrue(longResult.truncated)

        let tooMany = (1...25).map { "第\($0)条" }.joined(separator: "\n")
        let countResult = MobilePhraseBook.normalize(tooMany)
        XCTAssertEqual(countResult.phrases.count, MobilePhraseBook.maximumCount)
        XCTAssertEqual(countResult.phrases.last, "第20条")
        XCTAssertTrue(countResult.truncated)

        let exact = (1...20).map { "第\($0)条" }.joined(separator: "\n")
        let exactResult = MobilePhraseBook.normalize(exact)
        XCTAssertEqual(exactResult.phrases.count, 20)
        XCTAssertFalse(exactResult.truncated)
    }

    func testPayloadContractIsPhrasesKindWithOnePerLine() throws {
        let phrases = MobilePhraseBook.normalize("好的\n谢谢\n马上").phrases
        let text = MobilePhraseBook.text(from: phrases)
        XCTAssertEqual(text, "好的\n谢谢\n马上")
        XCTAssertEqual(MobilePhraseBook.parse(text), phrases)

        let item = try KeyboardPayload(kind: "phrases", text: text).pasteboardItem()
        XCTAssertNil(item["public.utf8-plain-text"])
        let data = try XCTUnwrap(item[KeyboardPayload.pasteboardType] as? Data)
        let decoded = try JSONDecoder().decode(KeyboardPayload.self, from: data)
        XCTAssertEqual(decoded.kind, "phrases")
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(decoded.text?.components(separatedBy: "\n"), ["好的", "谢谢", "马上"])
    }

    func testSettingsStayInHostDefaultsAndNormalizeOnLoad() {
        let suite = "liana.phrases.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MobilePhraseBookSettings.load(from: defaults), MobilePhraseBook.defaultPhrases)
        let saved = MobilePhraseBookSettings.save("好的\n谢谢\n好的", to: defaults)
        XCTAssertEqual(saved.phrases, ["好的", "谢谢"])
        XCTAssertEqual(defaults.string(forKey: MobilePhraseBookSettings.storageKey), "好的\n谢谢")
        XCTAssertEqual(MobilePhraseBookSettings.load(from: defaults), ["好的", "谢谢"])

        let tooMany = (1...25).map { "第\($0)条" }.joined(separator: "\n")
        defaults.set(tooMany, forKey: MobilePhraseBookSettings.storageKey)
        XCTAssertEqual(MobilePhraseBookSettings.load(from: defaults).count, MobilePhraseBook.maximumCount)

        defaults.set("", forKey: MobilePhraseBookSettings.storageKey)
        XCTAssertTrue(MobilePhraseBookSettings.load(from: defaults).isEmpty)
    }
}

/// Lightweight UI smoke coverage for the dictionary page that owns the phrase
/// editor. It never touches the clipboard or the keyboard extension.
@MainActor
final class MobilePhraseBookUITests: XCTestCase {
    private func view(with id: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == id { return root }
        for subview in root.subviews {
            if let match = view(with: id, in: subview) { return match }
        }
        return nil
    }

    func testDictionaryPageShowsEditablePhraseCardWithDefaults() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: MobilePhraseBookSettings.storageKey)
        defer {
            if let saved { defaults.set(saved, forKey: MobilePhraseBookSettings.storageKey) }
            else { defaults.removeObject(forKey: MobilePhraseBookSettings.storageKey) }
        }
        defaults.removeObject(forKey: MobilePhraseBookSettings.storageKey)

        let tools = MobileToolsViewController()
        tools.loadViewIfNeeded()
        let tabs = try XCTUnwrap(view(with: "mobile.section", in: tools.view) as? UISegmentedControl)
        tabs.selectedSegmentIndex = 1
        tabs.sendActions(for: .valueChanged)

        let editor = try XCTUnwrap(view(with: "dict.phrases.editor", in: tools.view) as? UITextView)
        XCTAssertEqual(editor.text, MobilePhraseBook.text(from: MobilePhraseBook.defaultPhrases))
        let copy = try XCTUnwrap(view(with: "dict.phrases.copy", in: tools.view) as? UIButton)
        XCTAssertTrue(copy.isEnabled)
        let count = try XCTUnwrap(view(with: "dict.phrases.count", in: tools.view) as? UILabel)
        XCTAssertEqual(count.text, "10/\(MobilePhraseBook.maximumCount) 条 · 每条最多 \(MobilePhraseBook.maximumLength) 字")

        editor.text = "好的\n谢谢\n好的\n"
        tools.textViewDidChange(editor)
        XCTAssertEqual(count.text, "2/\(MobilePhraseBook.maximumCount) 条 · 每条最多 \(MobilePhraseBook.maximumLength) 字")
    }
}
#endif
