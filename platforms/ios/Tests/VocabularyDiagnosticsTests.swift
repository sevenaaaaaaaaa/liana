import XCTest
import UIKit

/// 词库覆盖与候选召回的正式回归测试（前身是临时诊断：empty=0/97、wrong-first=29）。
///
/// 断言分三层，且与词库数据解耦（旧 5 万词库也能跑）：
/// 1. 任何输入都必须有候选（empty == 0）；
/// 2. 词库已收录的期望词必须出现在候选里（缺词的记录为「待数据补齐」）；
/// 3. 期望词被词库收录后必须排第一（同音歧义词除外，见 tolerant）。
private final class VocabularyDocument: NSObject, UITextDocumentProxy {
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

private final class VocabularyKeyboard: KeyboardViewController {
    let document = VocabularyDocument()
    override var textDocumentProxy: UITextDocumentProxy { document }
}

@MainActor
final class VocabularyDiagnosticsTests: XCTestCase {
    /// 97 条真实输入：生活用品／学科／办公／软件 App／AI／医疗／养生／科普／金融／诗歌／
    /// 人名／地名／网络流行语／年度盘点／基础词。
    private static let corpus: [(String, String)] = [
        ("bingxiang", "冰箱"), ("kongtiao", "空调"), ("xiyiji", "洗衣机"), ("dianfanguo", "电饭锅"),
        ("yashua", "牙刷"), ("maojin", "毛巾"), ("zhentou", "枕头"), ("beizi", "被子"),
        ("shuxue", "数学"), ("wuli", "物理"), ("huaxue", "化学"), ("shengwu", "生物"),
        ("lishi", "历史"), ("dili", "地理"), ("zhengzhi", "政治"),
        ("dayinji", "打印机"), ("fuyinji", "复印机"), ("wenjianjia", "文件夹"), ("dingshuji", "订书机"),
        ("bianqian", "便签"), ("huixingzhen", "回形针"),
        ("weixin", "微信"), ("zhifubao", "支付宝"), ("taobao", "淘宝"), ("douyin", "抖音"),
        ("xiaohongshu", "小红书"), ("pinduoduo", "拼多多"), ("feishu", "飞书"), ("dingding", "钉钉"),
        ("tengxunhuiyi", "腾讯会议"), ("jianying", "剪映"),
        ("rengongzhineng", "人工智能"), ("damoxing", "大模型"), ("jiqixuexi", "机器学习"),
        ("shenduxuexi", "深度学习"), ("shenjingwangluo", "神经网络"), ("tishici", "提示词"),
        ("xiangliangshujuku", "向量数据库"), ("weidiao", "微调"), ("tuili", "推理"),
        ("gaoxueya", "高血压"), ("tangniaobing", "糖尿病"), ("ganmao", "感冒"), ("fashao", "发烧"),
        ("xiaoyanyao", "消炎药"), ("tijian", "体检"), ("xindiantu", "心电图"),
        ("yangsheng", "养生"), ("aijiu", "艾灸"), ("baguan", "拔罐"), ("guasha", "刮痧"),
        ("guanghezuoyong", "光合作用"), ("liangzilixue", "量子力学"), ("xiangduilun", "相对论"),
        ("heidong", "黑洞"),
        ("jijin", "基金"), ("gupiao", "股票"), ("zhaiquan", "债券"), ("lilv", "利率"),
        ("tongzhang", "通胀"), ("jiangzhun", "降准"), ("caibao", "财报"),
        ("chuangqianmingyueguang", "床前明月光"), ("chunmianbujuexiao", "春眠不觉晓"),
        ("jutouwangmingyue", "举头望明月"),
        ("zhangsan", "张三"), ("lisi", "李四"), ("wangxiaoming", "王小明"), ("ouyangnana", "欧阳娜娜"),
        ("beijing", "北京"), ("shanghai", "上海"), ("hangzhou", "杭州"), ("shenzhen", "深圳"),
        ("chengdu", "成都"), ("xian", "西安"), ("wulumuqi", "乌鲁木齐"),
        ("kuangquanshui", "矿泉水"), ("baowenbei", "保温杯"), ("chongdianbao", "充电宝"),
        ("shujuxian", "数据线"), ("erji", "耳机"),
        ("neijuan", "内卷"), ("pofang", "破防"), ("tangping", "躺平"), ("bailan", "摆烂"),
        ("ganfan", "干饭"), ("dagongren", "打工人"), ("juejuezi", "绝绝子"), ("yuanyuzhou", "元宇宙"),
        ("niandupandian", "年度盘点"), ("shidaxinwen", "十大新闻"), ("nianduguanjianci", "年度关键词"),
        ("nihao", "你好"), ("women", "我们"), ("jintiantianqi", "今天天气"),
        ("mingtianqugongsi", "明天去公司"), ("beijingshanghai", "北京上海"),
    ]

