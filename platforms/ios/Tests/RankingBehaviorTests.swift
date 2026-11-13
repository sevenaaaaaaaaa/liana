import XCTest
import UIKit
import SQLite3

/// 上下文 / 学习权重 / 同音歧义的首选排序回归。
///
/// 规则：学习过的词 > 上下文类别（place/person）命中 > 原顺序（会话/词频）。
/// 裸打顺序必须保持词频语义；上下文只在触发词后生效。
private final class RankingDocument: NSObject, UITextDocumentProxy {
    var text = ""
    var hasText: Bool { !text.isEmpty }
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier = UUID()
    func insertText(_ value: String) { text += value }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}

private final class RankingKeyboard: KeyboardViewController {
    let document = RankingDocument()
    override var textDocumentProxy: UITextDocumentProxy { document }
}

@MainActor
final class RankingBehaviorTests: XCTestCase {
    private var savedMethod: Any?
    private var savedPreferences: Data?

    override func setUp() {
        super.setUp()
        savedMethod = UserDefaults.standard.object(forKey: "keyboard.method")
        UserDefaults.standard.removeObject(forKey: "keyboard.method")
        savedPreferences = UserDefaults.standard.data(forKey: "keyboard.layout.v1")
        KeyboardPreferences().save()
        // 学习记录持久化在键盘沙盒里；每个用例从干净状态开始。
        MobileLexicon(bundle: Bundle(for: Self.self)).resetLearning()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMethod, forKey: "keyboard.method")
        UserDefaults.standard.set(savedPreferences, forKey: "keyboard.layout.v1")
        UIView.setAnimationsEnabled(true)
        super.tearDown()
    }

    private func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }

    private func keyboard() -> RankingKeyboard {
        let value = RankingKeyboard()
        value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0, y: 0, width: 375, height: 301)
        value.view.setNeedsLayout()
        value.view.layoutIfNeeded()
        drain(value)
        return value
    }

    private func drain(_ keyboard: RankingKeyboard) {
        let idle = expectation(description: "decode queue idle")
        keyboard.whenInputIdle { idle.fulfill() }
        wait(for: [idle], timeout: 20)
    }

    private func type(_ value: String, _ keyboard: RankingKeyboard) {
        let buttons = allViews(keyboard.view).compactMap { $0 as? UIButton }
        for character in value {
            guard let key = buttons.first(where: { $0.accessibilityIdentifier == "key." + String(character) }) else {
                XCTFail("缺少按键 \(character)（\(value)）")
                return
            }
            key.sendActions(for: .touchUpInside)
        }
        drain(keyboard)
        keyboard.view.layoutIfNeeded()
    }

    private func tap(_ id: String, _ keyboard: RankingKeyboard) {
        if let button = allViews(keyboard.view).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == id }) {
            button.sendActions(for: .touchUpInside)
        }
        drain(keyboard)
    }

    private func candidates(_ keyboard: RankingKeyboard) -> [String] {
        allViews(keyboard.view).compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier?.hasPrefix("candidate.") == true && !$0.isHidden }
            .sorted {
                let left = Int(($0.accessibilityIdentifier ?? "").dropFirst("candidate.".count)) ?? 0
                let right = Int(($1.accessibilityIdentifier ?? "").dropFirst("candidate.".count)) ?? 0
                return left < right
            }
            .map { $0.title(for: .normal) ?? "" }
    }

    /// 输入 pinyin 并点选 title 对应的候选上屏。
    private func commit(_ title: String, pinyin: String, _ keyboard: RankingKeyboard) throws {
        type(pinyin, keyboard)
        let titles = candidates(keyboard)
        let index = try XCTUnwrap(titles.firstIndex(of: title), "\(pinyin) 候选里没有 \(title)：\(titles)")
        tap("candidate.\(index)", keyboard)
        XCTAssertTrue(keyboard.document.text.hasSuffix(title), "\(title) 未上屏")
    }

    /// 上下文命中：去/在/到 + 地名 → place；叫 + 人名 → person。
    func testContextPromotesPlaceAndPerson() throws {
        let cases: [(triggerPinyin: String, trigger: String, targetPinyin: String, expected: String)] = [
            ("qu", "去", "chengdu", "成都"),
            ("zai", "在", "xian", "西安"),
            ("dao", "到", "chongqing", "重庆"),
            ("qu", "去", "jinan", "济南"),
            ("zai", "在", "qingdao", "青岛"),
            ("jiao", "叫", "lihua", "李华"),
        ]
        for item in cases {
            let keyboard = keyboard()
            try commit(item.trigger, pinyin: item.triggerPinyin, keyboard)
            type(item.targetPinyin, keyboard)
            let titles = candidates(keyboard)
            print("RANK ctx(\(item.trigger)) \(item.targetPinyin) => \(titles.prefix(5).joined(separator: " | "))")
            XCTAssertEqual(titles.first, item.expected, "\(item.trigger)+\(item.targetPinyin)")
        }
    }

    /// 裸打顺序保持词频语义（上下文只在触发词之后生效）。
    func testBareOrderKeepsFrequency() throws {
        for (pinyin, expected) in [("chengdu", "程度"), ("xian", "现"), ("lihua", "梨花")] {
            let keyboard = keyboard()
            type(pinyin, keyboard)
            let titles = candidates(keyboard)
            print("RANK bare \(pinyin) => \(titles.prefix(5).joined(separator: " | "))")
            XCTAssertEqual(titles.first, expected, pinyin)
        }
    }

    /// 学习权重：选过的词在新键盘上排第一；再选同码的高频词可以切回。
    func testLearningOverridesAndCanSwitchBack() throws {
        let first = keyboard()
        try commit("成都", pinyin: "chengdu", first)

        let second = keyboard()
        type("chengdu", second)
        let learnedOrder = candidates(second)
        XCTAssertEqual(learnedOrder.first, "成都", "学习后应回到首位")
        // 组合串已经输入过，这里直接点「程度」，不要再 type 一次。
        let index = try XCTUnwrap(learnedOrder.firstIndex(of: "程度"))
        tap("candidate.\(index)", second)
        XCTAssertEqual(second.document.text, "程度")

        let third = keyboard()
        type("chengdu", third)
        let titles = candidates(third)
        print("RANK learned-switch chengdu => \(titles.prefix(5).joined(separator: " | "))")
        XCTAssertEqual(titles.first, "程度", "重新学习后应切回")
    }

    /// 旧词库没有 tags 表时优雅降级：词库可用，标签查询返回 false。
    func testOldDictionaryWithoutTagsDegradesGracefully() throws {
        let path = NSTemporaryDirectory() + "liana-no-tags-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        sqlite3_exec(database, "CREATE TABLE words(word TEXT,code TEXT,freq INTEGER,kind TEXT); INSERT INTO words VALUES('成都','chengdu',20000,'pinyin');", nil, nil, nil)
        sqlite3_close(database)

        let lexicon = MobileLexicon(bundle: Bundle(for: Self.self), baseURL: URL(fileURLWithPath: path))
        XCTAssertTrue(lexicon.hasBase)
        XCTAssertFalse(lexicon.hasTags)
        XCTAssertEqual(lexicon.exact("chengdu", kind: "pinyin").first?.word, "成都")
        XCTAssertFalse(lexicon.hasTag("成都", tag: "place"))
    }

    /// 上下文只提升对应类别的词；普通词序不受影响。
    func testContextDoesNotPromoteUnrelatedWords() throws {
        let keyboard = keyboard()
        try commit("去", pinyin: "qu", keyboard)
        type("nihao", keyboard)
        XCTAssertEqual(candidates(keyboard).first, "你好")
    }
}
