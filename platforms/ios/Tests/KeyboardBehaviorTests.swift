import XCTest
import UIKit

private final class MemoryDocument: NSObject, UITextDocumentProxy {
    var text = ""
    var hasText: Bool { !text.isEmpty }
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    let documentIdentifier = UUID()
    func insertText(_ value: String) { text += value }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
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
    override func setUp() {
        super.setUp()
        savedPreferences = UserDefaults.standard.data(forKey: "keyboard.layout.v1")
        savedAppearance = UserDefaults.standard.object(forKey: "keyboard.appearance")
        UserDefaults.standard.set(0, forKey: "keyboard.appearance")
        KeyboardPreferences().save()
    }
    override func tearDown() {
        UserDefaults.standard.set(savedPreferences, forKey: "keyboard.layout.v1")
        UserDefaults.standard.set(savedAppearance, forKey: "keyboard.appearance")
        super.tearDown()
    }
    private func fixture() -> FixtureKeyboard {
        let keyboard = FixtureKeyboard()
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 375, height: 289)
        keyboard.view.setNeedsLayout()
        keyboard.view.layoutIfNeeded()
        return keyboard
    }

    private func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
    private func button(_ id: String, _ keyboard: FixtureKeyboard, file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        try XCTUnwrap(allViews(keyboard.view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id || $0.title(for: .normal) == id }, "Missing button: \(id)", file: file, line: line)
    }
    private func tap(_ id: String, _ keyboard: FixtureKeyboard) throws {
        let target = try button(id, keyboard)
        UIView.performWithoutAnimation { target.sendActions(for: .touchUpInside) }
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
        let grip = try button("layout.drag", keyboard)
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
}
