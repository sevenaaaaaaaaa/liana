import UIKit

/// 顶栏入口：图标在上、两字标签在下。
///
/// 仍然是 `UIButton`（沿用命中测试、`isSelected`、无障碍与既有测试的查找方式），
/// 只是把内容排成竖排，让「语音 / 剪贴 / 文件 / 表情 / 命令 / 布局」一眼可读。
final class ToolbarEntryButton: LianaPressButton {
    private let iconView = UIImageView()
    private let caption = UILabel()

    var entryTitle: String { caption.text ?? "" }

    init(symbol: String, title: String, id: String) {
        super.init(frame: .zero)
        surface = .plain
        rounded = 12
        accessibilityIdentifier = id
        accessibilityLabel = title
        iconView.image = UIImage(systemName: symbol)?.withRenderingMode(.alwaysTemplate)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = LianaPalette.ink
        iconView.isUserInteractionEnabled = false
        caption.text = title
        caption.font = LianaPalette.font(10, weight: .medium, maximum: 12)
        caption.textColor = LianaPalette.muted
        caption.textAlignment = .center
        caption.adjustsFontForContentSizeCategory = true
        caption.isUserInteractionEnabled = false
        addSubview(iconView)
        addSubview(caption)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        caption.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 19),
            caption.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 会话里切换图标（「输入工具」打开时换成键盘图标）仍走 `setImage`，
    /// 这里把它转给竖排的图标视图，避免出现「按钮本体有图、界面看不到」。
    override func setImage(_ image: UIImage?, for state: UIControl.State) {
        super.setImage(nil, for: state)
        iconView.image = image?.withRenderingMode(.alwaysTemplate)
    }

    override func refreshAppearance(animate: Bool = false) {
        super.refreshAppearance(animate: animate)
        let prominent = surface == .primary || isSelected
        iconView.tintColor = prominent ? LianaPalette.onPrimary : LianaPalette.ink
        caption.textColor = prominent ? LianaPalette.onPrimary : LianaPalette.muted
    }
}
