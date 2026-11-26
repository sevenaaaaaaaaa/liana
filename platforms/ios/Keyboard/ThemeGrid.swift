import UIKit

/// 配色与点击特效的网格选择器：直接嵌在「布局与手感」面板里滚动，
/// 点一下立即生效并当场打勾。以前用 UIAlertController 列 19 行 action sheet，
/// 既放不下也看不到效果；现在主题还会继续加，列表式的选法必须退役。
///
/// 生命周期约定：面板关闭时整体丢弃，网格内部用 weak 回调，不持有面板/键盘。
final class ColorwayGrid: UIView {
    private var swatches: [ThemeSwatchButton] = []

    /// 选中某套配色后的额外动作（键盘换肤重建由调用方做，网格只管自己打勾）。
    init(onApply: @escaping () -> Void) {
        super.init(frame: .zero)
        let columns = UIScreen.main.bounds.width >= 380 ? 4 : 3
        let all = LianaColorway.allCases
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        var index = 0
        while index < all.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
            for offset in 0..<columns {
                let i = index + offset
                if i < all.count {
                    let swatch = ThemeSwatchButton(colorway: all[i])
                    swatches.append(swatch)
                    row.addArrangedSubview(swatch)
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            stack.addArrangedSubview(row)
            index += columns
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for swatch in swatches {
            swatch.onSelect = { [weak self] colorway in
                LianaPalette.colorway = colorway
                onApply()
                self?.refresh()
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let current = LianaPalette.colorway
        for swatch in swatches { swatch.refreshCheckmark(current: current) }
    }
}

/// 一套配色的小样：三枚即时解析的色块（键盘面 / 键面 / 主色）+ 名称 + 选中勾。
final class ThemeSwatchButton: LianaPressButton {
    let colorway: LianaColorway
    var onSelect: ((LianaColorway) -> Void)?
    private let checkmark = UILabel()

    init(colorway: LianaColorway) {
        self.colorway = colorway
        super.init(frame: .zero)
        surface = .tile
        rounded = 12
        accessibilityIdentifier = "theme." + colorway.rawValue
        accessibilityLabel = colorway.title + "，" + colorway.note

        // 动态色：系统切深浅色时色块跟着换，不用手动刷新
        func chip(_ role: LianaColorway.Role) -> UIView {
            let view = UIView()
            view.backgroundColor = UIColor { traits in colorway.color(role, dark: traits.userInterfaceStyle == .dark) }
            view.layer.cornerRadius = 4
            view.layer.borderWidth = 0.5
            view.layer.borderColor = LianaPalette.stroke.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 16).isActive = true
            view.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return view
        }
        let chips = UIStackView(arrangedSubviews: [chip(.keyboard), chip(.key), chip(.primary)])
        chips.spacing = 4
        chips.isUserInteractionEnabled = false

        let title = UILabel()
        title.text = colorway.title
        title.font = LianaPalette.font(12, weight: .medium, maximum: 15)
        title.textColor = LianaPalette.ink
        title.textAlignment = .center
        title.adjustsFontForContentSizeCategory = true
        title.isUserInteractionEnabled = false

        checkmark.text = "✓"
        checkmark.font = .systemFont(ofSize: 12, weight: .bold)
        checkmark.textColor = LianaPalette.ink
        checkmark.isUserInteractionEnabled = false
        checkmark.translatesAutoresizingMaskIntoConstraints = false

        let column = UIStackView(arrangedSubviews: [chips, title])
        column.axis = .vertical
        column.spacing = 6
        column.alignment = .center
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        addSubview(checkmark)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            checkmark.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSelect?(self.colorway)
        }, for: .touchUpInside)
        refreshCheckmark(current: LianaPalette.colorway)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshCheckmark(current: LianaColorway) {
        checkmark.isHidden = current != colorway
        isSelected = current == colorway
        accessibilityValue = current == colorway ? "当前" : nil
    }
}

/// 点击特效网格：九种，当前那种高亮；按下任意键即可当场试出效果。
final class EffectGrid: UIView {
    private var buttons: [(effect: KeyEffect, button: LianaPressButton)] = []

    init() {
        super.init(frame: .zero)
        let columns = 3
        let all = KeyEffect.allCases
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        var index = 0
        while index < all.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
            for offset in 0..<columns {
                let i = index + offset
                let button = LianaPressButton(frame: .zero)
                button.surface = .utility
                button.rounded = 12
                if i < all.count {
                    let effect = all[i]
                    button.setTitle(effect.title, for: .normal)
                    button.titleLabel?.font = LianaPalette.font(13, weight: .medium, maximum: 17)
                    button.accessibilityIdentifier = "effect." + effect.rawValue
                    button.addAction(UIAction { [weak self] _ in
                        KeyEffectSettings.current = effect
                        self?.refresh()
                    }, for: .touchUpInside)
                    buttons.append((effect, button))
                }
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
            index += columns
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let current = KeyEffectSettings.current
        for entry in buttons { entry.button.isSelected = entry.effect == current }
    }
}
