import UIKit

/// 「一个键 + 当前对象 + 算子」面板——入口收敛的第一步。
///
/// 它和 KeyboardToolsPanel 并存：旧面板一行不动，本面板从顶栏「输入工具」
/// 键**长按**进入。短按仍然打开旧面板，所以既有全部测试不受影响。
///
/// 这一版真正想验证的只有一件事：先把「我现在在处理什么字」摆在最上面，
/// 再列「对这段字能做什么」，并且让用不上的算子自动沉下去。等这套站住了，
/// 再把旧面板那 4 个分类的方块搬进来，最后删掉旧的。
///
/// 算子清单与排序放在 CommandCatalog（不依赖 UIKit），那边可以用 swiftc
/// 直接跑测试；本文件只负责画。
final class KeyboardCommandSheet: UIView {

    var onClose: (() -> Void)?
    /// 当前对象：光标前的一段文字；nil 表示这里没有可处理的文字。
    var currentText: (() -> String?)?
    var onAction: ((String, String) -> Void)?   // (op id, 当前文字)

    private let contextLabel = UILabel()
    private let contextCard = UIView()
    private let status = LianaUI.label("", size: 12, muted: true)
    private let list = LianaUI.vertical(spacing: 6)

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "command.sheet"
        backgroundColor = LianaPalette.keyboard
        buildHeader()
        buildContextCard()
        buildBody()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 构建

    private func buildHeader() {
        let back = LianaPressButton(frame: .zero)
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.accessibilityIdentifier = "command.close"
        back.accessibilityLabel = "返回键盘"
        back.widthAnchor.constraint(equalToConstant: 44).isActive = true
        back.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        let title = LianaUI.label("命令", size: 15, weight: .semibold)
        title.accessibilityIdentifier = "command.title"

        let header = UIStackView(arrangedSubviews: [back, title])
        header.spacing = 6
        header.alignment = .center
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        addArrangedRoot(header)
    }

    private func buildContextCard() {
        contextCard.backgroundColor = LianaPalette.card
        contextCard.layer.cornerRadius = 14
        contextCard.layer.cornerCurve = .continuous

        let caption = LianaUI.label("当前对象", size: 11, weight: .semibold, muted: true)
        contextLabel.numberOfLines = 2
        contextLabel.font = LianaPalette.font(15, weight: .medium, maximum: 20)
        contextLabel.textColor = LianaPalette.ink
        contextLabel.accessibilityIdentifier = "command.context"

        let stack = LianaUI.vertical([caption, contextLabel], spacing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contextCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contextCard.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contextCard.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contextCard.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contextCard.bottomAnchor, constant: -12),
        ])
        addArrangedRoot(contextCard)
    }

    private func buildBody() {
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16),
        ])
        status.isHidden = true
        status.accessibilityIdentifier = "command.status"
        status.numberOfLines = 2
        addArrangedRoot(scroll)
        addArrangedRoot(status)
    }

    /// 用一条竖向栈装外层三段，省掉重复的约束代码。
    private func addArrangedRoot(_ view: UIView) {
        if let root = subviews.compactMap({ $0 as? UIStackView }).first {
            root.addArrangedSubview(view)
            return
        }
        let root = LianaUI.vertical(spacing: 8)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        root.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    // MARK: - 刷新

    /// 重读当前对象并重排算子。键盘每次弹出、每次上屏后都可以调。
    func refresh() {
        let text = currentText?().map { CommandCatalog.snippet($0) } ?? ""
        let hasText = !text.isEmpty
        contextLabel.text = hasText ? text : "这里还没有可以处理的文字"
        contextLabel.textColor = hasText ? LianaPalette.ink : LianaPalette.muted

        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for op in CommandCatalog.ordered(hasText: hasText) {
            list.addArrangedSubview(row(for: op, hasText: hasText))
        }
    }

    private func row(for op: CommandCatalog.Op, hasText: Bool) -> UIView {
        let enabled = op.needsText ? hasText : true
        let button = LianaPressButton(frame: .zero)
        button.surface = .utility
        button.rounded = 11
        button.accessibilityIdentifier = "command.op." + op.id
        button.accessibilityLabel = op.title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.isEnabled = enabled
        button.alpha = enabled ? 1 : 0.42

        let icon = UIImageView(image: UIImage(systemName: op.icon))
        icon.tintColor = LianaPalette.ink
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = UILabel()
        title.text = op.title
        title.font = LianaPalette.font(15, weight: .medium, maximum: 20)
        title.textColor = LianaPalette.ink

        let row = UIStackView(arrangedSubviews: [icon, title, UIView()])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onAction?(op.id, self.currentText?() ?? "")
        }, for: .touchUpInside)
        return button
    }

    func status(_ text: String) {
        status.text = text
        status.isHidden = text.isEmpty
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
