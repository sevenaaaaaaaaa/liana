import UIKit

/// 全平台统一设计 Token（docs/design/UNIFIED-DESIGN.md 为单一事实源）。
enum LianaTheme {
    static let bg = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x1C/255, green: 0x1C/255, blue: 0x22/255, alpha: 1) : UIColor(red: 0.87, green: 0.89, blue: 0.92, alpha: 1) }
    static let key = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x2A/255, green: 0x2A/255, blue: 0x33/255, alpha: 1) : .white }
    static let keyPressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x33/255, green: 0x33/255, blue: 0x3E/255, alpha: 1) : UIColor(white: 0.94, alpha: 1) }
    static let text = UIColor.label
    static let secondary = UIColor.secondaryLabel
    static let accent = UIColor(red: 0x33/255, green: 0x7B/255, blue: 0xFF/255, alpha: 1)
    static let fontCandidate: CGFloat = 17
    static let fontKey: CGFloat = 16
    static let padSplitMinWidth: CGFloat = 600
}

/// 松萝 iOS 键盘扩展。
///
/// Rust 拼音与移动端本地形码、手写、滑行解码由串行后台队列驱动。
/// 键盘扩展使用紧凑词库；内存预算随设备和系统而变。
///
/// 触控创新（统一设计语言 §3）：
/// - 全键触觉反馈（§3.1）
/// - 候选上滑直上屏（§3.2）
/// - 退格长按连删（§3.3）
/// - 折叠屏几何守恒 + 中缝工作台（FOLDABLE-ADAPTATION.md §4 §5）
class KeyboardViewController: UIInputViewController {

    // MARK: - 输入状态（与视图生命周期解耦：视图重建不得丢失）

