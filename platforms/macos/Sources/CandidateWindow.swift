import AppKit
import QuartzCore

/// 候选窗：无激活面板 + Liquid Glass 背景（macOS 26+），旧系统回退 NSVisualEffectView。
/// 支持皮肤包（ThemeStore）：颜色/圆角/字号来自激活皮肤，缺省回落系统语义色。
final class CandidateWindowController {
    static let pageSize = 9

    private let panel: NSPanel
    private var background: NSView
    private let row = NSStackView()
    private let pageLabel = NSTextField(labelWithString: "")
    /// 候选格复用池：每个按键都重建 9 个 NSTextField 太贵（~0.2-0.5ms），
    /// 同一页尺寸固定，格子只换内容不换视图。
    private var cellPool: [CandidateCell] = []
    private var poolSide: CandidateTheme.Side?
    private var onPick: ((Int) -> Void)?
    private var onContext: ((Int, NSPoint) -> Void)?
    private var theme: CandidateTheme
    private var themeObserver: NSObjectProtocol?

    private(set) var page = 0

    init() {
        let initialTheme = ThemeStore.activeTheme()
        theme = initialTheme
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.autoresizingMask = [.width, .height]

        background = Self.makeBackground(initialTheme.current)
        applyBackground()
        panel.contentView = background

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadTheme()
        }
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    /// 切换皮肤时重建背景并让后续渲染走新主题。
    func reloadTheme() {
        theme = ThemeStore.activeTheme()
        cellPool.removeAll()
        poolSide = nil
        background = Self.makeBackground(theme.current)
        applyBackground()
        panel.contentView = background
    }

    private func applyBackground() {
        background.autoresizingMask = [.width, .height]
        let side = theme.current
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = row
            glass.tintColor = side.surface
        } else {
            background.addSubview(row)
            background.wantsLayer = true
            background.layer?.backgroundColor = side.surface?.cgColor ?? NSColor.clear.cgColor
        }
    }

    private static func makeBackground(_ side: CandidateTheme.Side) -> NSView {
        let radius = side.radius ?? 18
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            // 不默认染色：系统输入法同款素玻璃，皮肤包才覆盖 tint
            glass.tintColor = side.surface
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        if let surface = side.surface {
            effect.wantsLayer = true
            effect.layer?.backgroundColor = surface.cgColor
        }
        return effect
    }

    var isVisible: Bool { panel.isVisible }

    /// 开发用：把当前候选窗渲染成 PNG（离屏，不依赖屏幕录制权限）。
    func snapshot(to path: String) {
        panel.layoutIfNeeded()
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 更新内容并定位在光标下方；没有候选时自动隐藏。
    func present(candidates: [Candidate], page newPage: Int, near lineRect: NSRect?, onPick: @escaping (Int) -> Void, onContext: ((Int, NSPoint) -> Void)? = nil) {
        self.onPick = onPick
        self.onContext = onContext
        let total = candidates.count
        guard total > 0 else {
            hide()
            return
        }
        let pageCount = max(1, Int(ceil(Double(total) / Double(Self.pageSize))))
        page = min(max(0, newPage), pageCount - 1)
        let start = page * Self.pageSize
        let slice = Array(candidates[start..<min(start + Self.pageSize, total)])

        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let side = theme.current
        if poolSide != side {
            // 皮肤 / 明暗切换：颜色烘在 CandidateCell 的 init 里，整池重建
            cellPool.removeAll()
            poolSide = side
        }
        for (offset, candidate) in slice.enumerated() {
            let cell: CandidateCell
            if offset < cellPool.count {
                cell = cellPool[offset]
            } else {
                let created = CandidateCell(index: offset + 1, side: side)
                cellPool.append(created)
                cell = created
            }
            cell.configure(candidate, isFirst: offset == 0)
            cell.onClick = { [weak self] in
                self?.onPick?(start + offset)
            }
            if onContext != nil {
                let index = start + offset
                cell.onContext = { [weak self] point in
                    self?.onContext?(index, point)
                }
            }
            row.addArrangedSubview(cell)
        }

        if pageCount > 1 {
            pageLabel.stringValue = "\(page + 1)/\(pageCount)"
            pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            pageLabel.textColor = side.comment ?? .tertiaryLabelColor
            row.addArrangedSubview(pageLabel)
        }

        let size = row.fittingSize
        let maxWidth = (NSScreen.main?.visibleFrame.width ?? 1440) - 48
        panel.setContentSize(NSSize(width: min(max(80, size.width), maxWidth), height: max(36, size.height)))
        let wasVisible = panel.isVisible
        if let lineRect {
            position(near: lineRect)
        }
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            // 轻微弹入（0.97 → 1），Liquid Glass 的“出现感”
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.97
            spring.toValue = 1.0
            spring.damping = 18
            spring.stiffness = 240
            spring.duration = spring.settlingDuration
            panel.contentView?.layer?.add(spring, forKey: "pop")
        }
    }

    /// 开发用：打印每个候选格的 frame 与文本 intrinsic，定位截断。
    func dumpLayout(prefix: String) {
        panel.layoutIfNeeded()
        for (i, v) in row.arrangedSubviews.enumerated() {
            guard let cell = v as? CandidateCell else {
                print("\(prefix)[\(i)] other frame=\(v.frame)")
                continue
            }
            print(cell.diagLine(index: i, prefix: prefix))
        }
        print("\(prefix) panel=\(panel.frame.size) row=\(row.frame.size) fitting=\(row.fittingSize)")
    }

    func hide() {
        if panel.isVisible {
            panel.alphaValue = 0
            panel.orderOut(nil)
        }
    }

    /// 提示条（网址模式等）：复用候选窗的玻璃外观。
    func presentHint(_ text: String, near lineRect: NSRect?) {
        row.arrangedSubviews.forEach {
            row.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = theme.current.comment ?? .secondaryLabelColor
        row.addArrangedSubview(label)
        let size = row.fittingSize
        panel.setContentSize(NSSize(width: max(120, size.width), height: max(32, size.height)))
        let wasVisible = panel.isVisible
        if let lineRect {
            position(near: lineRect)
        }
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func position(near lineRect: NSRect) {
        let size = panel.frame.size
        let gap: CGFloat = 4
        var origin = NSPoint(x: lineRect.minX, y: lineRect.minY - size.height - gap)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: lineRect.minX, y: lineRect.minY)) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY + gap {
                origin.y = lineRect.maxY + gap
            }
            origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
        }
        panel.setFrameOrigin(origin)
    }
}

