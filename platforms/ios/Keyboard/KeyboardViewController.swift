import UIKit

/// 全平台统一设计 Token（docs/design/UNIFIED-DESIGN.md 为单一事实源）。
enum LianaTheme {
    static let bg = UIColor(red: 0x1C/255, green: 0x1C/255, blue: 0x22/255, alpha: 1)
    static let key = UIColor(red: 0x2A/255, green: 0x2A/255, blue: 0x33/255, alpha: 1)
    static let keyPressed = UIColor(red: 0x33/255, green: 0x33/255, blue: 0x3E/255, alpha: 1)
    static let text = UIColor(red: 0xE8/255, green: 0xE8/255, blue: 0xEC/255, alpha: 1)
    static let secondary = UIColor(red: 0x9A/255, green: 0x9A/255, blue: 0xA5/255, alpha: 1)
    static let accent = UIColor(red: 0x33/255, green: 0x7B/255, blue: 0xFF/255, alpha: 1)
    static let fontCandidate: CGFloat = 17
    static let fontKey: CGFloat = 16
    static let padSplitMinWidth: CGFloat = 600
}

/// 松萝 iOS 键盘扩展。
///
/// 与 macOS 端同构：Swift 只做 UI 与协议翻译，引擎逻辑全部来自
/// 静态链接的 Rust 内核（libliana_ffi.a，经 bridge.h 直调 liana.h）。
/// 内存红线：扩展进程上限约 60MB，词典按需加载、候选即时释放。
///
/// 触控创新（统一设计语言 §3）：
/// - 全键触觉反馈（§3.1）
/// - 候选上滑直上屏（§3.2）
/// - 退格长按连删（§3.3）
/// - 折叠屏几何守恒 + 中缝工作台（FOLDABLE-ADAPTATION.md §4 §5）
final class KeyboardViewController: UIInputViewController {

    // MARK: - 输入状态（与视图生命周期解耦：视图重建不得丢失）

    private var session: OpaquePointer?
    private var modeIdx = 0
    private var candidates: [String] = []
    private var rawInput = ""
    private var composingText = ""

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
    private static let stripHeight: CGFloat = 40
    private static let cursorRowHeight: CGFloat = 34
    private static let wbCandidateRowHeight: CGFloat = 52
    private static let keyboardAreaHeight: CGFloat =
        4 * FoldLayout.keyHeightConst + 3 * rowSpacing