    private let engine = MobileEngine()
    private var method = MobileInputMethod.saved
    private var english = false
    private var traditional = false
    private var latestRequest = 0
    private var candidateRaw = ""
    private var visibleForInput = true
    private var candidateButtons: [UIButton] = []
    private var renderedCandidates: [String] = []
    private var renderedCandidateFont: Double = 0
    private var handwritingPanel: HandwritingPanel?
    private var featurePanel: KeyboardToolsPanel?
    private var clipboardSender: PetLinkSender?
    private var glidePoints: [CGPoint] = []
    private var candidates: [String] = []
    private var rawInput = ""
    private var composingText = ""
    private enum Page { case letters, numbers, symbols }
    private var page: Page = .letters
    private var shifted = false
    private var capsLocked = false
    private var lastShiftTap: TimeInterval = 0
    private var saveWork: DispatchWorkItem?
    private var documentID: UUID?
    private var heightConstraint: NSLayoutConstraint?
    private var composingLabel: UILabel!
    private var clearButton: UIButton!
    private var returnButtons: [UIButton] = []
    private var preferences = KeyboardPreferences.load()
    private var entryDock: UIStackView!
    private var entryLeading: NSLayoutConstraint!
    private var compositionLeading: NSLayoutConstraint!
    private var compositionWidth: NSLayoutConstraint!
    private var areaHeight: NSLayoutConstraint!
    private var rootBottom: NSLayoutConstraint!
    private var adjustmentPanel: UIView?
    private var devicePanel: BluetoothDevicePanel?
    private var dragStart = KeyboardPreferences()
    private var geometrySave: DispatchWorkItem?
    private var isAdjusting = false
    private var rows: [String] {
        switch page {
        case .letters: return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .numbers: return ["1234567890", "-/:;()$&@\"", ".,?!'"]
        case .symbols: return ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]
        }
    }
    private var shiftTitle: String { page == .letters ? (capsLocked ? "⇪" : "⇧") : (page == .numbers ? "#+=" : "123") }

    // MARK: - 视图

    private var candidateStrip: UIStackView!
    private var modeButton: UIButton!
    private var tradButton: UIButton!
    private var backspaceButtons: [UIButton] = []
    private var keyboardArea: UIView!

    /// 中缝工作台（仅分体形态存在）
    private var wbComposing: UILabel?
    private var wbGrid: UIStackView?
    private var wbCursor: UIStackView?

    private var repeatTimer: Timer?
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticStrong = UIImpactFeedbackGenerator(style: .medium)

    private static let rowSpacing: CGFloat = 5
    private static let stripHeight: CGFloat = 46
    private static let headerHeight: CGFloat = 44
    private static let cursorRowHeight: CGFloat = 34
    private static let wbCandidateRowHeight: CGFloat = 52
    private var keyboardAreaHeight: CGFloat { 4 * CGFloat(preferences.keyHeight) + 3 * Self.rowSpacing }

    /// 当前几何签名；空串表示尚未构建。
    private var layoutSignature = ""
    private var isAssembling = false

    // MARK: - 生命周期

    override func loadView() {
        let root = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        root.allowsSelfSizing = true
        view = root
        inputView = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAppearance()
        engine.onUpdate = { [weak self] in self?.receive($0) }
        primaryLanguage = "zh-Hans"
        buildUI()
        latestRequest = engine.start(bundle: Bundle(for: KeyboardViewController.self), mode: method.rawValue)
        hapticLight.prepare()
        hapticStrong.prepare()
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); visibleForInput = true }

    override func viewWillDisappear(_ animated: Bool) {
        saveWork?.cancel()
        visibleForInput = false
        rawInput = ""; candidateRaw = ""; candidates = []; composingText = ""
        handwritingPanel?.clear(); renderCandidates()
        clipboardSender?.disconnect(); clipboardSender = nil
        _ = engine.submit(.save, document: nil)
        preferences.save()
        devicePanel?.stop()
        devicePanel?.removeFromSuperview()
        devicePanel = nil
        stopRepeat()
        _ = engine.submit(.clear, document: nil)
        super.viewWillDisappear(animated)
    }

    deinit {
        repeatTimer?.invalidate()
        saveWork?.cancel()
        geometrySave?.cancel()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        let id = textDocumentProxy.documentIdentifier
        if let previous = documentID, previous != id {
            devicePanel?.stop()
            send(.clear)
        }
        documentID = id
    }

    private func send(_ action: MobileEngine.Action) {
        let id = textDocumentProxy.documentIdentifier
        if let documentID, documentID != id { _ = engine.submit(.clear, document: id) }
        documentID = id
        latestRequest = engine.submit(action, document: id)
    }
    func whenInputIdle(_ completion: @escaping () -> Void) { engine.whenIdle(completion) }
    private func receive(_ update: MobileEngine.Update) {
        guard visibleForInput, update.document == nil || update.document == textDocumentProxy.documentIdentifier else { return }
        if !update.committed.isEmpty {
            textDocumentProxy.insertText(update.committed)
            if update.sequence >= latestRequest { handwritingPanel?.clear() }
            scheduleSave()
        }
        for _ in 0..<update.deletes { textDocumentProxy.deleteBackward() }
        guard update.sequence >= latestRequest else { return }
        candidates = update.snapshot.candidates
        rawInput = update.snapshot.raw
        candidateRaw = rawInput
        composingText = update.snapshot.message ?? update.snapshot.preedit
        renderCandidates()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.engine.submit(.save, document: nil) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    // MARK: - UI 骨架（只建一次：候选栏 + 可重建的键盘区）

    private func buildUI() {
        view.backgroundColor = LianaTheme.bg

        let root = UIStackView()
        root.axis = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        rootBottom = root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8 - CGFloat(preferences.bottomPadding))
        rootBottom.isActive = true

        let header = UIView()
        header.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        composingLabel = UILabel()
        composingLabel.font = .systemFont(ofSize: 12)
        composingLabel.textColor = LianaTheme.secondary
        composingLabel.lineBreakMode = .byTruncatingMiddle
        composingLabel.accessibilityIdentifier = "composition"
        composingLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(composingLabel)
        compositionLeading = composingLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8)
        compositionWidth = composingLabel.widthAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([compositionLeading, compositionWidth, composingLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        entryDock = UIStackView()
        entryDock.axis = .horizontal
        entryDock.distribution = .fillEqually
        entryDock.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(entryDock)
        entryLeading = entryDock.leadingAnchor.constraint(equalTo: header.leadingAnchor)
        NSLayoutConstraint.activate([entryLeading, entryDock.widthAnchor.constraint(equalToConstant: 220), entryDock.heightAnchor.constraint(equalToConstant: 44), entryDock.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        let grip = toolbarButton("arrow.up.and.down.and.arrow.left.and.right", label: "拖动调高度与入口位置", id: "layout.drag")
        grip.menu = UIMenu(children: [UIAction(title: "输入工具：方案、词库、表情、语音、同步") { [weak self] _ in self?.toggleTools() }])
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragLayout(_:))))
        grip.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "增高键盘", target: self, selector: #selector(increaseHeight)),
            UIAccessibilityCustomAction(name: "降低键盘", target: self, selector: #selector(decreaseHeight)),
        ]
        entryDock.addArrangedSubview(grip)
        let settings = toolbarButton("slider.horizontal.3", label: "调整键盘比例", id: "layout.settings")
        settings.addAction(UIAction { [weak self] _ in self?.toggleAdjustments() }, for: .touchUpInside)
        settings.menu = UIMenu(children: [UIAction(title: "输入工具 · 词库／表情／语音／剪贴板") { [weak self] _ in self?.toggleTools() }])
        entryDock.addArrangedSubview(settings)
        let devices = toolbarButton("waveform", label: "连接语音与编码设备", id: "devices.open")
        devices.addAction(UIAction { [weak self] _ in self?.toggleDevices() }, for: .touchUpInside)
        entryDock.addArrangedSubview(devices)
        clearButton = UIButton(type: .system)
        clearButton.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
        clearButton.accessibilityIdentifier = "composition.clear"
        clearButton.accessibilityLabel = "取消当前拼音"
        clearButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.handwritingPanel?.clear()
            self.send(.clear)
        }, for: .touchUpInside)
        entryDock.addArrangedSubview(clearButton)
        let tools = toolbarButton("square.grid.2x2", label: "输入工具：词库、表情、语音与同步", id: "tools.open")
        tools.addAction(UIAction { [weak self] _ in self?.toggleTools() }, for: .touchUpInside)
        entryDock.addArrangedSubview(tools)
        tradButton = UIButton(type: .system)
        tradButton.setTitle("简", for: .normal)
        tradButton.accessibilityLabel = "切换简繁体"
        tradButton.addAction(UIAction { [weak self] _ in self?.onTraditionalToggle() }, for: .touchUpInside)
        root.addArrangedSubview(header)
        heightConstraint = view.heightAnchor.constraint(equalToConstant: Self.headerHeight + Self.stripHeight + keyboardAreaHeight + 8 + CGFloat(preferences.bottomPadding))
        heightConstraint?.priority = .init(999)
        heightConstraint?.isActive = true

        // 候选栏（横向滚动）
        let scroll = UIScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: Self.stripHeight).isActive = true
        candidateStrip = UIStackView()
        candidateStrip.translatesAutoresizingMaskIntoConstraints = false
        candidateStrip.axis = .horizontal
        candidateStrip.spacing = 6
        candidateStrip.layoutMargins = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
        candidateStrip.isLayoutMarginsRelativeArrangement = true
        candidateStrip.insetsLayoutMarginsFromSafeArea = false
        scroll.addSubview(candidateStrip)
        NSLayoutConstraint.activate([
            candidateStrip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            candidateStrip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            candidateStrip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            candidateStrip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            candidateStrip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        root.addArrangedSubview(scroll)

        // 键盘区：几何随宽度变化整体重建（字母行 + 功能行 + 中缝工作台）
        let area = UIView()
        area.translatesAutoresizingMaskIntoConstraints = false
        areaHeight = area.heightAnchor.constraint(equalToConstant: keyboardAreaHeight)
        areaHeight.isActive = true
        keyboardArea = area
        let glide = GlidePan(target: self, action: #selector(onGlide(_:)))
        glide.allow = { [weak self] point in
            guard let self, self.page == .letters, (self.english || self.method == .pinyin), self.featurePanel == nil, self.adjustmentPanel == nil, self.devicePanel == nil,
                  let key = self.keyboardArea.hitTest(point, with: nil) as? UIButton, let title = key.title(for: .normal) else { return false }
            return title.count == 1 && title.first!.isASCII && title.first!.isLetter
        }
        area.addGestureRecognizer(glide)
        root.addArrangedSubview(area)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGeometry()
        rebuildKeyboardIfNeeded(animated: !layoutSignature.isEmpty)
    }

    /// L1 连续性：只有几何签名变化才重建，且重建只换视图、不动输入状态。
    private func rebuildKeyboardIfNeeded(animated: Bool) {
        guard !isAssembling else { return }
        let width = view.bounds.width
        guard width > 0 else { return }

        let effectiveWidth = width >= 600 ? width : preferences.contentWidth(in: width)
        let layout = FoldLayout.derive(
            width: effectiveWidth,
            regularWidth: traitCollection.horizontalSizeClass == .regular,
            rememberedSoloPitch: FoldLayoutMemory.rememberedSoloPitch,
            keyHeight: CGFloat(preferences.keyHeight)
        )
        let signature = layout.signature + "-\(width)-\(preferences.alignment)-\(page)-\(shifted)-\(capsLocked)-\(currentMode())"
        guard signature != layoutSignature else { return }

        layoutSignature = signature
        if layout.mode == .solo {
            FoldLayoutMemory.rememberSolo(pitch: layout.pitch, width: width)
        }

        isAssembling = true
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            if self.method == .handwriting && !self.english && self.page == .letters {
                self.assembleHandwriting()
            } else if self.method == .t9 && !self.english && self.page == .letters {
                self.assembleNineKey(layout)
            } else { switch layout.mode {
            case .solo: self.assembleSolo(layout)
            case .split: self.assembleSplit(layout)
            } }
            self.keyboardArea.layoutIfNeeded()
        }
        apply()
        isAssembling = false

        // 重建后：中/简/EN 标题、候选都必须原地恢复（L2）
        syncModeLabels()
        renderCandidates()
        if let adjustmentPanel { keyboardArea.bringSubviewToFront(adjustmentPanel) }
        if let devicePanel { keyboardArea.bringSubviewToFront(devicePanel) }
        if let featurePanel { keyboardArea.bringSubviewToFront(featurePanel) }
    }

    // MARK: - 布局 A：单块（外屏 / 手机）

    private func assembleSolo(_ layout: FoldLayout) {
        resetKeyboardArea()

        let avail = layout.clusterWidth
        let p = layout.pitch
        let rows = self.rows

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Self.rowSpacing
        column.alignment = .center
        column.translatesAutoresizingMaskIntoConstraints = false
        keyboardArea.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: keyboardArea.leadingAnchor, constant: (view.bounds.width - avail - 2 * layout.margin) * CGFloat(preferences.alignment) + layout.margin + avail / 2),
            column.topAnchor.constraint(equalTo: keyboardArea.topAnchor),
            column.bottomAnchor.constraint(equalTo: keyboardArea.bottomAnchor),
        ])

        for (i, keys) in rows.enumerated() {
            var items: [(String, CGFloat, () -> Void)] = []
            let geometry = layout.thirdRowGeometry(keyCount: keys.count)
            let sideWidth = geometry.sideWidth
            if i == 2 { items.append((shiftTitle, sideWidth, { [weak self] in self?.onShift() })) }
            for ch in keys {
                let title = page == .letters && shifted ? String(ch).uppercased() : String(ch)
                items.append((title, i == 2 ? geometry.keyWidth : p, { [weak self] in self?.onCharacter(ch) }))
            }
            if i == 2 { items.append(("⌫", sideWidth, { [weak self] in self?.onBackspace() })) }
            let row = letterRow(items, height: layout.keyHeight)
            if i == 2 { attachBackspace(in: row) }
            column.addArrangedSubview(row)
        }

        // 功能行（外屏通栏，拇指公共区）
        column.addArrangedSubview(soloFunctionRow(layout, avail: avail))
    }

    private func soloFunctionRow(_ layout: FoldLayout, avail: CGFloat) -> UIStackView {
        let fnWidth = min(50, (avail - 72 - 5 * layout.gap) / 5)
        let spaceWidth = avail - 5 * fnWidth - 5 * layout.gap
        let items: [(String, CGFloat, () -> Void)] = [
            (page == .letters ? "123" : "ABC", fnWidth, { [weak self] in self?.togglePage() }),
            ("🌐", fnWidth, {}),
            ("中", fnWidth, { [weak self] in self?.onModeToggle() }),
            ("空格", spaceWidth, { [weak self] in self?.onSpace() }),
            (!english && method == .mspy ? ";" : (!english ? "，" : ","), fnWidth, { [weak self] in self?.onPunctuation() }),
            ("⏎", fnWidth, { [weak self] in self?.onEnter() }),
        ]
        let row = letterRow(items, height: layout.keyHeight)
        modeButton = row.arrangedSubviews[2] as? UIButton
        configureModeMenu()
        return row
    }

    // MARK: - 布局 B：左右分体 + 中缝工作台（内屏 / Pad）

    private func assembleSplit(_ layout: FoldLayout) {
        resetKeyboardArea()

        let gap = layout.gap
        let cw = layout.clusterWidth
        let rows = self.rows
        // 与既有实现一致的双手分配：10→5/5、9→5/4、7→4/3
        let mids = [5, 5, 4]

        var leftRows: [UIStackView] = []
        var rightRows: [UIStackView] = []

        for (i, keys) in rows.enumerated() {
            let mid = mids[i]
            let leftKeys = keys.prefix(mid).map(String.init)
            let rightKeys = keys.dropFirst(mid).map(String.init)

            leftRows.append(clusterLetterRow(leftKeys, layout: layout, backspace: false, shift: i == 2))
            rightRows.append(clusterLetterRow(rightKeys, layout: layout, backspace: i == 2))
        }

        // 功能行：中/简/，/空格 贴内侧，. / ⏎ 靠外侧；空格两侧各一颗（拇指互不越界）
        let fnWidth = min(44, (cw - 64 - 3 * gap) / 3)
        let leftSpace = max(64, cw - 3 * fnWidth - 3 * gap)
        let leftFnItems: [(String, CGFloat, () -> Void)] = [
            (page == .letters ? "123" : "ABC", fnWidth, { [weak self] in self?.togglePage() }),
            ("🌐", fnWidth, {}),
            ("中", fnWidth, { [weak self] in self?.onModeToggle() }),
            ("空格", leftSpace, { [weak self] in self?.onSpace() }),
        ]
        let rightSpace = max(64, cw - 2 * fnWidth - 2 * gap)
        let rightFnItems: [(String, CGFloat, () -> Void)] = [
            ("空格", rightSpace, { [weak self] in self?.onSpace() }),
            (!english && method == .mspy ? ";" : ".", fnWidth, { [weak self] in
                if self?.method == .mspy && self?.english == false { self?.send(.feed(";")) } else { self?.insertText(".") }
            }),
            ("⏎", fnWidth, { [weak self] in self?.onEnter() }),
        ]

        let leftFn = letterRow(leftFnItems, height: layout.keyHeight)
        let rightFn = letterRow(rightFnItems, height: layout.keyHeight)
        modeButton = leftFn.arrangedSubviews[2] as? UIButton

        // 左侧键组贴左边缘、右侧贴右边缘：中缝吸收全部富余宽度
        let leftCluster = clusterStack(leftRows + [leftFn], alignment: .leading, width: cw)
        let rightCluster = clusterStack(rightRows + [rightFn], alignment: .trailing, width: cw)
        let gutter = makeWorkbench()

        let halves = UIStackView(arrangedSubviews: [leftCluster, gutter, rightCluster])
        halves.axis = .horizontal
        halves.alignment = .fill
        halves.spacing = 0
        halves.translatesAutoresizingMaskIntoConstraints = false
        keyboardArea.addSubview(halves)
        NSLayoutConstraint.activate([
            halves.leadingAnchor.constraint(equalTo: keyboardArea.leadingAnchor, constant: layout.margin),
            halves.trailingAnchor.constraint(equalTo: keyboardArea.trailingAnchor, constant: -layout.margin),
            halves.topAnchor.constraint(equalTo: keyboardArea.topAnchor),
            halves.bottomAnchor.constraint(equalTo: keyboardArea.bottomAnchor),
        ])

        renderWorkbench()
    }

    private func clusterStack(_ rows: [UIStackView], alignment: UIStackView.Alignment, width: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = Self.rowSpacing
        stack.alignment = alignment
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    /// 一侧字母行：字母键距恒为 pitch；底行的退格吸收本组剩余宽度。
    private func clusterLetterRow(_ titles: [String], layout: FoldLayout, backspace: Bool, shift: Bool = false) -> UIStackView {
        var items: [(String, CGFloat, () -> Void)] = []
        if shift { items.append((shiftTitle, layout.pitch, { [weak self] in self?.onShift() })) }
        for t in titles {
            guard let ch = t.first else { continue }
            let title = page == .letters && shifted ? t.uppercased() : t
            items.append((title, layout.pitch, { [weak self] in self?.onCharacter(ch) }))
        }
        if backspace {
            let used = CGFloat(titles.count) * layout.pitch + CGFloat(titles.count) * layout.gap
            items.append(("⌫", max(layout.pitch, layout.clusterWidth - used), { [weak self] in self?.onBackspace() }))
        }
        let row = letterRow(items, height: layout.keyHeight)
        if backspace { attachBackspace(in: row) }
        return row
    }

    // MARK: - 中缝工作台（候选网格 + 光标移动 + 组合串）

    private func makeWorkbench() -> UIView {
        let gutter = UIView()
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        box.isLayoutMarginsRelativeArrangement = true

        let composing = UILabel()
        composing.font = .systemFont(ofSize: 12)
        composing.textColor = LianaTheme.secondary
        composing.textAlignment = .center
        composing.lineBreakMode = .byTruncatingTail
        composing.heightAnchor.constraint(equalToConstant: 16).isActive = true
        wbComposing = composing
        box.addArrangedSubview(composing)

        // 候选网格：可竖向滚动，保证每个候选 ≥ 44pt 热区（不可达区不放高频键）
        let gridScroll = UIScrollView()
        gridScroll.contentInsetAdjustmentBehavior = .never
        gridScroll.showsVerticalScrollIndicator = false
        gridScroll.translatesAutoresizingMaskIntoConstraints = false
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.trailingAnchor),
            grid.topAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.bottomAnchor),
            grid.widthAnchor.constraint(equalTo: gridScroll.frameLayoutGuide.widthAnchor),
        ])
        wbGrid = grid
        box.addArrangedSubview(gridScroll)

        let cursor = UIStackView()
        cursor.axis = .horizontal
        cursor.spacing = 4
        cursor.distribution = .fillEqually
        cursor.heightAnchor.constraint(equalToConstant: Self.cursorRowHeight).isActive = true
        cursor.addArrangedSubview(keyButton("←") { [weak self] in self?.moveCursor(-1) })
        cursor.addArrangedSubview(keyButton("→") { [weak self] in self?.moveCursor(1) })
        wbCursor = cursor
        box.addArrangedSubview(cursor)

        gutter.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: gutter.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: gutter.trailingAnchor),
            box.topAnchor.constraint(equalTo: gutter.topAnchor),
            box.bottomAnchor.constraint(equalTo: gutter.bottomAnchor),
        ])
        return gutter
    }

    private func renderWorkbench() {
        guard let grid = wbGrid, let composing = wbComposing else { return }
        composing.text = composingText.isEmpty ? "中缝 · 候选与光标" : composingText
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let shown = Array(candidates.prefix(9))
        guard !shown.isEmpty else {
            let hint = UILabel()
            hint.text = "候选随输入出现在这里"
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = LianaTheme.secondary
            hint.textAlignment = .center
            hint.numberOfLines = 2
            let wrapper = UIStackView(arrangedSubviews: [hint])
            wrapper.isLayoutMarginsRelativeArrangement = true
            wrapper.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            wrapper.heightAnchor.constraint(equalToConstant: Self.wbCandidateRowHeight).isActive = true
            grid.addArrangedSubview(wrapper)
            return
        }

        var index = 0
        while index < shown.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            row.distribution = .fillEqually
            for offset in 0..<2 {
                let i = index + offset
                if i < shown.count {
                    row.addArrangedSubview(workbenchCandidate(shown[i], index: i))
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            row.heightAnchor.constraint(equalToConstant: Self.wbCandidateRowHeight).isActive = true
            grid.addArrangedSubview(row)
            index += 2
        }
    }

    private func workbenchCandidate(_ text: String, index: Int) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.setTitleColor(LianaTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: CGFloat(preferences.candidateFont), weight: .bold)
        b.titleLabel?.lineBreakMode = .byTruncatingTail
        b.backgroundColor = LianaTheme.keyPressed
        b.layer.cornerRadius = 6
        b.addAction(UIAction { [weak self] _ in
            self?.hapticStrong.impactOccurred()
            self?.selectCandidate(index)
        }, for: .touchUpInside)
        return b
    }

    private func moveCursor(_ delta: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
    }

    private func resetKeyboardArea() {
        keyboardArea.subviews.filter { $0 !== adjustmentPanel && $0 !== devicePanel && $0 !== featurePanel }.forEach { $0.removeFromSuperview() }
        handwritingPanel = nil
        backspaceButtons.removeAll()
        returnButtons.removeAll()
        wbComposing = nil
        wbGrid = nil
        wbCursor = nil
    }

    // MARK: - 视图工厂

    private func toolbarButton(_ symbol: String, label: String, id: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        return button
    }

    private func applyAppearance() {
        switch UserDefaults.standard.integer(forKey: "keyboard.appearance") {
        case 1: overrideUserInterfaceStyle = .light
        case 2: overrideUserInterfaceStyle = .dark
        default: overrideUserInterfaceStyle = .unspecified
        }
    }

    private func updateGeometry() {
        let requested = Self.headerHeight + Self.stripHeight + keyboardAreaHeight + view.safeAreaInsets.bottom + 8 + CGFloat(preferences.bottomPadding)
        heightConstraint?.constant = requested
        (inputView as? KeyboardInputView)?.requestedHeight = requested
        preferredContentSize = CGSize(width: view.bounds.width, height: requested)
        areaHeight?.constant = keyboardAreaHeight
        rootBottom?.constant = -8 - CGFloat(preferences.bottomPadding)
        guard entryDock != nil else { return }
        let travel = max(0, view.bounds.width - 220 - 8)
        let x = 4 + travel * CGFloat(preferences.entryPosition)
        entryLeading.constant = x
        let leftSpace = x - 12
        let rightSpace = view.bounds.width - x - 220 - 12
        compositionLeading.constant = leftSpace >= rightSpace ? 8 : x + 228
        compositionWidth.constant = max(0, max(leftSpace, rightSpace))
        if let adjustmentPanel { keyboardArea.bringSubviewToFront(adjustmentPanel) }
        if let devicePanel { keyboardArea.bringSubviewToFront(devicePanel) }
        if let featurePanel { keyboardArea.bringSubviewToFront(featurePanel) }
    }

    private func applyPreferences(persist: Bool = true) {
        preferences.normalize()
        isAdjusting = true
        updateGeometry()
        rebuildKeyboardIfNeeded(animated: false)
        renderCandidates()
        view.setNeedsLayout()
        isAdjusting = false
        if persist {
            geometrySave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.preferences.save() }
            geometrySave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    @objc private func increaseHeight() -> Bool { preferences.keyHeight += 2; applyPreferences(); return true }
    @objc private func decreaseHeight() -> Bool { preferences.keyHeight -= 2; applyPreferences(); return true }

    @objc private func dragLayout(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dragStart = preferences }
        let delta = gesture.translation(in: nil)
        if gesture.state == .changed || gesture.state == .ended {
            preferences.keyHeight = dragStart.keyHeight - Double(delta.y) / 4
            let travel = max(1, view.bounds.width - 184)
            preferences.entryPosition = dragStart.entryPosition + Double(delta.x / travel)
            applyPreferences(persist: gesture.state == .ended)
        } else if gesture.state == .cancelled || gesture.state == .failed {
            preferences = dragStart
            applyPreferences()
        }
    }

    private func installPanel(_ panel: UIView) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        keyboardArea.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: keyboardArea.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: keyboardArea.trailingAnchor),
            panel.topAnchor.constraint(equalTo: keyboardArea.topAnchor),
            panel.bottomAnchor.constraint(equalTo: keyboardArea.bottomAnchor),
        ])
    }

    private func toggleAdjustments() {

        if let adjustmentPanel { adjustmentPanel.removeFromSuperview(); self.adjustmentPanel = nil; return }
        featurePanel?.removeFromSuperview(); featurePanel = nil
        devicePanel?.stop()
        devicePanel?.removeFromSuperview()
        devicePanel = nil
        let panel = UIView()
        panel.backgroundColor = LianaTheme.bg
        adjustmentPanel = panel
        installPanel(panel)
        let scroll = UIScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor), scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24),
        ])
        let actions = UIStackView()
        actions.distribution = .fillEqually
        let reset = UIButton(type: .system)
        reset.setTitle("恢复默认", for: .normal)
        reset.accessibilityIdentifier = "layout.reset"
        reset.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.preferences = KeyboardPreferences()
            UserDefaults.standard.set(0, forKey: "keyboard.appearance")
            self.applyAppearance()
            self.applyPreferences()
            self.adjustmentPanel?.removeFromSuperview()
            self.adjustmentPanel = nil
            self.toggleAdjustments()
        }, for: .touchUpInside)
        actions.addArrangedSubview(reset)
        actions.addArrangedSubview(tradButton)
        let done = UIButton(type: .system)
        done.setTitle("完成", for: .normal)
        done.addAction(UIAction { [weak self] _ in self?.toggleAdjustments() }, for: .touchUpInside)
        actions.addArrangedSubview(done)
        actions.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(actions)
        let theme = UISegmentedControl(items: ["跟随系统", "白色", "黑色"])
        theme.selectedSegmentIndex = min(2, max(0, UserDefaults.standard.integer(forKey: "keyboard.appearance")))
        theme.accessibilityLabel = "键盘黑白主题"
        theme.accessibilityIdentifier = "layout.appearance"
        theme.heightAnchor.constraint(equalToConstant: 44).isActive = true
        theme.addAction(UIAction { [weak self, weak theme] _ in
            guard let self, let theme else { return }
            UserDefaults.standard.set(theme.selectedSegmentIndex, forKey: "keyboard.appearance")
            self.applyAppearance()
        }, for: .valueChanged)
        stack.addArrangedSubview(theme)
        let hint = UILabel()
        hint.text = "上下拖动顶部四向箭头调高度，左右拖动移动入口。也可用下方滑块或加减按钮。窄屏保留最小可用宽度。"
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        stack.addArrangedSubview(hint)
        let fields: [(String, String, WritableKeyPath<KeyboardPreferences, Double>, ClosedRange<Float>, Float)] = [
            ("按键高度 pt", "height", \.keyHeight, 44...64, 2),
            ("目标宽度 %", "width", \.width, 0.78...1, 0.02),
            ("左右位置 %", "alignment", \.alignment, 0...1, 0.1),
            ("候选字号 pt", "font", \.candidateFont, 14...24, 1),
            ("底部留白 pt", "padding", \.bottomPadding, 0...24, 2),
            ("入口位置 %", "entry", \.entryPosition, 0...1, 0.1),
        ]
        for (title, id, path, range, step) in fields {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .subheadline)
            let slider = UISlider()
            slider.minimumValue = range.lowerBound
            slider.maximumValue = range.upperBound
            slider.value = Float(preferences[keyPath: path])
            slider.accessibilityLabel = title
            slider.accessibilityIdentifier = "layout." + id
            let update: () -> Void = { [weak self, weak slider, weak label] in
                guard let self, let slider else { return }
                self.preferences[keyPath: path] = Double(slider.value)
                self.applyPreferences()
                let value = slider.value * (range.upperBound <= 1 ? 100 : 1)
                label?.text = title + "  " + String(Int(value.rounded()))
            }
            label.text = title + "  " + String(Int((slider.value * (range.upperBound <= 1 ? 100 : 1)).rounded()))
            slider.addAction(UIAction { _ in update() }, for: .valueChanged)
            stack.addArrangedSubview(label)
            let row = UIStackView()
            row.spacing = 8
            for direction in [-1, 1] {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: direction < 0 ? "minus.circle" : "plus.circle"), for: .normal)
                button.accessibilityLabel = (direction < 0 ? "减少" : "增加") + title
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.addAction(UIAction { [weak slider] _ in
                    guard let slider else { return }
                    slider.value += Float(direction) * step
                    update()
                }, for: .touchUpInside)
                row.addArrangedSubview(button)
                if direction < 0 { row.addArrangedSubview(slider) }
            }
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    private func toggleDevices() {
        if let devicePanel { devicePanel.stop(); devicePanel.removeFromSuperview(); self.devicePanel = nil; return }
        featurePanel?.removeFromSuperview(); featurePanel = nil
        adjustmentPanel?.removeFromSuperview()
        adjustmentPanel = nil
        let panel = BluetoothDevicePanel(hasFullAccess: { [weak self] in self?.hasFullAccess ?? false }, insert: { [weak self] text in
            self?.commitPending()
            self?.insertText(text)
        })
        devicePanel = panel
        installPanel(panel)
    }

    private func letterRow(_ items: [(String, CGFloat, () -> Void)], height: CGFloat) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = FoldLayout.gapConst
        row.alignment = .fill
        for (title, width, action) in items {
            let b = keyButton(title, action: action)
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
            row.addArrangedSubview(b)
        }
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        return row
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(LianaTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: LianaTheme.fontKey, weight: .semibold)
        b.backgroundColor = LianaTheme.key
        b.layer.cornerRadius = 8
        b.accessibilityIdentifier = "key." + title
        if title == "🌐" {
            b.setTitle(nil, for: .normal)
            b.setImage(UIImage(systemName: "globe"), for: .normal)
            b.tintColor = LianaTheme.text
            b.accessibilityLabel = "切换键盘，长按选择输入法"
            b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        } else {
            b.addAction(UIAction { [weak self] _ in
                self?.hapticLight.impactOccurred()
                action()
            }, for: .touchUpInside)
        }
        if title == "⏎" {
            b.setTitle(nil, for: .normal)
            b.setImage(UIImage(systemName: "return"), for: .normal)
            b.tintColor = LianaTheme.text
            b.accessibilityLabel = "换行"
            returnButtons.append(b)
        }
        if title == shiftTitle { b.accessibilityLabel = page == .letters ? "切换大写，连点锁定" : "切换符号" }
        return b
    }

    // MARK: - 退格长按连删（§3.3）

    private func attachBackspace(in row: UIStackView) {
        for v in row.arrangedSubviews {
            guard let b = v as? UIButton, b.title(for: .normal) == "⌫" else { continue }
            attachBackspaceGestures(to: b)
        }
    }

    private func attachBackspaceGestures(to button: UIButton) {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onBackspaceLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        button.addGestureRecognizer(longPress)
        backspaceButtons.append(button)
    }

    @objc private func onBackspaceLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            hapticStrong.impactOccurred()
            onBackspace()
            startRepeat()
        case .ended, .cancelled:
            stopRepeat()
        default: break
        }
    }

    private func startRepeat() {
        guard repeatTimer == nil else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in
            self?.onBackspace()
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - 按键行为（与 macOS/Android 端约定一致）

    private func onCharacter(_ ch: Character) {
        if page != .letters { commitPending(); insertText(String(ch)); return }
        onLetter(ch)
    }

    private func onShift() {
        if page != .letters { page = page == .numbers ? .symbols : .numbers }
        else {
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastShiftTap < 0.3 { capsLocked = true; shifted = true }
            else { shifted.toggle(); capsLocked = false }
            lastShiftTap = now
        }
        rebuildKeyboardIfNeeded(animated: false)
    }

    private func togglePage() {
        commitPending()
        page = page == .letters ? .numbers : .letters
        rebuildKeyboardIfNeeded(animated: false)
    }

    private func onPunctuation() {
        if method == .mspy, !english, page == .letters { send(.feed(";")); return }
        send(.literal(english ? "," : "，"))
    }

    private func commitPending() {
        send(.literal(""))
    }

    private func onLetter(_ ch: Character) {
        if english || shifted {
            send(.literal(shifted ? String(ch).uppercased() : String(ch)))
            if shifted && !capsLocked { shifted = false; rebuildKeyboardIfNeeded(animated: false) }
            return
        }
        rawInput += String(ch)
        composingLabel?.text = rawInput
        send(.feed(String(ch)))
    }

    private func onBackspace() {
        if method == .handwriting, !english, !rawInput.isEmpty { handwritingPanel?.undo(); return }
        if !rawInput.isEmpty { rawInput.removeLast(); composingLabel?.text = rawInput }
        send(.backspace)
    }

    private func onSpace() {
        send(.space)
    }

    private func onEnter() {
        send(.enter)
    }

    private func onModeToggle() {
        english.toggle()
        applyMode()
    }

    private func onTraditionalToggle() {
        traditional.toggle()
        tradButton?.setTitle(traditional ? "繁" : "简", for: .normal)
        send(.traditional(traditional))
    }

    private func applyMode() {
        send(.mode(currentMode()))
        modeButton?.setTitle(english ? "EN" : "中", for: .normal)
        primaryLanguage = english ? "en-US" : "zh-Hans"
        layoutSignature = ""
        rebuildKeyboardIfNeeded(animated: false)
    }

    private func currentMode() -> String { english ? "en" : method.rawValue }

    /// 视图重建后把状态重新贴回按钮（按钮是新建的，默认显示"中/简"）。
    private func syncModeLabels() {
        modeButton?.setTitle(english ? "EN" : "中", for: .normal)
        tradButton?.setTitle(traditional ? "繁" : "简", for: .normal)
        configureModeMenu()
    }

    private func selectCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        send(.select(index, raw: candidateRaw, text: candidates[index]))
        // 上屏加强触觉：形成"上屏了"的身体确认（§3.1）
        hapticStrong.impactOccurred()
        // 引擎可能仍留剩余缓冲，候选要立刻跟着变（L2 而不是等下一次按键）
    }

    private func commitRaw() {
        commitPending()
    }

    private func insertText(_ text: String) {
        send(.literal(text))
    }

    // MARK: - 候选刷新（状态 → 渲染，两处入口共用）

    private func renderCandidates() {
        renderWorkbench()
        guard candidateStrip != nil else { return }
        composingLabel?.text = composingText.isEmpty ? (english ? "松萝 · English" : "松萝 · " + method.title) : composingText
        clearButton?.isHidden = rawInput.isEmpty
        for button in returnButtons { button.accessibilityLabel = rawInput.isEmpty ? "换行" : "确认候选" }
        guard renderedCandidates != candidates || renderedCandidateFont != preferences.candidateFont else { return }
        renderedCandidates = candidates; renderedCandidateFont = preferences.candidateFont
        while candidateButtons.count < candidates.count {
            let button = candidateButton("", index: candidateButtons.count)
            candidateButtons.append(button); candidateStrip.addArrangedSubview(button)
        }
        for (i, button) in candidateButtons.enumerated() {
            button.isHidden = i >= candidates.count
            if i < candidates.count {
                UIView.performWithoutAnimation { button.setTitle(candidates[i], for: .normal) }
                button.titleLabel?.font = .systemFont(ofSize: CGFloat(preferences.candidateFont), weight: .bold)
            }
        }
    }

    /// 候选条目：点击选中；上滑 ≥ 24pt 直接着该候选上屏（§3.2）。
    private func candidateButton(_ text: String, index: Int) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.setTitleColor(LianaTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: CGFloat(preferences.candidateFont), weight: .bold)
        b.backgroundColor = LianaTheme.keyPressed
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.tag = index
        b.accessibilityIdentifier = "candidate.\(index)"
        b.addAction(UIAction { [weak self] _ in self?.selectCandidate(index) }, for: .touchUpInside)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(onCandidateSwipeUp(_:)))
        swipeUp.direction = .up
        swipeUp.delaysTouchesEnded = false
        b.addGestureRecognizer(swipeUp)
        return b
    }

    @objc private func onCandidateSwipeUp(_ g: UISwipeGestureRecognizer) {
        guard let b = g.view as? UIButton, candidates.indices.contains(b.tag) else { return }
        hapticStrong.impactOccurred()
        selectCandidate(b.tag)
    }
}