/// 候选下方拼音读音的显示策略（设置 › 输入 › 候选 › 拼音提示）。标签类注释不受影响。
enum ReadingDisplay: String, CaseIterable {
    /// 仅当读音与所打不同（模糊音 / 纠错 / 简拼 / 补全）时显示
    case correctedOnly
    case always
    case never

    static let defaultsKey = "LianaReadingDisplay"

    static var current: ReadingDisplay {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(ReadingDisplay.init(rawValue:)) ?? .never
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .correctedOnly: return "仅纠错时显示"
        case .always: return "始终显示"
        case .never: return "始终隐藏"
        }
    }

    func shows(_ candidate: Candidate) -> Bool {
        guard let reading = candidate.reading else { return true }
        switch self {
        case .always: return true
        case .never: return false
        case .correctedOnly: return reading != "exact"
        }
    }
}

/// 单个候选格：序号 + 文本 +（可选）拼音注释。颜色/字号来自主题侧。
private final class CandidateCell: NSView {
    static let maxTextWidth: CGFloat = 320

    var onClick: (() -> Void)?
    /// 右键（微信式候选管理）：把 cell 中心的屏幕坐标交给宿主弹菜单。
    var onContext: ((NSPoint) -> Void)?
    private let indexLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(labelWithString: "")
    private let column = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var baseBackground: CGColor = NSColor.clear.cgColor
    private let accent: NSColor
    private let baseFontSize: CGFloat
    private let side: CandidateTheme.Side
    private var isFirstCell = false
    /// 语音长句：允许两行换行展示（其余候选仍单行截断）。
    private var wraps = false
    private var wrapConstraint: NSLayoutConstraint?

