import UIKit

/// 十套配色的色卡。只做预览与试穿：键盘外观最终在键盘的「布局与手感」里调，
/// 因为键盘扩展有自己的沙盒，宿主的设置传不进去。
final class ColorwayGalleryViewController: UIViewController {
    private let list = LianaUI.vertical(spacing: 12)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "配色方案"
        LianaUI.navigation(self)
        navigationItem.rightBarButtonItem = LianaUI.closeItem(id: "colorway.done") { [weak self] in
            self?.dismiss(animated: true)
        }
        view.backgroundColor = LianaPalette.background
        let stack = LianaUI.scrollStack(in: self, spacing: 14)
        stack.addArrangedSubview(LianaUI.label("十套配色", size: 24, weight: .semibold))
        stack.addArrangedSubview(LianaUI.label("每套都配了浅色与深色两版，跟随系统外观切换。正文对背景 ≥ 7:1，次要文字 ≥ 4.5:1。", size: 13, muted: true))
        stack.addArrangedSubview(list)
        stack.addArrangedSubview(LianaUI.label("键盘里的「布局与手感 → 配色」才是真正生效的地方；这里只用来试看。", size: 12, muted: true))
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for colorway in LianaColorway.allCases {
            list.addArrangedSubview(card(colorway))
        }
    }

    private func card(_ colorway: LianaColorway) -> UIView {
        let selected = colorway == LianaPalette.colorway
        let title = LianaUI.label(colorway.title + (selected ? "  ✓" : ""), size: 16, weight: .semibold)
        let note = LianaUI.label(colorway.note, size: 12, muted: true)

        let swatches = UIStackView()
        swatches.spacing = 6
        swatches.distribution = .fillEqually
        for role in [LianaColorway.Role.background, .card, .key, .primary, .ink] {
            let chip = UIView()
            chip.backgroundColor = colorway.color(role, dark: view.traitCollection.userInterfaceStyle == .dark)
            chip.layer.cornerRadius = 7
            chip.layer.cornerCurve = .continuous
            chip.layer.borderWidth = 1
            chip.layer.borderColor = LianaPalette.stroke.resolvedColor(with: traitCollection).cgColor
            chip.heightAnchor.constraint(equalToConstant: 30).isActive = true
            swatches.addArrangedSubview(chip)
        }

        let stack = LianaUI.vertical([title, note, swatches], spacing: 8)
        let card = LianaUI.card([stack], spacing: 8)
        card.accessibilityIdentifier = "colorway.\(colorway.rawValue)"
        let tap = UITapGestureRecognizer(target: self, action: #selector(pick(_:)))
        card.addGestureRecognizer(tap)
        card.isUserInteractionEnabled = true
        card.tag = LianaColorway.allCases.firstIndex(of: colorway) ?? 0
        return card
    }

    @objc private func pick(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag, LianaColorway.allCases.indices.contains(index) else { return }
        LianaPalette.colorway = LianaColorway.allCases[index]
        view.backgroundColor = LianaPalette.background
        render()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