extension KeyboardViewController {
    private func configureModeMenu() {
        modeButton?.menu = UIMenu(title: "输入方案（点按切换中英）", children: MobileInputMethod.allCases.map { item in
            UIAction(title: item.title, state: method == item && !english ? .on : .off) { [weak self] _ in self?.chooseMethod(item) }
        } + [UIAction(title: "输入工具 · 词库／语音／表情／同步") { [weak self] _ in self?.toggleTools() }])
    }
    private func chooseMethod(_ item: MobileInputMethod) {
        method = item; english = false; page = .letters
        UserDefaults.standard.set(item.rawValue, forKey: "keyboard.method")
        featurePanel?.removeFromSuperview(); featurePanel = nil
        applyMode()
    }
    private func pinKeyboard(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        keyboardArea.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: keyboardArea.leadingAnchor, constant: 5),content.trailingAnchor.constraint(equalTo: keyboardArea.trailingAnchor, constant: -5),content.topAnchor.constraint(equalTo: keyboardArea.topAnchor),content.bottomAnchor.constraint(equalTo: keyboardArea.bottomAnchor)])
    }
    private func basicFunctions() -> UIStackView {
        let row = UIStackView(); row.spacing = 5; row.distribution = .fillEqually
        for (text, action): (String, () -> Void) in [("123",{ [weak self] in self?.togglePage() }),("🌐",{}),("中",{ [weak self] in self?.onModeToggle() }),("空格",{ [weak self] in self?.onSpace() }),("⏎",{ [weak self] in self?.onEnter() })] {
            let key = keyButton(text, action: action); row.addArrangedSubview(key); if text == "中" { modeButton = key }
        }
        configureModeMenu(); return row
    }
    private func assembleNineKey(_ layout: FoldLayout) {
        resetKeyboardArea()
        let column = UIStackView(); column.axis = .vertical; column.spacing = 5; column.distribution = .fillEqually
        let values = [["1 · 符号", "2 ABC", "3 DEF"],["4 GHI", "5 JKL", "6 MNO"],["7 PQRS", "8 TUV", "9 WXYZ"]]
        for titles in values {
            let row = UIStackView(); row.spacing = 5; row.distribution = .fillEqually
            for title in titles { row.addArrangedSubview(keyButton(title) { [weak self] in
                guard let self else { return }
                if title.hasPrefix("1") { self.insertText("，") } else { self.send(.feed(String(title.prefix(1)))) }
            }) }
            let back = keyButton(titles[0].hasPrefix("1") ? "⌫" : (titles[0].hasPrefix("4") ? "清空" : "工具")) { [weak self] in
                if titles[0].hasPrefix("1") { self?.onBackspace() } else if titles[0].hasPrefix("4") { self?.send(.clear) } else { self?.toggleTools() }
            }; row.addArrangedSubview(back); column.addArrangedSubview(row)
        }
        column.addArrangedSubview(basicFunctions()); pinKeyboard(column)
    }
    private func assembleHandwriting() {
        resetKeyboardArea()
        let column = UIStackView(); column.axis = .vertical; column.spacing = 5
        let canvas = HandwritingPanel(); handwritingPanel = canvas
        canvas.accessibilityLabel = "手写区域"; canvas.onStrokes = { [weak self] in self?.send(.handwriting($0)) }
        column.addArrangedSubview(canvas)
        let row = UIStackView(); row.spacing = 5; row.distribution = .fillEqually
        row.addArrangedSubview(keyButton("撤销一笔") { [weak canvas] in canvas?.undo() })
        row.addArrangedSubview(keyButton("清空") { [weak self, weak canvas] in canvas?.clear(); self?.send(.clear) })
        row.addArrangedSubview(keyButton("⌫") { [weak self] in self?.onBackspace() })
        row.addArrangedSubview(keyButton("工具") { [weak self] in self?.toggleTools() })
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true; column.addArrangedSubview(row)
        let functions = basicFunctions(); functions.heightAnchor.constraint(equalToConstant: CGFloat(preferences.keyHeight)).isActive = true; column.addArrangedSubview(functions); pinKeyboard(column)
    }
    @objc private func onGlide(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: keyboardArea)
        switch gesture.state {
        case .began: glidePoints = [gesture.location(in: keyboardArea) - gesture.translation(in: keyboardArea),point]
        case .changed: glidePoints.append(point)
        case .ended:
            glidePoints.append(point)
            var centers: [String: CGPoint] = [:]
            func collect(_ view: UIView) {
                if let key = view as? UIButton, let title = key.title(for: .normal)?.lowercased(), title.count == 1, title.first!.isASCII, title.first!.isLetter { centers[title] = key.convert(CGPoint(x:key.bounds.midX,y:key.bounds.midY),to:keyboardArea) }
                view.subviews.forEach(collect)
            }
            collect(keyboardArea); send(.glide(glidePoints, centers, english))
        default: glidePoints = []
        }
    }
    private func toggleTools() {
        if let panel = featurePanel { panel.removeFromSuperview(); featurePanel = nil; return }
        adjustmentPanel?.removeFromSuperview(); adjustmentPanel = nil
        devicePanel?.stop(); devicePanel?.removeFromSuperview(); devicePanel = nil
        let panel = KeyboardToolsPanel(); featurePanel = panel; installPanel(panel)
        panel.onClose = { [weak self] in self?.toggleTools() }
        panel.onMethod = { [weak self] in self?.chooseMethod($0) }
        panel.onInsert = { [weak self] in self?.insertText($0) }
        panel.onReceive = { [weak self] in self?.receiveHostContent() }
        panel.onSystemLexicon = { [weak self] in self?.importSystemLexicon() }
        panel.onClipboardSend = { [weak self] in self?.clipboardToMac(pull: false) }
        panel.onClipboardReceive = { [weak self] in self?.clipboardToMac(pull: true) }
    }
    private func receiveHostContent() {
        guard hasFullAccess else { featurePanel?.status("请先在系统键盘设置中允许完全访问，才能接收剪贴板内容。"); return }
        do {
            guard let payload = try KeyboardPayload.read() else { featurePanel?.status("请先打开主 App，复制文字／词库／GIF 或 Mac 配对内容，再回到这里接收。"); return }
            switch payload.kind {
            case "words": send(.importWords(payload.words ?? [])); featurePanel?.status("正在导入本地词库…")
            case "text": insertText(payload.text ?? ""); featurePanel?.status("已插入文字。")
            case "gif": try KeyboardToolsPanel.saveGIF(payload.gif ?? Data()); toggleTools(); toggleTools(); featurePanel?.status("GIF 已导入，点缩略图复制后粘贴。")
            case "pairing":
                let profile = try PetLink.Profile.parse(payload.text ?? "")
                try PetLink.store(profile, account: "keyboard.mac")
                featurePanel?.status("Mac 配对已保存在键盘钥匙串，可发送／接收剪贴板。")
            default: throw MobileImportError.message("不支持的内容类型。")
            }
        } catch { featurePanel?.status(error.localizedDescription) }
    }
    private func clipboardToMac(pull: Bool) {
        guard hasFullAccess else { featurePanel?.status("同步剪贴板需要允许键盘完全访问。"); return }
        guard let profile = PetLink.load(account: "keyboard.mac") else { featurePanel?.status("先在主 App「移动输入工具」复制 Mac 配对，再在这里接收 App 内容。"); return }
        let text: String?
        if pull { text = nil } else {
            guard let value = UIPasteboard.general.string else { featurePanel?.status("当前剪贴板没有文字。"); return }; text = value
        }
        clipboardSender?.disconnect()
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "PetLink.keyboardID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: "PetLink.keyboardID")
        let sender = PetLinkSender(deviceID: id, deviceName: "松萝 iOS 键盘")
        clipboardSender = sender
        sender.onStatus = { [weak self] in self?.featurePanel?.status($0) }
        sender.onReady = { [weak sender] in sender?.clipboard(text: text) }
        sender.onClipboard = { [weak self, weak sender] value in
            if let value { UIPasteboard.general.string = value; self?.featurePanel?.status("Mac 文字已复制到 iPhone 剪贴板，请粘贴。") }
            sender?.disconnect(silent: true); self?.clipboardSender = nil
        }
        sender.onFailure = { [weak self, weak sender] in sender?.disconnect(silent: true); self?.clipboardSender = nil }
        sender.connect(profile: profile)
    }
    private func importSystemLexicon() {
        featurePanel?.status("正在读取系统公开的补充词库…")
        requestSupplementaryLexicon { [weak self] lexicon in
            DispatchQueue.global(qos: .userInitiated).async {
                let words = lexicon.entries.prefix(20000).compactMap { entry -> MobileWord? in
                    let code = entry.userInput.allSatisfy({ $0.isASCII && $0.isLetter }) && !entry.userInput.isEmpty ? entry.userInput : MobileDictionaryImport.reading(entry.documentText)
                    return code.isEmpty ? nil : MobileWord(word:entry.documentText,code:code,kind:"pinyin",reading:MobileDictionaryImport.reading(entry.documentText))
                }
                DispatchQueue.main.async { self?.send(.importWords(words)); self?.featurePanel?.status("已提交 \(words.count) 条补充词条（联系人、文本替换等）；iOS 不开放完整系统词库。") }
            }
        }
    }
}

private final class GlidePan: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    var allow: ((CGPoint) -> Bool)?
    override init(target: Any?, action: Selector?) { super.init(target: target, action: action); delegate = self; maximumNumberOfTouches = 1 }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { allow?(touch.location(in: view)) ?? false }
}
private func - (left: CGPoint, right: CGPoint) -> CGPoint { CGPoint(x:left.x-right.x,y:left.y-right.y) }
