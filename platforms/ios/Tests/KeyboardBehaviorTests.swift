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
    func insertText(_ value: String) { text += value; events.append("insert:" + value) }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
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
    override func setUp() {
        super.setUp()
        savedDraft=UserDefaults.standard.object(forKey:MobileToolsViewController.draftKey)
        UserDefaults.standard.removeObject(forKey:MobileToolsViewController.draftKey)
        savedMethod = UserDefaults.standard.object(forKey: "keyboard.method")
        UserDefaults.standard.removeObject(forKey: "keyboard.method")
        savedPreferences = UserDefaults.standard.data(forKey: "keyboard.layout.v1")
        savedAppearance = UserDefaults.standard.object(forKey: "keyboard.appearance")
        UserDefaults.standard.set(0, forKey: "keyboard.appearance")
        KeyboardPreferences().save()
    }
    override func tearDown() {
        UserDefaults.standard.set(savedPreferences, forKey: "keyboard.layout.v1")
        UserDefaults.standard.set(savedAppearance, forKey: "keyboard.appearance")
        UserDefaults.standard.set(savedMethod, forKey: "keyboard.method")
        UserDefaults.standard.set(savedDraft,forKey:MobileToolsViewController.draftKey)
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
        let grip = try button("tools.open", keyboard)
        XCTAssertLessThan(grip.convert(grip.bounds, to: keyboard.view).minX, 150)
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

}
