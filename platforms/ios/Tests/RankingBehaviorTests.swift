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

    private func makeKeyboard() -> RankingKeyboard {
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
            let keyboard = makeKeyboard()
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
            let keyboard = makeKeyboard()
            type(pinyin, keyboard)
            let titles = candidates(keyboard)
            print("RANK bare \(pinyin) => \(titles.prefix(5).joined(separator: " | "))")
            XCTAssertEqual(titles.first, expected, pinyin)
        }
    }

    /// 学习权重：选过的词在新键盘上排第一；再选同码的高频词可以切回。
    func testLearningOverridesAndCanSwitchBack() throws {
        let first = makeKeyboard()
        try commit("成都", pinyin: "chengdu", first)

        let second = makeKeyboard()
        type("chengdu", second)
        let learnedOrder = candidates(second)
        XCTAssertEqual(learnedOrder.first, "成都", "学习后应回到首位")
        // 组合串已经输入过，这里直接点「程度」，不要再 type 一次。
        let index = try XCTUnwrap(learnedOrder.firstIndex(of: "程度"))
        tap("candidate.\(index)", second)
        XCTAssertEqual(second.document.text, "程度")

        let third = makeKeyboard()
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

    // MARK: - 第六轮：候选深度 / 学习同步 / 分段噪声 / 整句模型

    /// 候选深度统一到 24；候选条横向滚动。
    func testCandidateDepthIsTwentyFour() throws {
        let keyboard = makeKeyboard()
        type("shi", keyboard)
        let titles = candidates(keyboard)
        XCTAssertEqual(titles.count, 24)
        let deep = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "candidate.23" })
        XCTAssertFalse(deep.isHidden)
        let strip = try XCTUnwrap(deep.superview?.superview as? UIScrollView)
        XCTAssertGreaterThan(strip.contentSize.width, strip.bounds.width)
    }

    /// 从 Rust 会话候选中选词后，本地学习生效：新键盘同码首选是它。
    func testSessionCandidateSelectionLearnsLocally() throws {
        let keyboard = makeKeyboard()
        type("mingtianqugongsi", keyboard)
        let titles = candidates(keyboard)
        let index = try XCTUnwrap(titles.firstIndex(of: "明天去公司"), "候选: \(titles.prefix(6))")
        tap("candidate.\(index)", keyboard)
        XCTAssertEqual(keyboard.document.text, "明天去公司")

        let lexicon = MobileLexicon(bundle: Bundle(for: Self.self))
        XCTAssertTrue(lexicon.learnedWords(code: "mingtianqugongsi").contains("明天去公司"))

        let next = makeKeyboard()
        type("mingtianqugongsi", next)
        XCTAssertEqual(candidates(next).first, "明天去公司")
    }

    /// 两音节以上却全是单字的分段不进候选，但引擎兜底仍不空白。
    func testComposerDropsAllSingleCharacterSegments() throws {
        let lexicon = MobileLexicon(bundle: Bundle(for: Self.self))
        let composer = MobilePhraseComposer(lexicon: lexicon)
        XCTAssertEqual(composer.candidates("nene", kind: "pinyin"), [], "逐字分段不应成为候选")
        let phrase = composer.candidates("wanshangyiqichifan", kind: "pinyin")
        XCTAssertFalse(phrase.isEmpty)
        XCTAssertTrue(phrase.contains { $0.count > 1 }, "正常短语应保留多字词分段：\(phrase.prefix(5))")

        let engine = MobileEngine()
        engine.sessionFactory = { _, _ in nil }
        let ready = expectation(description: "start")
        engine.onUpdate = { _ in ready.fulfill() }
        engine.start(bundle: Bundle(for: Self.self), mode: "pinyin")
        wait(for: [ready], timeout: 20)
        let fallback = engineUpdate(engine, .feed("nene"))
        XCTAssertFalse(fallback.snapshot.candidates.isEmpty, "兜底仍要有候选")
    }

    /// 整句模型（base.lm 与 base.ifd 同目录）加载后，整句首选率不回归。
    func testSentenceModelKeepsWholeSentenceFirstChoice() throws {
        let bundle = Bundle(for: Self.self)
        let ifd = try XCTUnwrap(bundle.url(forResource: "base", withExtension: "ifd"))
        let model = ifd.deletingLastPathComponent().appendingPathComponent("base.lm")
        let hasModel = FileManager.default.fileExists(atPath: model.path)
        XCTAssertTrue(hasModel, "base.lm 应与 base.ifd 同目录随包")

        let cases: [(String, String)] = [
            ("jintiantianqihenhao", "今天天气很好"),
            ("wanshangyiqichifan", "晚上一起吃饭"),
            ("zhegeshoujizhendehenhao", "这个手机真的很好"),
            ("womendediannaohuaile", "我们的电脑坏了"),
            ("wozaijianadashangxue", "我在加拿大上学"),
            ("nizaiganshenme", "你在干什么"),
            ("womenmingtianzaijianba", "我们明天再见吧"),
            ("womenyiqiqukandianyingba", "我们一起去看电影吧"),
            ("qinggeiwoyibeishui", "请给我一杯水"),
            ("wanshangshidianwoyaoshuijiao", "晚上十点我要睡觉"),
        ]
        let engine = MobileEngine()
        let ready = expectation(description: "start")
        engine.onUpdate = { _ in ready.fulfill() }
        engine.start(bundle: bundle, mode: "pinyin")
        wait(for: [ready], timeout: 20)
        var hits = 0
        for (raw, expected) in cases {
            let update = engineUpdate(engine, .feed(raw))
            XCTAssertFalse(update.snapshot.candidates.isEmpty, raw)
            if update.snapshot.candidates.first == expected { hits += 1 }
            else { print("RANK-LM miss \(raw) -> \(update.snapshot.candidates.prefix(3).joined(separator: " | ")) [\(expected)]") }
            _ = engineUpdate(engine, .clear)
        }
        print("RANK-LM first=\(hits)/\(cases.count)")
        // 无 LM 时这批语料实测 6/10；有 LM 实测 10/10，留一句容差。
        XCTAssertGreaterThanOrEqual(hits, 9, "整句模型下首选率过低")
    }

    private func engineUpdate(_ engine: MobileEngine, _ action: MobileEngine.Action) -> MobileEngine.Update {
        let done = expectation(description: "engine action")
        var result: MobileEngine.Update!
        engine.onUpdate = { result = $0; done.fulfill() }
        engine.submit(action, document: nil)
        wait(for: [done], timeout: 20)
        return result
    }

    /// 上下文只提升对应类别的词；普通词序不受影响。
    func testContextDoesNotPromoteUnrelatedWords() throws {
        let keyboard = makeKeyboard()
        try commit("去", pinyin: "qu", keyboard)
        type("nihao", keyboard)
        XCTAssertEqual(candidates(keyboard).first, "你好")
    }
}