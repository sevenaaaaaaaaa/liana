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
/// 与 macOS 端同构：Swift 只做 UI 与协议翻译，引擎逻辑全部来自
/// 静态链接的 Rust 内核（libliana_ffi.a，经 bridge.h 直调 liana.h）。
/// 键盘扩展使用紧凑词库；内存预算随设备和系统而变。
///
/// 触控创新（统一设计语言 §3）：
/// - 全键触觉反馈（§3.1）
/// - 候选上滑直上屏（§3.2）
/// - 退格长按连删（§3.3）
/// - 折叠屏几何守恒 + 中缝工作台（FOLDABLE-ADAPTATION.md §4 §5）
class KeyboardViewController: UIInputViewController {

    // MARK: - 输入状态（与视图生命周期解耦：视图重建不得丢失）

    private var session: OpaquePointer?
    private var modeIdx = 0
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

    private static let modes = ["pinyin", "en"]
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

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAppearance()
        loadEngine()
        primaryLanguage = "zh-Hans"
        buildUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        saveWork?.cancel()
        saveUserWords()
        preferences.save()
        devicePanel?.stop()
        devicePanel?.removeFromSuperview()
        devicePanel = nil
        stopRepeat()
        if let session { liana_clear(session) }
        refreshCandidates()
        super.viewWillDisappear(animated)
    }

    deinit {
        repeatTimer?.invalidate()
        saveWork?.cancel()
        geometrySave?.cancel()
        if let session { liana_free(session) }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        let id = textDocumentProxy.documentIdentifier
        if let previous = documentID, previous != id, let session {
            liana_clear(session)
            devicePanel?.stop()
            refreshCandidates()
        }
        documentID = id
    }

    private func loadEngine() {
        let dictURL = Bundle(for: KeyboardViewController.self).url(forResource: "base", withExtension: "ifd")
        if let path = dictURL?.path {
            session = liana_new_with_dict("pinyin", path)
        }
        if session == nil {
            session = liana_new("pinyin")
        }
        // 用户词保存在键盘自身的沙盒，无需共享容器或完全访问。
        if let tsv = readUserWords() {
            liana_user_import(session, tsv)
        }
    }

    private func saveUserWords() {
        guard let session, let tsv = liana_user_export(session) else { return }
        let tsvString = String(cString: tsv)
        liana_free_string(tsv)
        writeUserWords(tsvString)
    }

    private func readUserWords() -> String? { UserDefaults.standard.string(forKey: "user_dict_tsv") }

    private func writeUserWords(_ tsv: String) {
        UserDefaults.standard.set(tsv, forKey: "user_dict_tsv")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveUserWords() }
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
        rootBottom = root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -CGFloat(preferences.bottomPadding))
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
        NSLayoutConstraint.activate([entryLeading, entryDock.widthAnchor.constraint(equalToConstant: 176), entryDock.heightAnchor.constraint(equalToConstant: 44), entryDock.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        let grip = toolbarButton("arrow.up.and.down.and.arrow.left.and.right", label: "拖动调高度与入口位置", id: "layout.drag")
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragLayout(_:))))
        grip.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "增高键盘", target: self, selector: #selector(increaseHeight)),
            UIAccessibilityCustomAction(name: "降低键盘", target: self, selector: #selector(decreaseHeight)),
        ]
        entryDock.addArrangedSubview(grip)
        let settings = toolbarButton("slider.horizontal.3", label: "调整键盘比例", id: "layout.settings")
        settings.addAction(UIAction { [weak self] _ in self?.toggleAdjustments() }, for: .touchUpInside)
        entryDock.addArrangedSubview(settings)
        let devices = toolbarButton("waveform", label: "连接语音与编码设备", id: "devices.open")
        devices.addAction(UIAction { [weak self] _ in self?.toggleDevices() }, for: .touchUpInside)
        entryDock.addArrangedSubview(devices)
        clearButton = UIButton(type: .system)
        clearButton.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
        clearButton.accessibilityIdentifier = "composition.clear"
        clearButton.accessibilityLabel = "取消当前拼音"
        clearButton.addAction(UIAction { [weak self] _ in
            guard let self, let session = self.session else { return }
            liana_clear(session)
            self.refreshCandidates()
        }, for: .touchUpInside)
        entryDock.addArrangedSubview(clearButton)
        tradButton = UIButton(type: .system)
        tradButton.setTitle("简", for: .normal)
        tradButton.accessibilityLabel = "切换简繁体"
        tradButton.addAction(UIAction { [weak self] _ in self?.onTraditionalToggle() }, for: .touchUpInside)
        root.addArrangedSubview(header)
        heightConstraint = view.heightAnchor.constraint(equalToConstant: Self.headerHeight + Self.stripHeight + keyboardAreaHeight + CGFloat(preferences.bottomPadding))
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
        let signature = layout.signature + "-\(width)-\(preferences.alignment)-\(page)-\(shifted)-\(capsLocked)"
        guard signature != layoutSignature else { return }

        let isFirstBuild = layoutSignature.isEmpty
        layoutSignature = signature
        if layout.mode == .solo {
            FoldLayoutMemory.rememberSolo(pitch: layout.pitch, width: width)
        }

        isAssembling = true
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            switch layout.mode {
            case .solo: self.assembleSolo(layout)
            case .split: self.assembleSplit(layout)
            }
            self.keyboardArea.layoutIfNeeded()
        }
        if animated && !isFirstBuild && !isAdjusting && !UIAccessibility.isReduceMotionEnabled {
            // 折叠/展开瞬间不做逐键 morph（v1.1），用交叉淡入消除闪断（D5）
            UIView.transition(with: keyboardArea,
                              duration: 0.22,
                              options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: apply,
                              completion: nil)
        } else {
            apply()
        }
        isAssembling = false

        // 重建后：中/简/EN 标题、候选都必须原地恢复（L2）
        syncModeLabels()
        renderCandidates()
        if let adjustmentPanel { keyboardArea.bringSubviewToFront(adjustmentPanel) }
        if let devicePanel { keyboardArea.bringSubviewToFront(devicePanel) }
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
            (currentMode() == "pinyin" ? "，" : ",", fnWidth, { [weak self] in self?.onPunctuation() }),
            ("⏎", fnWidth, { [weak self] in self?.onEnter() }),
        ]
        let row = letterRow(items, height: layout.keyHeight)
        modeButton = row.arrangedSubviews[2] as? UIButton
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
            (".", fnWidth, { [weak self] in self?.commitPending(); self?.insertText(".") }),
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
        keyboardArea.subviews.filter { $0 !== adjustmentPanel && $0 !== devicePanel }.forEach { $0.removeFromSuperview() }
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
        heightConstraint?.constant = Self.headerHeight + Self.stripHeight + keyboardAreaHeight + view.safeAreaInsets.bottom + CGFloat(preferences.bottomPadding)
        areaHeight?.constant = keyboardAreaHeight
        rootBottom?.constant = -CGFloat(preferences.bottomPadding)
        guard entryDock != nil else { return }
        let travel = max(0, view.bounds.width - 176 - 8)
        let x = 4 + travel * CGFloat(preferences.entryPosition)
        entryLeading.constant = x
        let leftSpace = x - 12
        let rightSpace = view.bounds.width - x - 176 - 12
        compositionLeading.constant = leftSpace >= rightSpace ? 8 : x + 184
        compositionWidth.constant = max(0, max(leftSpace, rightSpace))
        if let adjustmentPanel { keyboardArea.bringSubviewToFront(adjustmentPanel) }
        if let devicePanel { keyboardArea.bringSubviewToFront(devicePanel) }
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
            guard let self, let session = self.session else { return }
            if !self.rawInput.isEmpty {
                liana_backspace(session)
                self.refreshCandidates()
            } else {
                self.textDocumentProxy.deleteBackward()
            }
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
        commitPending()
        insertText(currentMode() == "pinyin" ? "，" : ",")
    }

    private func commitPending() {
        var attempts = 0
        while !rawInput.isEmpty && attempts < 64 {
            let before = rawInput
            if candidates.isEmpty { commitRaw() } else { selectCandidate(0) }
            attempts += 1
            if before == rawInput { commitRaw(); break }
        }
    }

    private func onLetter(_ ch: Character) {
        guard let session else { return }
        if currentMode() == "en" || shifted {
            commitPending()
            insertText(shifted ? String(ch).uppercased() : String(ch))
            if shifted && !capsLocked { shifted = false; rebuildKeyboardIfNeeded(animated: false) }
            return
        }
        if liana_feed(session, String(ch)) == 1 {
            refreshCandidates()
        }
    }

    private func onBackspace() {
        guard let session else { return }
        if !rawInput.isEmpty {
            liana_backspace(session)
            refreshCandidates()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func onSpace() {
        if !candidates.isEmpty {
            selectCandidate(0)
        } else {
            insertText(" ")
        }
    }

    private func onEnter() {
        if !rawInput.isEmpty { commitPending() }
        else { insertText("\n") }
    }

    private func onModeToggle() {
        commitPending()
        modeIdx = (modeIdx + 1) % Self.modes.count
        applyMode()
    }

    private func onTraditionalToggle() {
        guard let session else { return }
        let on = liana_traditional(session) == 0
        liana_set_traditional(session, on ? 1 : 0)
        tradButton?.setTitle(on ? "繁" : "简", for: .normal)
        refreshCandidates()
    }

    private func applyMode() {
        guard let session else { return }
        let mode = Self.modes[modeIdx]
        liana_set_mode(session, mode)
        liana_clear(session)
        modeButton?.setTitle(mode == "pinyin" ? "中" : "EN", for: .normal)
        primaryLanguage = mode == "pinyin" ? "zh-Hans" : "en-US"
        refreshCandidates()
        layoutSignature = ""
        rebuildKeyboardIfNeeded(animated: false)
    }

    private func currentMode() -> String { Self.modes[modeIdx] }

    /// 视图重建后把状态重新贴回按钮（按钮是新建的，默认显示"中/简"）。
    private func syncModeLabels() {
        modeButton?.setTitle(currentMode() == "pinyin" ? "中" : "EN", for: .normal)
        guard let session else { return }
        tradButton?.setTitle(liana_traditional(session) == 1 ? "繁" : "简", for: .normal)
    }

    private func selectCandidate(_ index: Int) {
        guard let session, let p = liana_select(session, UInt32(index)) else { return }
        let text = String(cString: p)
        liana_free_string(p)
        insertText(text)
        scheduleSave()
        // 上屏加强触觉：形成"上屏了"的身体确认（§3.1）
        hapticStrong.impactOccurred()
        // 引擎可能仍留剩余缓冲，候选要立刻跟着变（L2 而不是等下一次按键）
        refreshCandidates()
    }

    private func commitRaw() {
        guard let session, let p = liana_commit_raw(session) else { return }
        let text = String(cString: p)
        liana_free_string(p)
        insertText(text)
        hapticStrong.impactOccurred()
        refreshCandidates()
    }

    private func insertText(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    // MARK: - 候选刷新（状态 → 渲染，两处入口共用）

    private func refreshCandidates() {
        candidates = []
        rawInput = ""
        composingText = ""

        if let session, let p = liana_composition_json(session) {
            let jsonString = String(cString: p)
            liana_free_string(p)
            if let data = jsonString.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = obj["raw"] as? String, !raw.isEmpty {
                rawInput = raw
                let preedit = obj["preedit"] as? String ?? ""
                composingText = preedit.isEmpty ? raw : preedit
                let arr = obj["candidates"] as? [[String: Any]] ?? []
                candidates = arr.prefix(9).compactMap { $0["text"] as? String }
            }
        }
        renderCandidates()
    }

    private func renderCandidates() {
        guard candidateStrip != nil else { return }
        candidateStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        composingLabel?.text = composingText.isEmpty ? (currentMode() == "pinyin" ? "松萝 · 拼音" : "松萝 · English") : composingText
        clearButton?.isHidden = rawInput.isEmpty
        for button in returnButtons { button.accessibilityLabel = rawInput.isEmpty ? "换行" : "确认候选" }
        for (i, text) in candidates.enumerated() {
            candidateStrip.addArrangedSubview(candidateButton(text, index: i))
        }
        renderWorkbench()
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
        b.addGestureRecognizer(swipeUp)
        return b
    }

    @objc private func onCandidateSwipeUp(_ g: UISwipeGestureRecognizer) {
        guard let b = g.view as? UIButton, candidates.indices.contains(b.tag) else { return }
        hapticStrong.impactOccurred()
        selectCandidate(b.tag)
    }
}