    /// 同音歧义词：只要求期望词出现在候选里，不强求第一。
    private static let tolerant: Set<String> = [
        "beizi", "lisi", "xian", "chengdu", "caibao", "jianying", "bianqian",
    ]

    /// 不依赖词库收录的整句（分段组合/会话职责）。
    private static let composedFirst: [(String, String)] = [
        ("jintiantianqi", "今天天气"), ("mingtianqugongsi", "明天去公司"),
        ("beijingshanghai", "北京上海"), ("nihao", "你好"), ("women", "我们"),
    ]

    private var savedMethod: Any?
    private var savedPreferences: Data?
    private var lexicon: MobileLexicon!

    override func setUp() {
        super.setUp()
        savedMethod = UserDefaults.standard.object(forKey: "keyboard.method")
        UserDefaults.standard.removeObject(forKey: "keyboard.method")
        savedPreferences = UserDefaults.standard.data(forKey: "keyboard.layout.v1")
        KeyboardPreferences().save()
        lexicon = MobileLexicon(bundle: Bundle(for: Self.self))
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMethod, forKey: "keyboard.method")
        UserDefaults.standard.set(savedPreferences, forKey: "keyboard.layout.v1")
        UIView.setAnimationsEnabled(true)
        super.tearDown()
    }

    private func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }

    private func keyboard() -> VocabularyKeyboard {
        let value = VocabularyKeyboard()
        value.loadViewIfNeeded()
        value.view.frame = CGRect(x: 0, y: 0, width: 375, height: 301)
        value.view.setNeedsLayout()
        value.view.layoutIfNeeded()
        drain(value)
        return value
    }

    private func drain(_ keyboard: VocabularyKeyboard) {
        let idle = expectation(description: "decode queue idle")
        keyboard.whenInputIdle { idle.fulfill() }
        wait(for: [idle], timeout: 20)
    }

    private func type(_ value: String, _ keyboard: VocabularyKeyboard) {
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

    private func candidates(_ keyboard: VocabularyKeyboard) -> [String] {
        allViews(keyboard.view).compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier?.hasPrefix("candidate.") == true && !$0.isHidden }
            .sorted {
                let left = Int(($0.accessibilityIdentifier ?? "").dropFirst("candidate.".count)) ?? 0
                let right = Int(($1.accessibilityIdentifier ?? "").dropFirst("candidate.".count)) ?? 0
                return left < right
            }
            .map { $0.title(for: .normal) ?? "" }
    }

    private func clear(_ keyboard: VocabularyKeyboard) {
        if let button = allViews(keyboard.view).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "composition.clear" }) {
            button.sendActions(for: .touchUpInside)
        }
        drain(keyboard)
    }

    /// 97 条语料：empty 必须为 0；词库已收录的期望词必须出现在候选里。
    func testVocabularyCorpusNeverEmptyAndKeepsExpectedWords() throws {
        let keyboard = keyboard()
        var empty: [String] = []
        var hidden: [(String, String)] = []
        var pendingData: [String] = []
        var firstMismatch: [(String, String, String)] = []
        for (pinyin, expected) in Self.corpus {
            type(pinyin, keyboard)
            let titles = candidates(keyboard)
            if titles.isEmpty { empty.append(pinyin) }
            if lexicon.contains(word: expected, code: pinyin) {
                if !titles.contains(expected) { hidden.append((pinyin, expected)) }
            } else if !pendingData.contains(pinyin) {
                pendingData.append(pinyin)
            }
            if let first = titles.first, first != expected {
                firstMismatch.append((pinyin, expected, first))
            }
            clear(keyboard)
        }
        print("VOCAB total=\(Self.corpus.count) empty=\(empty.count) hidden=\(hidden.count) pendingData=\(pendingData.count) firstMismatch=\(firstMismatch.count)")
        if !firstMismatch.isEmpty { print("VOCAB-FIRST-MISMATCH \(firstMismatch.map { "\($0.0):\($0.1)->\($0.2)" })") }
        if !pendingData.isEmpty { print("VOCAB-PENDING-DATA \(pendingData.joined(separator: ","))") }
        XCTAssertTrue(empty.isEmpty, "以下输入没有候选：\(empty)")
        XCTAssertTrue(hidden.isEmpty, "期望词不在候选里：\(hidden.map { "\($0.0)->\($0.1)" })")
    }

    /// 词库收录后期望词必须排第一（同音歧义词退化为「出现在候选里」）。
    func testExpectedWordRanksFirstOnceShipped() throws {
        let keyboard = keyboard()
        var checked = 0
        var pendingData: [String] = []
        var wrongFirst: [(String, String, String)] = []
        for (pinyin, expected) in Self.corpus where !Self.tolerant.contains(pinyin) {
            guard lexicon.contains(word: expected, code: pinyin) else {
                pendingData.append(pinyin)
                continue
            }
            type(pinyin, keyboard)
            let titles = candidates(keyboard)
            if titles.first != expected { wrongFirst.append((pinyin, expected, titles.prefix(3).joined(separator: "/"))) }
            checked += 1
            clear(keyboard)
        }
        // 整句不依赖词库收录。
        for (pinyin, expected) in Self.composedFirst {
            type(pinyin, keyboard)
            XCTAssertEqual(candidates(keyboard).first, expected, "\(pinyin) 首候选")
            checked += 1
            clear(keyboard)
        }
        print("VOCAB-FIRST checked=\(checked) pendingData=\(pendingData.count) wrongFirst=\(wrongFirst.count)")
        if !wrongFirst.isEmpty { print("VOCAB-WRONG-FIRST \(wrongFirst)") }
        XCTAssertTrue(wrongFirst.isEmpty, "首候选不符：\(wrongFirst.map { "\($0.0)->\($0.2)" })")
    }

    /// 本地词库的整串精确命中要压过会话候选（新词进库后立即生效，不依赖会话分词）。
    func testLocalExactWordOutranksSessionCandidates() throws {
        let engine = MobileEngine()
        let ready = expectation(description: "start")
        engine.onUpdate = { _ in ready.fulfill() }
        engine.start(bundle: Bundle(for: Self.self), mode: "pinyin")
        wait(for: [ready], timeout: 20)
        _ = engineUpdate(engine, .feed("dianfanguo"))
        _ = engineUpdate(engine, .importWords([
            MobileWord(word: "电饭锅", code: "dian fan guo", frequency: 1, reading: "dian fan guo"),
            MobileWord(word: "飞书", code: "fei shu", frequency: 1, reading: "fei shu"),
            MobileWord(word: "向量数据库", code: "xiang liang shu ju ku", frequency: 1, reading: "xiang liang shu ju ku"),
        ]))
        for (raw, expected) in [("dianfanguo", "电饭锅"), ("feishu", "飞书"), ("xiangliangshujuku", "向量数据库")] {
            let update = engineUpdate(engine, .feed(raw))
            XCTAssertEqual(update.snapshot.candidates.first, expected, raw)
            _ = engineUpdate(engine, .clear)
        }
    }

    /// 选词学习后，同一个编码再次输入时学过的词应回到首位。
    /// 每次跑用新编码，避免持久化的学习记录让测试在多次运行间变成不稳定。
    func testLearnedWordMovesBackToFront() throws {
        let engine = MobileEngine()
        let ready = expectation(description: "start")
        engine.onUpdate = { _ in ready.fulfill() }
        engine.start(bundle: Bundle(for: Self.self), mode: "pinyin")
        wait(for: [ready], timeout: 20)
        let code = "lianalearn" + UUID().uuidString.lowercased().filter { $0.isASCII && $0.isLetter }
        _ = engineUpdate(engine, .importWords([
            MobileWord(word: "甲词", code: code, frequency: 100, reading: code),
            MobileWord(word: "乙词", code: code, frequency: 1, reading: code),
        ]))
        let before = engineUpdate(engine, .feed(code)).snapshot.candidates
        XCTAssertEqual(before.first, "甲词")
        let index = try XCTUnwrap(before.firstIndex(of: "乙词"))
        XCTAssertEqual(engineUpdate(engine, .select(index, raw: code, text: "乙词")).committed, "乙词")
        XCTAssertEqual(engineUpdate(engine, .feed(code)).snapshot.candidates.first, "乙词")
    }

    /// 词典/会话不可用时，合法拼音也必须给出候选（音节 DP 兜底）；九键同理。
    func testLegalPinyinNeverReturnsEmptyWithoutDictionarySession() throws {
        for mode in ["pinyin", "t9"] {
            let engine = MobileEngine()
            engine.sessionFactory = { _, _ in nil }
            let ready = expectation(description: "start")
            engine.onUpdate = { _ in ready.fulfill() }
            engine.start(bundle: Bundle(for: Self.self), mode: mode)
            wait(for: [ready], timeout: 20)
            let inputs = mode == "t9"
                ? ["999999999999", "5468426842674", "64426"]
                : ["zhuangzhuang", "lve", "xiongyongpengpai", "chuangqianmingyueguang"]
            for raw in inputs {
                let update = engineUpdate(engine, .feed(raw))
                XCTAssertFalse(update.snapshot.candidates.isEmpty, "\(mode) \(raw) 没有候选")
                XCTAssertFalse(update.snapshot.candidates.first?.isEmpty ?? true, "\(mode) \(raw) 首候选为空")
                _ = engineUpdate(engine, .clear)
            }
        }
    }

    /// 九键长串逐键解码的耗时回归（引擎在后台队列，不应阻塞/超时）。
    func testNineKeyLongPhraseLookupStaysFast() throws {
        let engine = MobileEngine()
        let ready = expectation(description: "start")
        engine.onUpdate = { _ in ready.fulfill() }
        engine.start(bundle: Bundle(for: Self.self), mode: "t9")
        wait(for: [ready], timeout: 20)
        let start = CACurrentMediaTime()
        var update: MobileEngine.Update!
        for character in "5468426842674" { update = engineUpdate(engine, .feed(String(character))) }
        let elapsed = CACurrentMediaTime() - start
        XCTAssertEqual(update.snapshot.candidates.first, "今天天气")
        print("VOCAB-PERF t9 13 keys -> \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 2.0, "13 次九键按键解码过慢")
    }

    private func engineUpdate(_ engine: MobileEngine, _ action: MobileEngine.Action) -> MobileEngine.Update {
        let done = expectation(description: "engine action")
        var result: MobileEngine.Update!
        engine.onUpdate = { result = $0; done.fulfill() }
        engine.submit(action, document: nil)
        wait(for: [done], timeout: 20)
        return result
    }
}