    init(index: Int, side: CandidateTheme.Side) {
        self.side = side
        accent = side.accent ?? .controlAccentColor
        baseFontSize = side.fontSize ?? 17
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = (side.radius ?? 18) * 0.55

        indexLabel.stringValue = "\(index)"
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        indexLabel.alignment = .center

        textLabel.font = .systemFont(ofSize: baseFontSize, weight: .regular)
        textLabel.textColor = side.text ?? .labelColor
        textLabel.lineBreakMode = .byTruncatingMiddle
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        commentLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        commentLabel.textColor = side.comment ?? .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail
        commentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 文本 + 注释用纵向 stack：注释隐藏时自动收起，避免留空错位
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.addArrangedSubview(textLabel)
        column.addArrangedSubview(commentLabel)

        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indexLabel)
        addSubview(column)
        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            indexLabel.widthAnchor.constraint(equalToConstant: 16),
            indexLabel.heightAnchor.constraint(equalToConstant: 14),
            indexLabel.firstBaselineAnchor.constraint(equalTo: textLabel.firstBaselineAnchor),
            column.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ candidate: Candidate, isFirst: Bool = false) {
        isFirstCell = isFirst
        // 系统输入法同款：选中格实心 highlight + 白字；未选中纯文字无底
        indexLabel.wantsLayer = true
        indexLabel.layer?.cornerRadius = 6
        indexLabel.layer?.backgroundColor = NSColor.clear.cgColor
        if isFirst {
            baseBackground = accent.cgColor
            indexLabel.textColor = .white
        } else {
            baseBackground = (candidate.kind == "literal"
                ? NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor)
            indexLabel.textColor = side.comment ?? .tertiaryLabelColor
        }
        textLabel.stringValue = candidate.text
        textLabel.font = candidate.kind == "emoji"
            ? .systemFont(ofSize: baseFontSize + 9)
            : .systemFont(ofSize: baseFontSize, weight: .regular)
        if candidate.kind == "voice" {
            wraps = true
            // 抗压缩提到 required：低优先级被挤 1px 就会把末字换行到 frame 外整字消失
            textLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.maximumNumberOfLines = 2
            textLabel.preferredMaxLayoutWidth = 360
            let constraint = wrapConstraint ?? textLabel.widthAnchor.constraint(
                lessThanOrEqualToConstant: 360
            )
            constraint.isActive = true
            wrapConstraint = constraint
        } else {
            wraps = false
            textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textLabel.lineBreakMode = .byTruncatingMiddle
            textLabel.maximumNumberOfLines = 1
            textLabel.preferredMaxLayoutWidth = 0
            wrapConstraint?.isActive = false
        }
        if let comment = candidate.comment, !comment.isEmpty, candidate.kind != "emoji",
           ReadingDisplay.current.shows(candidate) {
            commentLabel.stringValue = comment
            commentLabel.isHidden = false
        } else {
            commentLabel.stringValue = ""
            commentLabel.isHidden = true
        }
        textLabel.textColor = isFirst
            ? .white
            : (side.text ?? .labelColor)
        commentLabel.textColor = isFirst
            ? NSColor.white.withAlphaComponent(0.72)
            : (side.comment ?? .secondaryLabelColor)
        layer?.backgroundColor = baseBackground
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        // 未选中悬停用中性灰（系统列表同款），不用 accent 蓝
        layer?.backgroundColor = isFirstCell
            ? accent.withAlphaComponent(0.88).cgColor
            : NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseBackground
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = isFirstCell
            ? accent.cgColor
            : NSColor.labelColor.withAlphaComponent(0.14).cgColor
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        // NSEvent.mouseLocation 即屏幕坐标（AppKit 原点），菜单直接可用
        onContext?(NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil // 右键统一走 rightMouseDown 的回调，菜单由宿主组装
    }

    override func mouseUp(with event: NSEvent) {
        mouseEntered(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func diagLine(index: Int, prefix: String) -> String {
        let tl = textLabel
        let cl = commentLabel
        let col = column
        return "\(prefix)[\(index)] text=\(tl.stringValue.prefix(12)) cell=\(frame.width)"
            + " col=\(col.frame.width) indexFrame=\(indexLabel.frame.width) indexIntrinsic=\(indexLabel.intrinsicContentSize.width)"
            + " labelFrame=\(tl.frame.width) labelIntrinsic=\(tl.intrinsicContentSize.width)"
            + " commentHidden=\(cl.isHidden) commentFrame=\(cl.isHidden ? 0 : cl.frame.width)"
            + " commentIntrinsic=\(cl.isHidden ? 0 : cl.intrinsicContentSize.width)"
            + " intrinsicCell=\(intrinsicContentSize.width)"
            + (tl.frame.width + 0.5 < tl.intrinsicContentSize.width ? "  <<< SQUEEZED" : "")
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = min(
            max(
                textLabel.intrinsicContentSize.width,
                commentLabel.isHidden ? 0 : commentLabel.intrinsicContentSize.width
            ),
            wraps ? 360 : Self.maxTextWidth
        )
        let height = textLabel.intrinsicContentSize.height
            + (commentLabel.isHidden ? 0 : commentLabel.intrinsicContentSize.height + 1)
        return NSSize(width: 8 + 16 + 6 + textWidth + 10, height: height + 5)
    }
}