    /// 当前几何签名；空串表示尚未构建。
    private var layoutSignature = ""
    private var isAssembling = false

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        loadEngine()
        buildUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        saveUserWords()
        stopRepeat()
        super.viewWillDisappear(animated)
    }

    private func loadEngine() {
        let dictURL = Bundle.main.url(forResource: "base", withExtension: "ifd")
        if let path = dictURL?.path {
            session = liana_new_with_dict("pinyin", path)
        }
        if session == nil {
            session = liana_new("pinyin")
        }
        // 用户词：App Group 共享容器（无权限时退化为内存态学习）
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

    /// 键盘扩展没有自己的容器写权限（未开 Full Access 时），退化到内存缓存
    private func readUserWords() -> String? {
        guard let shared = UserDefaults(suiteName: "dev.liana.ime.ios") else { return nil }
        return shared.string(forKey: "user_dict_tsv")
    }

    private func writeUserWords(_ tsv: String) {
        UserDefaults(suiteName: "dev.liana.ime.ios")?.set(tsv, forKey: "user_dict_tsv")
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
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 候选栏（横向滚动）
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: Self.stripHeight).isActive = true
        candidateStrip = UIStackView()
        candidateStrip.axis = .horizontal
        candidateStrip.spacing = 6
        candidateStrip.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        candidateStrip.isLayoutMarginsRelativeArrangement = true
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
        area.heightAnchor.constraint(equalToConstant: Self.keyboardAreaHeight).isActive = true
        keyboardArea = area
        root.addArrangedSubview(area)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        rebuildKeyboardIfNeeded(animated: !layoutSignature.isEmpty)
    }

    /// L1 连续性：只有几何签名变化才重建，且重建只换视图、不动输入状态。
    private func rebuildKeyboardIfNeeded(animated: Bool) {
        guard !isAssembling else { return }
        let width = view.bounds.width
        guard width > 0 else { return }

        let layout = FoldLayout.derive(
            width: width,
            regularWidth: traitCollection.horizontalSizeClass == .regular,
            rememberedSoloPitch: FoldLayoutMemory.rememberedSoloPitch
        )
        guard layout.signature != layoutSignature else { return }

        let isFirstBuild = layoutSignature.isEmpty
        layoutSignature = layout.signature
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
        if animated && !isFirstBuild {
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
    }

    // MARK: - 布局 A：单块（外屏 / 手机）

    private func assembleSolo(_ layout: FoldLayout) {
        resetKeyboardArea()

        let avail = view.bounds.width - 2 * layout.margin
        let gap = layout.gap
        let p = layout.pitch
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Self.rowSpacing
        column.alignment = .center
        column.translatesAutoresizingMaskIntoConstraints = false
        keyboardArea.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: keyboardArea.centerXAnchor),
            column.topAnchor.constraint(equalTo: keyboardArea.topAnchor),
            column.bottomAnchor.constraint(equalTo: keyboardArea.bottomAnchor),
        ])

        for (i, keys) in rows.enumerated() {
            var items: [(String, CGFloat, () -> Void)] = []
            for ch in keys {
                items.append((String(ch), p, { [weak self] in self?.onLetter(ch) }))
            }
            if i == 2 {
                // 退格吃掉底行剩余宽度：既保持字母键距，又不留空档
                let used = CGFloat(keys.count) * p + CGFloat(keys.count) * gap
                items.append(("⌫", max(p, avail - used), { [weak self] in self?.onBackspace() }))
            }
            let row = letterRow(items, height: layout.keyHeight)
            if i == 2 { attachBackspace(in: row) }
            column.addArrangedSubview(row)
        }

        // 功能行（外屏通栏，拇指公共区）
        column.addArrangedSubview(soloFunctionRow(layout, avail: avail))
    }

    private func soloFunctionRow(_ layout: FoldLayout, avail: CGFloat) -> UIStackView {
        let gap = layout.gap
        let fnWidth = max(48, layout.pitch)
        let spaceWidth = max(72, avail - 5 * fnWidth - 5 * gap)

        let items: [(String, CGFloat, () -> Void)] = [
            ("中", fnWidth, { [weak self] in self?.onModeToggle() }),
            ("简", fnWidth, { [weak self] in self?.onTraditionalToggle() }),
            (",", fnWidth, { [weak self] in self?.insertText(",") }),
            ("空格", spaceWidth, { [weak self] in self?.onSpace() }),
            (".", fnWidth, { [weak self] in self?.insertText(".") }),
            ("⏎", fnWidth, { [weak self] in self?.onEnter() }),
        ]
        let row = letterRow(items, height: layout.keyHeight)
        // letterRow 内部按顺序生成按钮；这里把引用接回可更新的两个标题键
        if row.arrangedSubviews.count == 6 {
            modeButton = row.arrangedSubviews[0] as? UIButton
            tradButton = row.arrangedSubviews[1] as? UIButton
        }
        return row
    }

    // MARK: - 布局 B：左右分体 + 中缝工作台（内屏 / Pad）

    private func assembleSplit(_ layout: FoldLayout) {
        resetKeyboardArea()

        let gap = layout.gap
        let p = layout.pitch
        let cw = layout.clusterWidth
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        // 与既有实现一致的双手分配：10→5/5、9→5/4、7→4/3
        let mids = [5, 5, 4]

        var leftRows: [UIStackView] = []
        var rightRows: [UIStackView] = []

        for (i, keys) in rows.enumerated() {
            let mid = mids[i]
            let leftKeys = keys.prefix(mid).map(String.init)
            let rightKeys = keys.dropFirst(mid).map(String.init)

            leftRows.append(clusterLetterRow(leftKeys, layout: layout, backspace: i == 2))
            rightRows.append(clusterLetterRow(rightKeys, layout: layout, backspace: i == 2))
        }

        // 功能行：中/简/，/空格 贴内侧，. / ⏎ 靠外侧；空格两侧各一颗（拇指互不越界）
        let fnWidth = max(48, p)
        let leftSpace = max(64, cw - 3 * fnWidth - 3 * gap)
        let leftFnItems: [(String, CGFloat, () -> Void)] = [
            ("中", fnWidth, { [weak self] in self?.onModeToggle() }),
            ("简", fnWidth, { [weak self] in self?.onTraditionalToggle() }),
            (",", fnWidth, { [weak self] in self?.insertText(",") }),
            ("空格", leftSpace, { [weak self] in self?.onSpace() }),
        ]
        let rightSpace = max(64, cw - 2 * fnWidth - 2 * gap)
        let rightFnItems: [(String, CGFloat, () -> Void)] = [
            ("空格", rightSpace, { [weak self] in self?.onSpace() }),
            (".", fnWidth, { [weak self] in self?.insertText(".") }),
            ("⏎", fnWidth, { [weak self] in self?.onEnter() }),
        ]

        let leftFn = letterRow(leftFnItems, height: layout.keyHeight)
        let rightFn = letterRow(rightFnItems, height: layout.keyHeight)
        modeButton = leftFn.arrangedSubviews.first as? UIButton
        tradButton = leftFn.arrangedSubviews.count > 1 ? leftFn.arrangedSubviews[1] as? UIButton : nil

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
    private func clusterLetterRow(_ titles: [String], layout: FoldLayout, backspace: Bool) -> UIStackView {
        var items: [(String, CGFloat, () -> Void)] = []
        for t in titles {
            guard let ch = t.first else { continue }
            items.append((t, layout.pitch, { [weak self] in self?.onLetter(ch) }))
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
        b.titleLabel?.font = .systemFont(ofSize: LianaTheme.fontCandidate, weight: .bold)
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
        keyboardArea.subviews.forEach { $0.removeFromSuperview() }
        backspaceButtons.removeAll()
        wbComposing = nil
        wbGrid = nil
        wbCursor = nil
    }

    // MARK: - 视图工厂

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
        b.addAction(UIAction { [weak self] _ in
            self?.hapticLight.impactOccurred()
            action()
        }, for: .touchUpInside)
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

    private func onLetter(_ ch: Character) {
        guard let session else { return }
        if currentMode() == "en" {
            insertText(String(ch))
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
        if !rawInput.isEmpty {
            commitRaw()
        } else {
            textDocumentProxy.insertText("\n")
        }
    }

    private func onModeToggle() {
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
        refreshCandidates()
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
                composingText = preedit.isEmpty ? raw : "\(raw) › \(preedit)"
                let arr = obj["candidates"] as? [[String: Any]] ?? []
                candidates = arr.prefix(9).compactMap { $0["text"] as? String }
            }
        }
        renderCandidates()
    }

    private func renderCandidates() {
        guard candidateStrip != nil else { return }
        candidateStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !composingText.isEmpty {
            let composing = UILabel()
            composing.text = composingText
            composing.font = .systemFont(ofSize: 13)
            composing.textColor = LianaTheme.secondary
            candidateStrip.addArrangedSubview(composing)
        }
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
        b.titleLabel?.font = .systemFont(ofSize: LianaTheme.fontCandidate, weight: .bold)
        b.backgroundColor = LianaTheme.keyPressed
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.addAction(UIAction { [weak self] _ in self?.selectCandidate(index) }, for: .touchUpInside)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(onCandidateSwipeUp(_:)))
        swipeUp.direction = .up
        b.addGestureRecognizer(swipeUp)
        return b
    }

    @objc private func onCandidateSwipeUp(_ g: UISwipeGestureRecognizer) {
        guard let b = g.view as? UIButton,
              let idx = candidateStrip.arrangedSubviews.firstIndex(of: b),
              idx > 0, idx - 1 < candidates.count else { return }
        // arrangedSubviews[0] 只在有组合串时是提示标签
        hapticStrong.impactOccurred()
        selectCandidate(idx - 1)
    }
}
