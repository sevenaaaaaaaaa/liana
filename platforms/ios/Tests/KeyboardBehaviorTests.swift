import XCTest
import UIKit

private final class MemoryDocument: NSObject, UITextDocumentProxy {
    var text = ""
    var events: [String] = []
    var hasText: Bool { !text.isEmpty }
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier = UUID()
    var deletes = 0
    func insertText(_ value: String) { text += value; events.append("insert:" + value) }
    func deleteBackward() { deletes += 1; if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) { events.append("cursor:\(offset)") }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}

private final class FixtureKeyboard: KeyboardViewController {
    let document = MemoryDocument()
    override var textDocumentProxy: UITextDocumentProxy { document }
}

private final class SimulatedPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .began
    var delta = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { delta }
}

@MainActor
final class KeyboardBehaviorTests: XCTestCase {
    private var savedPreferences: Data?
    private var savedAppearance: Any?
    private var savedMethod: Any?
    private var savedDraft: Any?
    private var savedPhrases: Any?
    override func setUp() {
        super.setUp()
        savedDraft=UserDefaults.standard.object(forKey:MobileToolsViewController.draftKey)
        UserDefaults.standard.removeObject(forKey:MobileToolsViewController.draftKey)
        savedMethod = UserDefaults.standard.object(forKey: "keyboard.method")
        UserDefaults.standard.removeObject(forKey: "keyboard.method")
        savedPreferences = UserDefaults.standard.data(forKey: "keyboard.layout.v1")
        savedPhrases = UserDefaults.standard.object(forKey: MobilePhrases.key)
        UserDefaults.standard.removeObject(forKey: MobilePhrases.key)
        savedAppearance = UserDefaults.standard.object(forKey: "keyboard.appearance")
        UserDefaults.standard.set(0, forKey: "keyboard.appearance")
        KeyboardPreferences().save()
        // 截图与断言都按最终状态：测试里关闭 UIView 动画，避免面板 reveal 拍到半透明。
        UIView.setAnimationsEnabled(false)
    }
    override func tearDown() {
        UserDefaults.standard.set(savedPreferences, forKey: "keyboard.layout.v1")
        UserDefaults.standard.set(savedPhrases, forKey: MobilePhrases.key)
        UserDefaults.standard.set(savedAppearance, forKey: "keyboard.appearance")
        UserDefaults.standard.set(savedMethod, forKey: "keyboard.method")
        UserDefaults.standard.set(savedDraft,forKey:MobileToolsViewController.draftKey)
        UIView.setAnimationsEnabled(true)
        super.tearDown()
    }
    private func fixture() -> FixtureKeyboard {
        let keyboard = FixtureKeyboard()
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 375, height: 301)
        keyboard.view.setNeedsLayout()
        keyboard.view.layoutIfNeeded()
        drain(keyboard)
        return keyboard
    }

    private func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
    private func button(_ id: String, _ keyboard: FixtureKeyboard, file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id || $0.title(for: .normal) == id }, "Missing button: \(id)", file: file, line: line)
    }
    private func tap(_ id: String, _ keyboard: FixtureKeyboard) throws {
        let target = try button(id, keyboard)
        UIView.performWithoutAnimation { target.sendActions(for: .touchUpInside) }
        drain(keyboard)
    }
    private func drain(_ keyboard: FixtureKeyboard) {
        let idle = expectation(description: "decode queue idle")
        keyboard.whenInputIdle { idle.fulfill() }
        wait(for: [idle], timeout: 15)
    }
    private func typePinyin(_ value: String, _ keyboard: FixtureKeyboard) throws {
        for character in value { try tap("key." + String(character), keyboard) }
    }

    /// 让短过渡（面板 reveal）走完再截图。
    private func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func attachScreenshot(_ name: String, _ keyboard: FixtureKeyboard) {
        keyboard.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: keyboard.view.bounds).image { context in keyboard.view.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCandidateSelectionAndComposition() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
        let composition = allViews(keyboard.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "composition" }
        XCTAssertEqual(composition?.text, "ni hao")
        keyboard.view.layoutIfNeeded()
        let firstCandidate = try button("candidate.0", keyboard)
        XCTAssertGreaterThanOrEqual(firstCandidate.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(firstCandidate.bounds.width, firstCandidate.intrinsicContentSize.width)
        XCTAssertNotNil(try button("key.⏎", keyboard).image(for: .normal))
        let image = UIGraphicsImageRenderer(bounds: keyboard.view.bounds).image { context in
            keyboard.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iPhone-keyboard-candidates"
        attachment.lifetime = .keepAlways
        add(attachment)
        try tap("candidate.0", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好")
    }

    func testPunctuationCommitsChineseBeforeComma() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        try tap("key.，", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好，")
    }

    func testModeSwitchKeepsPendingComposition() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        try tap("key.中", keyboard)
        try tap("key.a", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好a")
    }

    func testNumberSymbolShiftAndGlobe() throws {
        let keyboard = fixture()
        try tap("key.123", keyboard)
        try tap("key.1", keyboard)
        try tap("key.2", keyboard)
        try tap("key.#+=", keyboard)
        try tap("key.€", keyboard)
        try tap("key.ABC", keyboard)
        try tap("key.⇧", keyboard)
        try tap("key.A", keyboard)
        XCTAssertEqual(keyboard.document.text, "12€A")
        XCTAssertNotNil(try button("key.🌐", keyboard).image(for: .normal))
    }

    func testBackspaceAndCancelDoNotDeleteCommittedText() throws {
        let keyboard = fixture()
        keyboard.document.text = "保留"
        try typePinyin("nihao", keyboard)
        try tap("key.⌫", keyboard)
        XCTAssertEqual(keyboard.document.text, "保留")
        try tap("composition.clear", keyboard)
        try tap("key.⌫", keyboard)
        XCTAssertEqual(keyboard.document.text, "保")
    }

    func testResizeKeepsComposition() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        keyboard.view.frame.size.width = 430
        keyboard.view.setNeedsLayout()
        keyboard.view.layoutIfNeeded()
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
    }

    func testAdjustmentPreservesCompositionAndReset() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        try tap("layout.settings", keyboard)
        let slider = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISlider }.first { $0.accessibilityIdentifier == "layout.height" })
        slider.value = 60
        slider.sendActions(for: .valueChanged)
        keyboard.view.layoutIfNeeded()
        XCTAssertEqual(try button("key.q", keyboard).bounds.height, 60, accuracy: 0.1)
        attachScreenshot("iPhone-layout-adjustments", keyboard)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
        try tap("layout.reset", keyboard)
        keyboard.view.layoutIfNeeded()
        XCTAssertEqual(try button("key.q", keyboard).bounds.height, 46, accuracy: 0.1)
        try tap("layout.settings", keyboard)
        try tap("candidate.0", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好")
    }

    func testOptionalBluetoothIsGatedWithoutFullAccess() throws {
        let keyboard = fixture()
        try tap("devices.open", keyboard)
        try tap("devices.scan", keyboard)
        let status = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "devices.status" })
        XCTAssertTrue(status.text?.contains("允许完全访问") == true)
        attachScreenshot("iPhone-bluetooth-entry", keyboard)
        try tap("devices.open", keyboard)
        try typePinyin("nihao", keyboard)
        try tap("candidate.0", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好")
    }

    func testBLEPreviewRequiresExplicitInsertAndKeepsComposition() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        try tap("devices.open", keyboard)
        let panel = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? BluetoothDevicePanel }.first)
        panel.receive(.partial("code"))
        XCTAssertEqual(keyboard.document.text, "")
        XCTAssertFalse(try button("devices.insert", keyboard).isEnabled)
        panel.receive(.final("code"))
        XCTAssertEqual(keyboard.document.text, "")
        try tap("devices.insert", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好code")
        try tap("devices.insert", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好code")
    }

    func testBLEFramingHandlesSplitUTF8AndJSONDeduplication() throws {
        var decoder = BLETextDecoder()
        let bytes = Data("你好\n".utf8)
        XCTAssertEqual(try decoder.append(bytes.prefix(2)), [])
        XCTAssertEqual(try decoder.append(bytes.dropFirst(2)), [.final("你好")])
        decoder = BLETextDecoder(format: .json)
        let partial = Data("{\"type\":\"partial\",\"text\":\"你\"}\n".utf8)
        XCTAssertEqual(try decoder.append(partial), [.partial("你")])
        let final = Data("{\"type\":\"final\",\"id\":\"1\",\"text\":\"你好\"}\n".utf8)
        XCTAssertEqual(try decoder.append(final), [.final("你好")])
        XCTAssertEqual(try decoder.append(final), [])
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 65_537)))
    }

    func testPreferencesClampAndRoundTrip() {
        var preferences = KeyboardPreferences()
        preferences.keyHeight = 200
        preferences.width = 0.1
        preferences.entryPosition = .nan
        preferences.normalize()
        XCTAssertEqual(preferences.keyHeight, 64)
        XCTAssertEqual(preferences.width, 0.78)
        XCTAssertEqual(preferences.entryPosition, 1)
        XCTAssertEqual(preferences.contentWidth(in: 375), 320)
        preferences.save()
        XCTAssertEqual(KeyboardPreferences.load(), preferences)
    }

    func testDragResizesAndMovesEntryWithoutLosingInput() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        let action = NSSelectorFromString("dragLayout:")
        XCTAssertTrue(keyboard.responds(to: action))
        let pan = SimulatedPan()
        keyboard.perform(action, with: pan)
        pan.delta = CGPoint(x: -100, y: -40)
        pan.phase = .ended
        keyboard.perform(action, with: pan)
        keyboard.view.layoutIfNeeded()
        XCTAssertEqual(try button("key.q", keyboard).bounds.height, 56, accuracy: 0.1)
        // 入口组整体左移（6 个入口后，「工具」不再是第一个，按整组位置断言）。
        let dock = try XCTUnwrap(allViews(keyboard.view).first { $0.accessibilityIdentifier == "layout.drag" })
        XCTAssertLessThan(dock.convert(dock.bounds, to: keyboard.view).minX, 60)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
        keyboard.viewWillDisappear(false)
        XCTAssertEqual(KeyboardPreferences.load().keyHeight, 56)
    }

    func testNarrowOneHandLayoutAndLargeCandidatesInDarkMode() throws {
        let keyboard = fixture()
        let window = UIWindow(frame: keyboard.view.frame)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = keyboard
        window.isHidden = false
        defer { window.isHidden = true }
        keyboard.overrideUserInterfaceStyle = .dark
        keyboard.view.layoutIfNeeded()
        XCTAssertEqual(keyboard.view.traitCollection.userInterfaceStyle, .dark)
        try typePinyin("nihao", keyboard)
        try tap("layout.settings", keyboard)
        for (id, value): (String, Float) in [("width", 0.78), ("alignment", 1), ("font", 24), ("entry", 0)] {
            let slider = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISlider }.first { $0.accessibilityIdentifier == "layout." + id })
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }
        try tap("layout.settings", keyboard)
        keyboard.view.layoutIfNeeded()
        let q = try button("key.q", keyboard)
        let p = try button("key.p", keyboard)
        XCTAssertGreaterThan(q.convert(q.bounds, to: keyboard.view).minX, 40)
        XCTAssertLessThanOrEqual(p.convert(p.bounds, to: keyboard.view).maxX, 375)
        XCTAssertEqual(try button("candidate.0", keyboard).titleLabel?.font.pointSize, 24)
        let candidate = try button("candidate.0", keyboard)
        let strip = try XCTUnwrap(candidate.superview?.superview as? UIScrollView)
        XCTAssertGreaterThanOrEqual(candidate.convert(candidate.bounds, to: strip).intersection(strip.bounds).height, 44)
        attachScreenshot("iPhone-one-hand-dark", keyboard)
        keyboard.view.frame.size.width = 320
        keyboard.view.layoutIfNeeded()
        let narrowP = try button("key.p", keyboard)
        XCTAssertLessThanOrEqual(narrowP.convert(narrowP.bounds, to: keyboard.view).maxX, 320)
    }

    func testOnlyBlackWhiteThemesCanFollowSystemAndPersist() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        try tap("layout.settings", keyboard)
        let appearance = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "layout.appearance" })
        XCTAssertEqual(appearance.numberOfSegments, 3)
        appearance.selectedSegmentIndex = 2
        appearance.sendActions(for: .valueChanged)
        XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(fixture().overrideUserInterfaceStyle, .dark)
        appearance.selectedSegmentIndex = 1
        appearance.sendActions(for: .valueChanged)
        XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
    }

    func testHostOffersMacPairingAndExplicitFileSelection() throws {
        let host = ViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.loadViewIfNeeded()
        let open = try XCTUnwrap(allViews(host.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "mac.open" })
        UIView.performWithoutAnimation { open.sendActions(for: .touchUpInside) }
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let link = try XCTUnwrap(navigation.topViewController as? PetLinkViewController)
        link.loadViewIfNeeded()
        let identifiers = Set(allViews(link.view).compactMap { $0.accessibilityIdentifier })
        XCTAssertTrue(identifiers.isSuperset(of: ["mac.scan", "mac.paste", "mac.connect", "mac.send", "mac.cancel", "mac.forget"]))
        let send = try XCTUnwrap(allViews(link.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "mac.send" })
        XCTAssertFalse(send.isEnabled)
        link.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: link.view.bounds).image { context in link.view.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iPhone-Mac-pairing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testBottomKeysHaveGuaranteedFooterAndSelfSizing() throws {
        let keyboard = fixture()
        for width: CGFloat in [320, 375, 430] {
            keyboard.view.frame.size = CGSize(width: width, height: keyboard.view.intrinsicContentSize.height)
            keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
            let key = try button("key.⏎", keyboard)
            let rect = key.convert(key.bounds, to: keyboard.view)
            XCTAssertGreaterThanOrEqual(keyboard.view.bounds.maxY - rect.maxY, 8)
            XCTAssertGreaterThanOrEqual(rect.height, 44)
        }
        let input = try XCTUnwrap(keyboard.inputView as? KeyboardInputView)
        XCTAssertTrue(input.allowsSelfSizing)
        XCTAssertEqual(input.systemLayoutSizeFitting(CGSize(width:430,height:216)).height,input.requestedHeight)
        attachScreenshot("iPhone-bottom-spacing",keyboard)
    }
    func testRapidTapsEnqueueWithoutBlockingTouchThread() throws {
        let keyboard = fixture()
        let start = CACurrentMediaTime()
        for _ in 0..<20 {
            for character in "nihao" { try button("key."+String(character),keyboard).sendActions(for:.touchUpInside) }
            try button("key.空格",keyboard).sendActions(for:.touchUpInside)
        }
        let elapsed = CACurrentMediaTime()-start
        XCTAssertLessThan(elapsed,0.5,"Touch handling must not wait for decoding")
        drain(keyboard)
        XCTAssertEqual(keyboard.document.text,String(repeating:"你好",count:20))
        print("120 rapid touch actions enqueued in \(elapsed) seconds")
    }
    func testNineKeyAndHandwritingLayoutsAreRealAndContained() throws {
        UserDefaults.standard.set("t9",forKey:"keyboard.method")
        let keyboard = fixture()
        for key in ["6 MNO","4 GHI","4 GHI","2 ABC","6 MNO"] { try tap("key."+key,keyboard) }
        XCTAssertEqual(try button("candidate.0",keyboard).title(for:.normal),"你好")
        try tap("candidate.0",keyboard); XCTAssertEqual(keyboard.document.text,"你好")
        attachScreenshot("iPhone-nine-key",keyboard)
        UserDefaults.standard.set("handwriting",forKey:"keyboard.method")
        let hand = fixture()
        let canvas = try XCTUnwrap(allViews(hand.view).compactMap { $0 as? HandwritingPanel }.first)
        canvas.onStrokes?([[[20,100],[128,100],[236,100]]]); drain(hand)
        XCTAssertTrue((0..<9).contains { (try? button("candidate.\($0)",hand).title(for:.normal)) == "一" })
        attachScreenshot("iPhone-handwriting",hand)
    }
    func testDictionaryParserAndGitHubURLs() throws {
        let words=try MobileDictionaryImport.parse(Data("---\nname: test\n...\n松萝测试\tsong luo ce shi\t9999\n".utf8),wubi:false)
        XCTAssertEqual(words.count,1); XCTAssertEqual(words[0].code,"song luo ce shi")
        XCTAssertEqual(try MobileDictionaryImport.githubURL("https://github.com/rime/rime-wubi/blob/master/wubi86.dict.yaml").host,"raw.githubusercontent.com")
        for bad in ["http://github.com/a/b/blob/main/a.txt","https://evil.example/a.txt","https://github.com/a/b"] { XCTAssertThrowsError(try MobileDictionaryImport.githubURL(bad)) }
        XCTAssertThrowsError(try MobileDictionaryImport.parse(Data("invalid: yaml".utf8),wubi:true))
    }

    private func engineUpdate(_ engine: MobileEngine, _ action: MobileEngine.Action) -> MobileEngine.Update {
        let done = expectation(description: "engine action")
        var result: MobileEngine.Update!
        engine.onUpdate = { result=$0; done.fulfill() }
        engine.submit(action,document:nil)
        wait(for:[done],timeout:15)
        return result
    }
    func testWubiAndAllDoublePinyinSchemes() throws {
        for (mode,code) in [("flypy","nihc"),("mspy","nihk"),("zrm","nihk"),("wubi","wqiy")] {
            let engine=MobileEngine()
            let ready=expectation(description:"start"); engine.onUpdate={ _ in ready.fulfill() }
            engine.start(bundle:Bundle(for:Self.self),mode:mode); wait(for:[ready],timeout:15)
            let decoded=engineUpdate(engine,.feed(code))
            XCTAssertEqual(decoded.snapshot.candidates.first,mode == "wubi" ? "你" : "你好",mode)
            let chosen=engineUpdate(engine,.space)
            XCTAssertEqual(chosen.committed,mode == "wubi" ? "你" : "你好",mode)
        }
        UserDefaults.standard.set("mspy",forKey:"keyboard.method")
        let keyboard=fixture()
        XCTAssertNotNil(try button("key.;",keyboard))
    }
    func testGlideDecoderProducesChineseAndEnglishCandidates() throws {
        let db=MobileLexicon(bundle:Bundle(for:Self.self))
        var centers:[String:CGPoint]=[:]
        for (r,row) in ["qwertyuiop","asdfghjkl","zxcvbnm"].enumerated() {
            for (c,ch) in row.enumerated() { centers[String(ch)]=CGPoint(x:Double(c)*35+Double(r)*12,y:Double(r)*50) }
        }
        let chinese=GlideDecoder.decode(points:"nihao".map { centers[String($0)]! },centers:centers,lexicon:db,english:false)
        XCTAssertEqual(chinese.first?.word,"你好")
        let english=GlideDecoder.decode(points:"hello".map { centers[String($0)]! },centers:centers,lexicon:db,english:true)
        XCTAssertEqual(english.first?.word,"hello")
    }
    func testStaleCandidateSelectionPreservesNewSuffix() throws {
        let engine=MobileEngine()
        let ready=expectation(description:"start"); engine.onUpdate={ _ in ready.fulfill() }
        engine.start(bundle:Bundle(for:Self.self),mode:"pinyin"); wait(for:[ready],timeout:15)
        let before=engineUpdate(engine,.feed("nihao"))
        XCTAssertEqual(before.snapshot.candidates.first,"你好")
        _=engineUpdate(engine,.feed("ma"))
        let selected=engineUpdate(engine,.select(0,raw:"nihao",text:"你好"))
        XCTAssertEqual(selected.committed,"你好"); XCTAssertEqual(selected.snapshot.raw,"ma")
    }
    func testImportedShortcutIsLocalAndCompletionKeepsExactRanking() throws {
        let engine=MobileEngine()
        let ready=expectation(description:"start"); engine.onUpdate={ _ in ready.fulfill() }
        engine.start(bundle:Bundle(for:Self.self),mode:"pinyin"); wait(for:[ready],timeout:15)
        let words=[MobileWord(word:"拟好",code:"ni hao",frequency:1,reading:"ni hao"),MobileWord(word:"松萝快捷测试",code:"lianatestshortcut",reading:"song luo kuai jie ce shi"),MobileWord(word:"你好世界测试",code:"ni hao shi jie ce shi",reading:"ni hao shi jie ce shi")]
        _=engineUpdate(engine,.importWords(words))
        XCTAssertEqual(engineUpdate(engine,.feed("lianatestshortcut")).snapshot.candidates.first,"松萝快捷测试")
        XCTAssertEqual(engineUpdate(engine,.space).committed,"松萝快捷测试")
        XCTAssertEqual(engineUpdate(engine,.feed("nihao")).snapshot.candidates.first,"你好")
    }
    func testToolsContainRealActionsAndKaomojiInserts() throws {
        let keyboard=fixture()
        try tap("tools.open",keyboard)
        XCTAssertNotNil(try button("tools.receive",keyboard))
        let tabs = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "tools.section" })
        tabs.selectedSegmentIndex = 3; tabs.sendActions(for:.valueChanged)
        XCTAssertNotNil(try button("tools.system",keyboard))
        tabs.selectedSegmentIndex = 2; tabs.sendActions(for:.valueChanged)
        XCTAssertNotNil(try button("tools.clip.send",keyboard)); XCTAssertNotNil(try button("tools.clip.receive",keyboard))
        tabs.selectedSegmentIndex = 1; tabs.sendActions(for:.valueChanged)
        try tap("face.0",keyboard)
        XCTAssertFalse(keyboard.document.text.isEmpty)
        try tap("tools.close",keyboard)
        XCTAssertNotNil(try button("key.q",keyboard))
        try tap("tools.open",keyboard)
        try tap("method.wubi",keyboard)
        try typePinyin("wqiy",keyboard)
        XCTAssertEqual(try button("candidate.0",keyboard).title(for:.normal),"你")
    }

    func testGlideCandidatesSurviveBackgroundSave() throws {
        let engine=MobileEngine()
        let ready=expectation(description:"start"); engine.onUpdate={ _ in ready.fulfill() }
        engine.start(bundle:Bundle(for:Self.self),mode:"pinyin"); wait(for:[ready],timeout:15)
        var centers:[String:CGPoint]=[:]
        for (r,row) in ["qwertyuiop","asdfghjkl","zxcvbnm"].enumerated() {
            for (c,ch) in row.enumerated() { centers[String(ch)]=CGPoint(x:Double(c)*35+Double(r)*12,y:Double(r)*50) }
        }
        let result=engineUpdate(engine,.glide("nihao".map { centers[String($0)]! },centers,false))
        XCTAssertEqual(result.snapshot.candidates.first,"你好")
        XCTAssertEqual(engineUpdate(engine,.save).snapshot.candidates.first,"你好")
        XCTAssertEqual(engineUpdate(engine,.space).committed,"你好")
        XCTAssertTrue(engineUpdate(engine,.save).snapshot.candidates.isEmpty)
    }
    func testDocumentSwitchDropsQueuedCommitAndClearsComposition() throws {
        let keyboard=fixture()
        try typePinyin("nihao",keyboard)
        try button("key.空格",keyboard).sendActions(for:.touchUpInside)
        keyboard.document.documentIdentifier=UUID()
        try button("key.a",keyboard).sendActions(for:.touchUpInside)
        drain(keyboard)
        XCTAssertEqual(keyboard.document.text,"")
        try tap("composition.clear",keyboard)
        try tap("key.中",keyboard)
        try tap("key.x",keyboard)
        XCTAssertEqual(keyboard.document.text,"x")
    }

    func testMonochromePalettesMeetTextContrast() {
        func luminance(_ color:UIColor,_ traits:UITraitCollection)->Double {
            var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
            color.resolvedColor(with:traits).getRed(&r,green:&g,blue:&b,alpha:&a)
            func linear(_ v:CGFloat)->Double { let n=Double(v); return n<=0.04045 ? n/12.92 : pow((n+0.055)/1.055,2.4) }
            return 0.2126*linear(r)+0.7152*linear(g)+0.0722*linear(b)
        }
        for style:UIUserInterfaceStyle in [.light,.dark] {
            let traits=UITraitCollection(userInterfaceStyle:style)
            for (foreground,background) in [(LianaPalette.ink,LianaPalette.key),(LianaPalette.muted,LianaPalette.keyboard),(LianaPalette.muted,LianaPalette.card),(LianaPalette.onPrimary,LianaPalette.primary)] {
                let a=luminance(foreground,traits),b=luminance(background,traits)
                XCTAssertGreaterThanOrEqual((max(a,b)+0.05)/(min(a,b)+0.05),4.5)
            }
        }
    }
    func testPressFeedbackDoesNotMoveKeyAndPresetsKeepComposition() throws {
        let keyboard=fixture()
        let key=try button("key.q",keyboard); let frame=key.frame; let before=key.backgroundColor
        key.isHighlighted=true
        XCTAssertEqual(key.frame,frame); XCTAssertNotEqual(key.backgroundColor,before)
        key.isHighlighted=false
        try typePinyin("nihao",keyboard)
        try tap("layout.settings",keyboard)
        for index in [1,2,0] {
            try tap("layout.preset.\(index)",keyboard)
            XCTAssertEqual(try button("candidate.0",keyboard).title(for:.normal),"你好")
        }
        try tap("layout.done",keyboard)
        try tap("candidate.0",keyboard)
        XCTAssertEqual(keyboard.document.text,"你好")
    }
    func testCopyPayloadSupportsDirectPasteAndKeepsPairingPrivate() throws {
        let item=try KeyboardPayload(kind:"text",text:"可以直接粘贴").pasteboardItem()
        XCTAssertEqual(item["public.utf8-plain-text"] as? String,"可以直接粘贴")
        let decoded=try JSONDecoder().decode(KeyboardPayload.self,from:try XCTUnwrap(item[KeyboardPayload.pasteboardType] as? Data))
        XCTAssertEqual(decoded.text,"可以直接粘贴")
        let gif=Data(base64Encoded:"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        XCTAssertEqual(try KeyboardPayload(kind:"gif",gif:gif).pasteboardItem()["com.compuserve.gif"] as? Data,gif)
        let pairing=try KeyboardPayload(kind:"pairing",text:"private-pairing-material").pasteboardItem()
        XCTAssertNil(pairing["public.utf8-plain-text"])
        XCTAssertNotNil(pairing[KeyboardPayload.pasteboardType])
    }
    func testHostVoiceCopyIsAvailableAfterEditingWithoutRecording() throws {
        let tools=MobileToolsViewController(); tools.loadViewIfNeeded()
        let text=try XCTUnwrap(allViews(tools.view).compactMap { $0 as? UITextView }.first)
        let copy=try XCTUnwrap(allViews(tools.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier=="voice.copy" })
        XCTAssertFalse(copy.isEnabled)
        text.text="编辑好的文字"; tools.textViewDidChange(text)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertEqual(text.text,"编辑好的文字")
    }
    func testKeyboardGalleryPhoneAndTabletInBothThemes() throws {
        for style:UIUserInterfaceStyle in [.light,.dark] {
            let keyboard=fixture()
            let window=UIWindow(frame:keyboard.view.frame); window.overrideUserInterfaceStyle=style; window.rootViewController=keyboard; window.isHidden=false
            keyboard.overrideUserInterfaceStyle=style; keyboard.view.layoutIfNeeded()
            XCTAssertEqual(keyboard.view.traitCollection.userInterfaceStyle,style)
            func fit(_ width:CGFloat) {
                for _ in 0..<3 {
                    let height=keyboard.view.intrinsicContentSize.height
                    window.frame=CGRect(x:0,y:0,width:width,height:height)
                    keyboard.view.frame=window.bounds; keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
                }
            }
            func visibleKeys(_ width:CGFloat) throws {
                let area=try XCTUnwrap(allViews(keyboard.view).first { $0.accessibilityIdentifier=="keyboard.keys" })
                let viewport=area.convert(area.bounds,to:keyboard.view)
                for key in allViews(keyboard.view).compactMap({ $0 as? UIButton }) where key.accessibilityIdentifier?.hasPrefix("key.")==true {
                    let rect=key.convert(key.bounds,to:keyboard.view)
                    XCTAssertGreaterThanOrEqual(rect.minX,-0.5); XCTAssertLessThanOrEqual(rect.maxX,width+0.5)
                    XCTAssertGreaterThanOrEqual(rect.intersection(viewport).height,43.5,key.accessibilityIdentifier ?? "")
                }
            }
            fit(375); try typePinyin("shuru",keyboard)
            attachScreenshot("keyboard-\(style.rawValue)-phone",keyboard)
            try tap("tools.open",keyboard); attachScreenshot("tools-\(style.rawValue)-phone",keyboard); try tap("tools.close",keyboard)
            if #available(iOS 17.0,*) { keyboard.traitOverrides.horizontalSizeClass = .regular }
            fit(1024); try visibleKeys(1024); attachScreenshot("keyboard-\(style.rawValue)-tablet",keyboard)
            if #available(iOS 17.0,*) { keyboard.traitOverrides.verticalSizeClass = .compact }
            fit(932); try visibleKeys(932)
            let before=keyboard.view.intrinsicContentSize.height
            XCTAssertLessThan(before,310)
            attachScreenshot("keyboard-\(style.rawValue)-landscape",keyboard)
            try tap("candidate.0",keyboard)
            XCTAssertEqual(keyboard.document.text,"输入")
            XCTAssertEqual(keyboard.view.intrinsicContentSize.height,before)
            window.isHidden=true
        }
    }
    func testCursorMoveCommitsBeforeAdjustingTheDocument() throws {
        let keyboard=fixture()
        if #available(iOS 17.0,*) { keyboard.traitOverrides.horizontalSizeClass = .regular }
        keyboard.view.frame.size.width=1024; keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
        try typePinyin("nihao",keyboard); try tap("key.←",keyboard)
        XCTAssertEqual(keyboard.document.events,["insert:你好","cursor:-1"])
    }
    func testHostLargeTypeHasNoHorizontalOverflow() throws {
        for style:UIUserInterfaceStyle in [.light,.dark] {
            for width:CGFloat in [375,1024] {
                let host=ViewController(); host.overrideUserInterfaceStyle=style
                if #available(iOS 17.0,*) { host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
                let window=UIWindow(frame:CGRect(x:0,y:0,width:width,height:width>600 ? 768:900)); window.rootViewController=host; window.isHidden=false
                host.loadViewIfNeeded(); host.view.layoutIfNeeded()
                let scroll=try XCTUnwrap(allViews(host.view).compactMap { $0 as? UIScrollView }.first { !($0 is UITextView) })
                XCTAssertEqual(scroll.contentSize.width,scroll.bounds.width,accuracy:1)
                XCTAssertFalse(scroll.subviews.compactMap { $0 as? UIStackView }.first?.hasAmbiguousLayout ?? true)
                let attachment=XCTAttachment(image:UIGraphicsImageRenderer(bounds:host.view.bounds).image { context in host.view.layer.render(in:context.cgContext) }); attachment.name="home-large-type-\(style.rawValue)-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
                window.isHidden=true
            }
        }
    }

    func testReducedMotionClosesPanelWithoutAHiddenDelay() throws {
        guard UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("Run this check with simulator Reduce Motion enabled") }
        let parent=UIView(frame:CGRect(x:0,y:0,width:375,height:199))
        let panel=UIView(frame:parent.bounds); parent.addSubview(panel)
        LianaMotion.reveal(panel)
        XCTAssertEqual(panel.alpha,1); XCTAssertEqual(panel.transform,.identity)
        var completed=false
        LianaMotion.dismiss(panel) { completed=true }
        XCTAssertTrue(completed); XCTAssertNil(panel.superview)
    }

    func testVoiceDraftSurvivesClosingAndCanUndoClear() throws {
        let tools=MobileToolsViewController(); tools.loadViewIfNeeded()
        let editor=try XCTUnwrap(allViews(tools.view).compactMap { $0 as? UITextView }.first)
        editor.text="保留这一段草稿"; tools.textViewDidChange(editor); tools.viewWillDisappear(false)
        let restored=MobileToolsViewController(); restored.loadViewIfNeeded()
        let restoredEditor=try XCTUnwrap(allViews(restored.view).compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(restoredEditor.text,"保留这一段草稿")
        let clear=try XCTUnwrap(allViews(restored.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier=="voice.clear" })
        clear.sendActions(for:.touchUpInside)
        XCTAssertEqual(restoredEditor.text,"")
        XCTAssertNil(UserDefaults.standard.object(forKey:MobileToolsViewController.draftKey))
        let undo=try XCTUnwrap(allViews(restored.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier=="voice.undo" })
        XCTAssertFalse(undo.isHidden); undo.sendActions(for:.touchUpInside)
        XCTAssertEqual(restoredEditor.text,"保留这一段草稿")
    }

    // MARK: - 词库覆盖与分段回退（问题 1：候选空白）

    private func nineKeyTitle(_ digit: Character) -> String {
        let titles: [Character: String] = ["1": "1 · 符号", "2": "2 ABC", "3": "3 DEF", "4": "4 GHI", "5": "5 JKL", "6": "6 MNO", "7": "7 PQRS", "8": "8 TUV", "9": "9 WXYZ"]
        return titles[digit] ?? String(digit)
    }

    private func typeNineKey(_ digits: String, _ keyboard: FixtureKeyboard) throws {
        for digit in digits { try tap("key." + nineKeyTitle(digit), keyboard) }
    }

    private func candidateTitles(_ keyboard: FixtureKeyboard) -> [String] {
        allViews(keyboard.view).compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier?.hasPrefix("candidate.") == true && !$0.isHidden }
            .sorted {
                let left = Int(($0.accessibilityIdentifier ?? "").dropFirst("candidate.".count)) ?? 0
                let right = Int(($1.accessibilityIdentifier ?? "").dropFirst("candidate.".count)) ?? 0
                return left < right
            }
            .map { $0.title(for: .normal) ?? "" }
    }

    /// 全拼整句：多音节输入必须立刻给出非空候选，且首候选是常用词。
    func testPinyinPhrasesProduceCandidates() throws {
        let keyboard = fixture()
        let cases: [(String, String)] = [
            ("jintiantianqi", "今天天气"),
            ("mingtianqugongsi", "明天去公司"),
            ("zhegeshouji", "这个手机"),
            ("wanshangyiqichifan", "晚上一起吃饭"),
            ("gongzuoshunli", "工作顺利"),
            ("nizaiganma", "你在干嘛"),
            ("xiexienile", "谢谢你了"),
            ("woxiangchi", "我想吃"),
            ("wobuyaole", "我不要了"),
            ("kuaiyidian", "快一点"),
            ("zheshishayisi", "这是啥意思"),
            ("zhongguorenmin", "中国人民"),
            ("dajiahao", "大家好"),
            ("kandianying", "看电影"),
        ]
        for (raw, expected) in cases {
            try typePinyin(raw, keyboard)
            let titles = candidateTitles(keyboard)
            XCTAssertFalse(titles.isEmpty, "\(raw) 没有候选")
            XCTAssertEqual(titles.first, expected, "\(raw) 首候选")
            XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), expected)
            try tap("composition.clear", keyboard)
        }
        attachScreenshot("iPhone-pinyin-phrases", keyboard)
    }

    /// Rust 会话拿不到（设备上随包词典加载失败）时，全拼仍要能给出整句候选。
    func testPhraseComposerFallbackWhenSessionIsUnavailable() throws {
        let engine = MobileEngine()
        engine.sessionFactory = { _, _ in nil }
        let ready = expectation(description: "start")
        engine.onUpdate = { _ in ready.fulfill() }
        engine.start(bundle: Bundle(for: Self.self), mode: "pinyin")
        wait(for: [ready], timeout: 15)
        let cases: [(String, String)] = [
            ("jintiantianqi", "今天天气"),
            ("mingtianqugongsi", "明天去公司"),
            ("zhegeshouji", "这个手机"),
            ("wanshangyiqichifan", "晚上一起吃饭"),
            ("gongzuoshunli", "工作顺利"),
            ("kuaiyidian", "快一点"),
            ("zheshishayisi", "这是啥意思"),
            ("zhongguorenmin", "中国人民"),
        ]
        for (raw, expected) in cases {
            let update = engineUpdate(engine, .feed(raw))
            XCTAssertFalse(update.snapshot.candidates.isEmpty, "\(raw) 回退后没有候选")
            XCTAssertEqual(update.snapshot.candidates.first, expected, "\(raw) 回退首候选")
            XCTAssertEqual(update.snapshot.raw, raw)
            _ = engineUpdate(engine, .clear)
        }
        _ = engineUpdate(engine, .feed("jintiantianqi"))
        XCTAssertEqual(engineUpdate(engine, .space).committed, "今天天气")
    }

    /// 九键长数字串：真实整句输入此前完全没有候选（候选栏空白）。
    func testNineKeyPhrasesProduceCandidates() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        let keyboard = fixture()
        let cases: [(String, String)] = [
            ("5468426842674", "今天天气"),
            ("6464842678466474", "明天去公司"),
            ("94343746854", "这个手机"),
            ("926742649474244326", "晚上一起吃饭"),
            ("4664986748654", "工作顺利"),
            ("6492442662", "你在干嘛"),
            ("9439436453", "谢谢你了"),
            ("9694264244", "我想吃"),
            ("5824943426", "快一点"),
            ("6442662", "你好吗"),
            ("962892653", "我不要了"),
        ]
        for (digits, expected) in cases {
            try typeNineKey(digits, keyboard)
            let titles = candidateTitles(keyboard)
            XCTAssertFalse(titles.isEmpty, "\(digits) 没有候选")
            XCTAssertEqual(titles.first, expected, "\(digits) 首候选")
            try tap("composition.clear", keyboard)
        }
        // 多音字/同码歧义也要给出真实词条，不能回退成拉丁字母。
        try typeNineKey("74683269426", keyboard)
        let ambiguous = candidateTitles(keyboard)
        XCTAssertFalse(ambiguous.isEmpty, "74683269426 没有候选")
        XCTAssertTrue(ambiguous.allSatisfy { $0.allSatisfy { !$0.isASCII } }, "\(ambiguous)")
        try tap("composition.clear", keyboard)
        try typeNineKey("5468426842674", keyboard)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "今天天气")
        attachScreenshot("iPhone-nine-key-phrases", keyboard)
        try tap("composition.clear", keyboard)
    }

    /// 九键 · 侧栏：中心 3x3、左右窄列放符号与功能键，整组在键盘宽度内且热区够大。
    func testNineKeySidebarLayoutIsContainedAndComplete() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        XCTAssertEqual(KeyboardPreferences.load().nineKeyLayout, .sidebar)
        let keyboard = fixture()
        for width: CGFloat in [320, 375, 430] {
            keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.view.intrinsicContentSize.height)
            keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
            let height = keyboard.view.bounds.height
            for title in ["1 · 符号", "2 ABC", "5 JKL", "9 WXYZ", "，", "。", "？！", "⌫", "⏎", "清空", "中", "🌐", "空格"] {
                let key = try button("key." + title, keyboard)
                let rect = key.convert(key.bounds, to: keyboard.view)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5, "key.\(title) 左越界")
                XCTAssertLessThanOrEqual(rect.maxX, width + 0.5, "key.\(title) 右越界")
                XCTAssertGreaterThanOrEqual(rect.height, 44, "key.\(title) 热区高度")
                XCTAssertGreaterThanOrEqual(rect.width, 44, "key.\(title) 热区宽度")
                XCTAssertGreaterThanOrEqual(rect.minY, -0.5)
                XCTAssertLessThanOrEqual(rect.maxY, height + 0.5)
            }
            let punctuation = try button("key.，", keyboard)
            let side = punctuation.convert(punctuation.bounds, to: keyboard.view).width
            let middle = try button("key.5 JKL", keyboard)
            let main = middle.convert(middle.bounds, to: keyboard.view).width
            XCTAssertLessThan(side, main, "侧栏必须窄于主键")
            attachScreenshot("iPhone-nine-key-sidebar-\(Int(width))", keyboard)
        }
        // 工具键已移除（入口只在顶栏），九键也没有独立 123。
        XCTAssertNil(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "key.工具" })
        XCTAssertNil(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "key.123" })
        // 中间仍是标准 3x3，点 5 进入九宫格组合。
        try tap("key.5 JKL", keyboard)
        XCTAssertFalse(candidateTitles(keyboard).isEmpty, "九键单键没有候选")
        try tap("composition.clear", keyboard)
        // 左列符号与长按更多符号。
        try tap("key.，", keyboard)
        XCTAssertEqual(keyboard.document.text, "，")
        try tap("key.⌫", keyboard)
        XCTAssertEqual(keyboard.document.text, "")
        let more = try button("key.？！", keyboard)
        XCTAssertEqual(more.menu?.children.count, 5)
        try tap("key.？！", keyboard)
        XCTAssertEqual(keyboard.document.text, "？")
        attachScreenshot("iPhone-nine-key-sidebar", keyboard)
    }

    /// 九键组合态顶栏不能显示原始数字串（用户反馈「顶栏莫名其妙多出来数字」）。
    func testNineKeyCompositionShowsPinyinNotDigits() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        let keyboard = fixture()
        let label = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "composition" })
        try typeNineKey("5468426842674", keyboard)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "今天天气")
        let reading = try XCTUnwrap(label.text)
        XCTAssertFalse(reading.isEmpty)
        XCTAssertFalse(reading.contains { "0123456789".contains($0) }, reading)
        XCTAssertTrue(reading.contains("jin"), reading)
        XCTAssertTrue(reading.contains("tian"), reading)
        attachScreenshot("iPhone-nine-key-reading", keyboard)
        // 退格后仍然是可读拼音，不能回退成数字串。
        try tap("key.⌫", keyboard)
        let afterBackspace = try XCTUnwrap(label.text)
        XCTAssertFalse(afterBackspace.contains { "0123456789".contains($0) }, afterBackspace)
        // 词库切不出来时也不能露出数字。
        try tap("composition.clear", keyboard)
        try typeNineKey("999999999999999", keyboard)
        let fallback = try XCTUnwrap(label.text)
        XCTAssertFalse(fallback.contains { "0123456789".contains($0) }, fallback)
        XCTAssertFalse(fallback.isEmpty)
        attachScreenshot("iPhone-nine-key-reading-fallback", keyboard)
        try tap("composition.clear", keyboard)
    }

    /// 顶栏六个同级入口：语音设备／剪贴板／文件／表情／工具／布局。
    func testEntryDockSharesSixQuickEntries() throws {
        let keyboard = fixture()
        let ids = ["devices.open", "clip.open", "file.open", "faces.open", "tools.open", "layout.settings"]
        var rects: [CGRect] = []
        for id in ids {
            let entry = try button(id, keyboard)
            XCTAssertFalse(entry.accessibilityLabel?.isEmpty ?? true, "\(id) 缺少 accessibilityLabel")
            let rect = entry.convert(entry.bounds, to: keyboard.view)
            XCTAssertGreaterThanOrEqual(rect.width, 44, id)
            XCTAssertGreaterThanOrEqual(rect.height, 44, id)
            rects.append(rect)
        }
        let first = try XCTUnwrap(rects.first)
        for rect in rects {
            XCTAssertEqual(rect.minY, first.minY, accuracy: 0.5, "入口不在同一排")
            XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
            XCTAssertLessThanOrEqual(rect.maxX, 375.5)
        }
        for (left, right) in zip(rects, rects.dropFirst()) { XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5) }
        // 组合串与入口组不能重叠；手机三档宽度与 iPad 都不溢出。
        try typePinyin("nihao", keyboard)
        let label = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "composition" })
        let dock = try XCTUnwrap(allViews(keyboard.view).first { $0.accessibilityIdentifier == "layout.drag" })
        for width: CGFloat in [320, 375, 430, 1024] {
            keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.view.intrinsicContentSize.height)
            keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
            let labelFrame = label.convert(label.bounds, to: keyboard.view)
            let dockFrame = dock.convert(dock.bounds, to: keyboard.view)
            XCTAssertLessThanOrEqual(labelFrame.maxX, dockFrame.minX + 0.5, "宽度 \(Int(width)) 组合串与入口重叠")
            XCTAssertGreaterThanOrEqual(dockFrame.minX, -0.5, "宽度 \(Int(width)) 入口左越界")
            XCTAssertLessThanOrEqual(dockFrame.maxX, width + 0.5, "宽度 \(Int(width)) 入口右越界")
            for (index, rect) in rects.enumerated() {
                XCTAssertLessThanOrEqual(rect.width * 6, width + 0.5, "入口 \(index) 在 \(Int(width)) 下溢出")
            }
        }
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 375, height: keyboard.view.intrinsicContentSize.height)
        keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
        // 横屏一行式：入口组仍在顶栏内，不越界。
        if #available(iOS 17.0, *) { keyboard.traitOverrides.verticalSizeClass = .compact }
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 932, height: keyboard.view.intrinsicContentSize.height)
        keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
        let landscapeDock = dock.convert(dock.bounds, to: keyboard.view)
        XCTAssertGreaterThanOrEqual(landscapeDock.minX, -0.5)
        XCTAssertLessThanOrEqual(landscapeDock.maxX, 932.5)
        if #available(iOS 17.0, *) { keyboard.traitOverrides.verticalSizeClass = .regular }
        // 表情入口 → 表情分类；剪贴板入口 → 同步分类。
        try tap("faces.open", keyboard)
        let tabs = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "tools.section" })
        XCTAssertEqual(tabs.selectedSegmentIndex, 1)
        XCTAssertNotNil(try button("face.0", keyboard))
        try tap("clip.open", keyboard)
        XCTAssertEqual(tabs.selectedSegmentIndex, 2)
        XCTAssertNotNil(try button("tools.clip.send", keyboard))
        // 文件入口在没有 App 内容时要给出明确状态。
        try tap("file.open", keyboard)
        let status = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "tools.status" })
        XCTAssertFalse(status.isHidden)
        XCTAssertFalse(status.text?.isEmpty ?? true)
        attachScreenshot("iPhone-entry-dock", keyboard)
    }

    /// 旧九键布局必须仍可选用，且候选行为不回归。
    func testNineKeyClassicLayoutRemainsAvailable() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        var preferences = KeyboardPreferences()
        preferences.nineKeyLayout = .classic
        preferences.save()
        let keyboard = fixture()
        XCTAssertTrue(allViews(keyboard.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.清空" })
        // 经典布局第 3 行右侧现在是「，」；侧栏独有的「。」「？！」不存在。
        XCTAssertTrue(allViews(keyboard.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.，" })
        XCTAssertFalse(allViews(keyboard.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.。" })
        XCTAssertFalse(allViews(keyboard.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.？！" })
        try typeNineKey("64426", keyboard)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
        try tap("candidate.0", keyboard)
        XCTAssertEqual(keyboard.document.text, "你好")
        // 布局面板里切回新布局。
        try tap("layout.settings", keyboard)
        let control = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "layout.ninekey" })
        XCTAssertEqual(control.numberOfSegments, 2)
        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        try tap("layout.done", keyboard)
        XCTAssertEqual(KeyboardPreferences.load().nineKeyLayout, .sidebar)
        XCTAssertTrue(allViews(keyboard.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.。" })
    }

    /// 新布局是默认值；旧版本保存的手感快照（没有该字段）仍能解码。
    func testNineKeyLayoutPreferenceDefaultsAndRoundTrips() throws {
        XCTAssertEqual(KeyboardPreferences().nineKeyLayout, .sidebar)
        var preferences = KeyboardPreferences()
        preferences.nineKeyLayout = .classic
        preferences.save()
        XCTAssertEqual(KeyboardPreferences.load().nineKeyLayout, .classic)
        let legacy = Data(#"{"keyHeight":52,"width":0.9,"alignment":0.4,"candidateFont":19,"bottomPadding":2,"entryPosition":0.3}"#.utf8)
        UserDefaults.standard.set(legacy, forKey: "keyboard.layout.v1")
        let restored = KeyboardPreferences.load()
        XCTAssertEqual(restored.keyHeight, 52)
        XCTAssertEqual(restored.width, 0.9, accuracy: 0.001)
        XCTAssertEqual(restored.nineKeyLayout, .sidebar)
        XCTAssertEqual(restored.gestureHold, KeyboardGestureDefaults.hold)
    }

    // MARK: - 长按滑动手势与常用短语（第三轮）

    private func holdSwipe(on title: String, _ keyboard: FixtureKeyboard) throws -> HoldSwipeGestureRecognizer {
        let key = try button("key." + title, keyboard)
        return try XCTUnwrap(key.gestureRecognizers?.compactMap { $0 as? HoldSwipeGestureRecognizer }.first, "key.\(title) 缺少长按滑动识别器")
    }

    private func trigger(_ gesture: HoldSwipeGestureRecognizer, _ direction: HoldSwipeDirection, hold: TimeInterval) {
        gesture.begin()
        gesture.update(elapsed: hold + 0.01, translation: .zero)
        let translation: CGPoint
        switch direction {
        case .up: translation = CGPoint(x: 0, y: -40)
        case .down: translation = CGPoint(x: 0, y: 40)
        case .left: translation = CGPoint(x: -40, y: 0)
        case .right: translation = CGPoint(x: 40, y: 0)
        }
        gesture.update(elapsed: hold + 0.05, translation: translation)
    }

    func testHoldSwipePolicyTimingThresholdsAndDirections() {
        let policy = HoldSwipePolicy(holdDuration: 1, threshold: 28)
        // 未达到时长：不 arm、不触发。
        XCTAssertEqual(policy.outcome(elapsed: 0.5, translation: CGPoint(x: 0, y: -60), armed: false), .none)
        // 达到时长：只 arm，不因未滑动而触发。
        XCTAssertEqual(policy.outcome(elapsed: 1.02, translation: .zero, armed: false), .armed)
        XCTAssertEqual(policy.outcome(elapsed: 1.02, translation: .zero, armed: true), .none)
        // 四个方向。
        XCTAssertEqual(policy.outcome(elapsed: 1.1, translation: CGPoint(x: 0, y: -28), armed: true), .fire(.up))
        XCTAssertEqual(policy.outcome(elapsed: 1.1, translation: CGPoint(x: 0, y: 28), armed: true), .fire(.down))
        XCTAssertEqual(policy.outcome(elapsed: 1.1, translation: CGPoint(x: -28, y: 0), armed: true), .fire(.left))
        XCTAssertEqual(policy.outcome(elapsed: 1.1, translation: CGPoint(x: 28, y: 0), armed: true), .fire(.right))
        // 未达阈值 / 主方向 / 取消。
        XCTAssertNil(policy.direction(for: CGPoint(x: 12, y: 20)))
        XCTAssertEqual(policy.direction(for: CGPoint(x: 40, y: -30)), .right)
        XCTAssertEqual(policy.outcome(elapsed: 2, translation: CGPoint(x: 0, y: -60), armed: true, cancelled: true), .cancelled)
        // 有状态判定器：只触发一次，取消后不再触发。
        var tracker = HoldSwipeTracker(policy: policy)
        tracker.begin()
        XCTAssertFalse(tracker.armIfDue(elapsed: 0.4))
        XCTAssertNil(tracker.swipe(translation: CGPoint(x: 0, y: -40)))
        XCTAssertTrue(tracker.armIfDue(elapsed: 1))
        XCTAssertNil(tracker.swipe(translation: .zero))
        XCTAssertEqual(tracker.swipe(translation: CGPoint(x: 0, y: -40)), .up)
        XCTAssertNil(tracker.swipe(translation: CGPoint(x: 0, y: -60)), "只触发一次")
        tracker.begin()
        tracker.cancel()
        XCTAssertNil(tracker.swipe(translation: CGPoint(x: 0, y: -60)))
    }

    /// 删除键：3 秒上滑清空；普通点按仍然只删一个字。
    func testDeleteHoldSwipeClearsInputWithoutExtraDelete() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        let keyboard = fixture()
        keyboard.document.text = "保留"
        try typeNineKey("64426", keyboard)
        XCTAssertEqual(try button("candidate.0", keyboard).title(for: .normal), "你好")
        let delete = try holdSwipe(on: "⌫", keyboard)
        XCTAssertEqual(delete.policy.holdDuration, KeyboardGestureDefaults.clearHold, "清空手势固定 3 秒")
        delete.begin()
        delete.update(elapsed: 2.9, translation: .zero)
        XCTAssertNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.hint" }, "未到 3 秒不能提示")
        delete.update(elapsed: 3.01, translation: .zero)
        XCTAssertNotNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.hint" }, "armed 后要提示上滑")
        attachScreenshot("iPhone-gesture-clear-hint", keyboard)
        delete.update(elapsed: 3.05, translation: CGPoint(x: 0, y: -40))
        drain(keyboard)
        XCTAssertEqual(keyboard.document.text, "")
        XCTAssertEqual(keyboard.document.deletes, 2, "只删掉已上屏的两个字，不能多删")
        XCTAssertTrue(candidateTitles(keyboard).isEmpty, "清空后候选应消失")
        // 普通点按不受影响：仍然只删一个字。
        let second = fixture()
        second.document.text = "保留"
        try tap("key.⌫", second)
        XCTAssertEqual(second.document.text, "保")
    }

    /// 回车：长按下滑换行，有组合串时只提交一次。
    func testEnterHoldSwipeInsertsNewlineOnce() throws {
        let keyboard = fixture()
        try typePinyin("nihao", keyboard)
        trigger(try holdSwipe(on: "⏎", keyboard), .down, hold: KeyboardGestureDefaults.hold)
        drain(keyboard)
        XCTAssertEqual(keyboard.document.text, "你好\n")
        // 空组合串时下滑只换行。
        let empty = fixture()
        trigger(try holdSwipe(on: "⏎", empty), .down, hold: KeyboardGestureDefaults.hold)
        drain(empty)
        XCTAssertEqual(empty.document.text, "\n")
    }

    /// 九键数字键：上滑选数字/字母大小写、下滑短语、左右移动光标。
    func testDigitHoldSwipesPickLettersPhrasesAndCursor() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        let keyboard = fixture()
        // 未达到时长不触发。
        let two = try holdSwipe(on: "2 ABC", keyboard)
        two.begin()
        two.update(elapsed: 0.9, translation: CGPoint(x: 0, y: -40))
        XCTAssertNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.digits" })
        XCTAssertEqual(keyboard.document.text, "")
        // 上滑：数字 + 大小写字母。
        trigger(two, .up, hold: KeyboardPreferences.load().gestureHold)
        XCTAssertNotNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.digits" })
        for option in ["2", "A", "B", "C", "a", "b", "c"] { XCTAssertNotNil(try button("digit.option." + option, keyboard), option) }
        settle()
        attachScreenshot("iPhone-digit-options", keyboard)
        try tap("digit.option.B", keyboard)
        XCTAssertEqual(keyboard.document.text, "B")
        XCTAssertNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.digits" })
        // 下滑：常用短语条。
        let phrases = MobilePhrases.load()
        let three = try holdSwipe(on: "3 DEF", keyboard)
        trigger(three, .down, hold: KeyboardPreferences.load().gestureHold)
        XCTAssertNotNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.phrases" })
        settle()
        attachScreenshot("iPhone-phrase-strip", keyboard)
        try tap("phrase.0", keyboard)
        XCTAssertEqual(keyboard.document.text, "B" + phrases[0])
        XCTAssertNil(allViews(keyboard.view).first { $0.accessibilityIdentifier == "gesture.phrases" })
        // 数字 1 兼作页面键，长按上滑仍给数字与常用标点。
        let one = try holdSwipe(on: "1 · 符号", keyboard)
        trigger(one, .up, hold: KeyboardPreferences.load().gestureHold)
        XCTAssertNotNil(try button("digit.option.1", keyboard))
        XCTAssertNotNil(try button("digit.option.，", keyboard))
        try tap("gesture.close", keyboard)
        // 左右滑：移动光标。
        let before = keyboard.document.events
        let four = try holdSwipe(on: "4 GHI", keyboard)
        trigger(four, .left, hold: KeyboardPreferences.load().gestureHold)
        drain(keyboard)
        trigger(four, .right, hold: KeyboardPreferences.load().gestureHold)
        drain(keyboard)
        XCTAssertEqual(Array(keyboard.document.events.dropFirst(before.count)), ["cursor:-1", "cursor:1"])
        try tap("composition.clear", keyboard)
    }

    /// 常用短语：内置默认、清洗规则与主 App payload 接入。
    func testPhrasesDefaultsSanitizeAndImport() throws {
        XCTAssertEqual(MobilePhrases.load(), MobilePhrases.builtIn)
        let messy = "\n好的\n\n谢谢\n好的\n" + String(repeating: "长", count: MobilePhrases.maxLength + 1) + "\n" + (1...25).map { "第\($0)条" }.joined(separator: "\n")
        let cleaned = MobilePhrases.sanitize(text: messy)
        XCTAssertLessThanOrEqual(cleaned.count, MobilePhrases.limit)
        XCTAssertEqual(cleaned.first, "好的")
        XCTAssertEqual(cleaned.filter { $0 == "好的" }.count, 1)
        XCTAssertFalse(cleaned.contains { $0.count > MobilePhrases.maxLength })
        let keyboard = fixture()
        try tap("tools.open", keyboard)
        let tabs = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "tools.section" })
        tabs.selectedSegmentIndex = 3; tabs.sendActions(for: .valueChanged)
        XCTAssertNotNil(try button("tools.phrases", keyboard))
        XCTAssertNotNil(try button("tools.phrases.receive", keyboard))
        XCTAssertEqual(keyboard.importPhrases("甲\n乙\n甲\n\n丙"), 3)
        XCTAssertEqual(MobilePhrases.load(), ["甲", "乙", "丙"])
        let status = try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "tools.status" })
        XCTAssertEqual(status.text, "已保存 3 条常用短语")
        XCTAssertEqual(keyboard.importPhrases("\n  \n"), 0, "空内容不覆盖")
        XCTAssertEqual(MobilePhrases.load(), ["甲", "乙", "丙"])
        attachScreenshot("iPhone-phrases-tools", keyboard)
    }

    /// 工具键从键盘移除，但顶栏 tools.open 仍能打开面板。
    func testKeyboardHasNoToolKeyEverywhere() throws {
        for layout in NineKeyLayout.allCases {
            UserDefaults.standard.set("t9", forKey: "keyboard.method")
            var preferences = KeyboardPreferences()
            preferences.nineKeyLayout = layout
            preferences.save()
            let keyboard = fixture()
            XCTAssertFalse(allViews(keyboard.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.工具" || $0.title(for: .normal) == "工具" }, "\(layout) 仍有工具键")
            try tap("tools.open", keyboard)
            XCTAssertNotNil(try button("tools.close", keyboard), "\(layout) 顶栏工具入口失效")
            try tap("tools.close", keyboard)
            XCTAssertNotNil(try button("key.5 JKL", keyboard))
            attachScreenshot("iPhone-nine-key-\(layout.rawValue)", keyboard)
        }
        UserDefaults.standard.set("handwriting", forKey: "keyboard.method")
        let hand = fixture()
        XCTAssertFalse(allViews(hand.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "key.工具" })
        try tap("tools.open", hand)
        XCTAssertNotNil(try button("tools.close", hand))
    }

    /// 数字 1 兼作页面键；九键没有独立 123，QWERTY 保留。
    func testNineKeyOneKeySwitchesPagesAndNoSeparateNumbersKey() throws {
        UserDefaults.standard.set("t9", forKey: "keyboard.method")
        for layout in NineKeyLayout.allCases {
            var preferences = KeyboardPreferences()
            preferences.nineKeyLayout = layout
            preferences.save()
            let keyboard = fixture()
            XCTAssertNil(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "key.123" }, "\(layout) 不应有独立 123")
            try tap("key.1 · 符号", keyboard)
            XCTAssertNil(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "key.q" }, "\(layout) 未切到数字页")
            XCTAssertNotNil(try button("key.1", keyboard))
            XCTAssertNotNil(try button("key.ABC", keyboard))
            settle()
            attachScreenshot("iPhone-nine-key-numbers-\(layout.rawValue)", keyboard)
            try tap("key.1", keyboard)
            XCTAssertEqual(keyboard.document.text, "1")
            try tap("key.ABC", keyboard)
            XCTAssertNotNil(try button("key.2 ABC", keyboard), "\(layout) 未回到九键字母页")
            XCTAssertNil(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "key.q" }, "九键字母页不应出现 QWERTY 字母")
        }
        UserDefaults.standard.removeObject(forKey: "keyboard.method")
        let qwerty = fixture()
        XCTAssertNotNil(try button("key.123", qwerty), "QWERTY 仍有 123")
    }

}
