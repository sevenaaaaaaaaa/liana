import UIKit

/// iOS uses a neutral pair of palettes; semantic colors are shared by the app and extension.
enum LianaPalette {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
        }
    }
    static let background = pair(0xF5F5F2, 0x101112)
    static let card = pair(0xFFFFFF, 0x1B1D1F)
    static let soft = pair(0xECEDE9, 0x282A2C)
    static let ink = pair(0x191B1D, 0xF3F3EF)
    static let muted = pair(0x64686A, 0xB3B7B9)
    static let stroke = pair(0xDDDFDC, 0x3B3E40)
    static let primary = pair(0x202224, 0xEDEEE9)
    static let onPrimary = pair(0xFFFFFF, 0x17191B)
    static let keyboard = pair(0xE5E7E6, 0x17191B)
    static let key = pair(0xFFFFFF, 0x303335)
    static let pressed = pair(0xC4C8C7, 0x505557)
    static let utility = pair(0xCFD3D1, 0x222527)
    static let shadow = pair(0x9DA3A0, 0x080909)
    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body, maximum: CGFloat? = nil) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let maximum { return UIFontMetrics(forTextStyle: style).scaledFont(for: base, maximumPointSize: maximum) }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}

enum LianaMotion {
    static var enabled: Bool { !UIAccessibility.isReduceMotionEnabled && UIView.areAnimationsEnabled }
    static func reveal(_ view: UIView) {
        guard enabled else { return }
        view.alpha = 0; view.transform = CGAffineTransform(translationX: 0, y: 6)
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) { view.alpha = 1; view.transform = .identity }
    }
    static func dismiss(_ view: UIView, completion: (() -> Void)? = nil) {
        view.isUserInteractionEnabled = false
        guard enabled else { view.removeFromSuperview(); completion?(); return }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn], animations: { view.alpha = 0; view.transform = CGAffineTransform(translationX: 0, y: 3) }) { _ in view.removeFromSuperview(); completion?() }
    }
}

/// Immediate touch-down feedback without moving the key or invalidating layout.
class LianaPressButton: UIButton {
    enum Role { case plain, key, utility, primary, tile }
    var surface: Role = .plain { didSet { refreshAppearance() } }
    var rounded: CGFloat = 10 { didSet { layer.cornerRadius = rounded } }
    override var isHighlighted: Bool { didSet { refreshAppearance(animate: !isHighlighted) } }
    override var isEnabled: Bool { didSet { refreshAppearance() } }
    override var isSelected: Bool { didSet { refreshAppearance() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous; layer.cornerRadius = rounded
        adjustsImageWhenHighlighted = false; adjustsImageWhenDisabled = false
        titleLabel?.font = LianaPalette.font(15, weight: .medium, maximum: 23)
        titleLabel?.adjustsFontForContentSizeCategory = true
        imageView?.contentMode = .scaleAspectFit
        setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .medium), forImageIn: .normal)
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); refreshAppearance() }
    override func layoutSubviews() {
        super.layoutSubviews()
        if surface == .key { layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: rounded).cgPath }
    }
    func refreshAppearance(animate: Bool = false) {
        let prominent = surface == .primary || isSelected
        let foreground = prominent ? LianaPalette.onPrimary : LianaPalette.ink
        let background: UIColor
        if isHighlighted { background = prominent ? LianaPalette.muted : LianaPalette.pressed }
        else if prominent { background = LianaPalette.primary }
        else { switch surface { case .key, .tile: background = LianaPalette.key; case .utility: background = LianaPalette.utility; default: background = .clear } }
        setTitleColor(foreground, for: .normal); setTitleColor(LianaPalette.muted, for: .disabled); tintColor = foreground
        let changes = { self.backgroundColor = background; self.alpha = self.isEnabled ? 1 : 0.42 }
        if animate && LianaMotion.enabled { UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: changes) } else { changes() }
        layer.shadowColor = LianaPalette.shadow.resolvedColor(with: traitCollection).cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1); layer.shadowRadius = 0
        layer.shadowOpacity = surface == .key && !isHighlighted ? 0.65 : 0
        layer.borderWidth = surface == .tile ? 0.5 : 0
        layer.borderColor = LianaPalette.stroke.resolvedColor(with: traitCollection).cgColor
    }
}

enum LianaUI {
    static func label(_ text: String, size: CGFloat = 15, weight: UIFont.Weight = .regular, muted: Bool = false) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = LianaPalette.font(size, weight: weight); label.adjustsFontForContentSizeCategory = true
        label.textColor = muted ? LianaPalette.muted : LianaPalette.ink
        return label
    }
    static func button(_ title: String, icon: String? = nil, role: LianaPressButton.Role = .utility, id: String? = nil, action: @escaping () -> Void) -> LianaPressButton {
        let button = LianaPressButton(frame: .zero); button.surface = role; button.rounded = 13
        button.setTitle(title, for: .normal)
        if let icon { button.setImage(UIImage(systemName: icon), for: .normal); button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -5, bottom: 0, right: 5) }
        button.contentEdgeInsets = UIEdgeInsets(top: 13, left: title.isEmpty ? 12 : 16, bottom: 13, right: title.isEmpty ? 12 : 16)
        if title.isEmpty { button.imageEdgeInsets = .zero }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    static func vertical(_ views: [UIView] = [], spacing: CGFloat = 12) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views); stack.axis = .vertical; stack.spacing = spacing; return stack
    }
    static func card(_ views: [UIView], spacing: CGFloat = 12) -> UIView {
        let card = UIView(); card.backgroundColor = LianaPalette.card; card.layer.cornerRadius = 20; card.layer.cornerCurve = .continuous
        let stack = vertical(views, spacing: spacing); stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)])
        return card
    }
    static func scrollStack(in controller: UIViewController, below topView: UIView? = nil, spacing: CGFloat = 20) -> UIStackView {
        controller.view.backgroundColor = LianaPalette.background; controller.view.tintColor = LianaPalette.ink
        let scroll = UIScrollView(); scroll.keyboardDismissMode = .interactive; scroll.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(scroll)
        let stack = vertical(spacing: spacing); stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        let center = stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor),scroll.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor),scroll.topAnchor.constraint(equalTo: topView?.bottomAnchor ?? controller.view.safeAreaLayoutGuide.topAnchor),scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),scroll.bottomAnchor.constraint(equalTo: controller.view.keyboardLayoutGuide.topAnchor),center,stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620)])
        let width = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40); width.priority = .defaultHigh; width.isActive = true
        return stack
    }
    static func closeItem(id: String, action: @escaping () -> Void) -> UIBarButtonItem {
        let button = LianaPressButton(frame: .zero)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .medium), forImageIn: .normal)
        button.accessibilityLabel = "完成"; button.accessibilityIdentifier = id
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44)])
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return UIBarButtonItem(customView: button)
    }
    static func navigation(_ controller: UIViewController) {
        let appearance = UINavigationBarAppearance(); appearance.configureWithOpaqueBackground(); appearance.backgroundColor = LianaPalette.background
        appearance.shadowColor = .clear; appearance.titleTextAttributes = [.foregroundColor: LianaPalette.ink, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        controller.navigationController?.navigationBar.standardAppearance = appearance; controller.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        controller.navigationController?.navigationBar.tintColor = LianaPalette.ink
        controller.navigationItem.backButtonDisplayMode = .minimal
        controller.navigationController?.presentationController?.presentedView?.tintColor = LianaPalette.ink
    }
    static func segment(_ items: [String]) -> UISegmentedControl {
        let control = UISegmentedControl(items: items)
        control.backgroundColor = LianaPalette.soft; control.selectedSegmentTintColor = LianaPalette.card
        control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: LianaPalette.muted], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: LianaPalette.ink], for: .selected)
        control.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return control
    }
}

final class LianaActionRow: LianaPressButton {
    init(title: String, subtitle: String, icon: String, id: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero); surface = .tile; rounded = 18; accessibilityIdentifier = id; accessibilityLabel = title + "，" + subtitle
        let image = UIImageView(image: UIImage(systemName: icon)); image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 23, weight: .regular); image.tintColor = LianaPalette.ink
        image.widthAnchor.constraint(equalToConstant: 30).isActive = true; image.contentMode = .scaleAspectFit
        let titleLabel = LianaUI.label(title, size: 16, weight: .semibold)
        let subtitleLabel = LianaUI.label(subtitle, size: 12, muted: true)
        let labels = LianaUI.vertical([titleLabel, subtitleLabel], spacing: 4)
        let arrow = UIImageView(image: UIImage(systemName: "chevron.right")); arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold); arrow.tintColor = LianaPalette.muted; arrow.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let row = UIStackView(arrangedSubviews: [image, labels, arrow]); row.spacing = 12; row.alignment = .center; row.isUserInteractionEnabled = false; row.accessibilityElementsHidden = true; row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),row.topAnchor.constraint(equalTo: topAnchor, constant: 16),row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),heightAnchor.constraint(greaterThanOrEqualToConstant: 76)])
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A decorative preview, not an input engine or a second keyboard instance.
final class KeyboardPreviewView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = LianaPalette.keyboard; clipsToBounds = true; layer.cornerRadius = 14; layer.cornerCurve = .continuous; isAccessibilityElement = true; accessibilityLabel = "键盘外观预览，全拼，候选你好"; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        let width = bounds.width
        func text(_ value: String, rect: CGRect, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular) {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight),.foregroundColor: color,.paragraphStyle: style]
            let h = value.size(withAttributes: attributes).height
            (value as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY-h/2, width: rect.width, height: h+2), withAttributes: attributes)
        }
        text("ni hao", rect: CGRect(x:8,y:5,width:64,height:18),size:10,color:LianaPalette.muted)
        let candidate = CGRect(x: 9, y: 28, width: 48, height: 26)
        LianaPalette.primary.setFill(); UIBezierPath(roundedRect:candidate,cornerRadius:6).fill()
        text("你好",rect:candidate,size:12,color:LianaPalette.onPrimary,weight:.semibold)
        text("你",rect:CGRect(x:64,y:28,width:34,height:26),size:12,color:LianaPalette.ink)
        text("你好啊",rect:CGRect(x:104,y:28,width:52,height:26),size:12,color:LianaPalette.ink)
        text("你好呀",rect:CGRect(x:166,y:28,width:52,height:26),size:12,color:LianaPalette.muted)
        for (row,letters) in ["qwertyuiop","asdfghjkl","zxcvbnm"].enumerated() {
            let pitch = (width-12)/10; let left = (width-CGFloat(letters.count)*pitch)/2
            for (column,letter) in letters.enumerated() {
                let key = CGRect(x:left+CGFloat(column)*pitch+1.5,y:62+CGFloat(row)*27,width:pitch-3,height:23)
                LianaPalette.key.setFill(); UIBezierPath(roundedRect:key,cornerRadius:4).fill()
                text(String(letter),rect:key,size:12,color:LianaPalette.ink)
            }
        }
        let bottomY: CGFloat = 145
        for (x,w,title) in [(CGFloat(8),CGFloat(40),"123"),(CGFloat(53),CGFloat(35),"中"),(CGFloat(93),max(30,width-153),"空格"),(width-55,CGFloat(47),"↵")] {
            let key=CGRect(x:x,y:bottomY,width:w,height:23); (title == "↵" ? LianaPalette.primary : LianaPalette.key).setFill(); UIBezierPath(roundedRect:key,cornerRadius:4).fill()
            text(title,rect:key,size:10,color:title == "↵" ? LianaPalette.onPrimary : LianaPalette.ink)
        }
    }
}

final class LianaActionTile: LianaPressButton {
    init(title: String, subtitle: String, icon: String, primary: Bool = false, id: String, action: @escaping () -> Void) {
        super.init(frame: .zero); surface = primary ? .primary : .tile; rounded = 20; accessibilityIdentifier = id; accessibilityLabel = title + "，" + subtitle
        let image = UIImageView(image: UIImage(systemName: icon)); image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular); image.tintColor = primary ? LianaPalette.onPrimary : LianaPalette.ink; image.contentMode = .left
        image.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let title = LianaUI.label(title, size: 17, weight: .semibold); title.textColor = primary ? LianaPalette.onPrimary : LianaPalette.ink
        let subtitle = LianaUI.label(subtitle, size: 12, muted: true); if primary { subtitle.textColor = LianaPalette.onPrimary.withAlphaComponent(0.8) }
        let stack = LianaUI.vertical([image,title,subtitle],spacing:6); stack.translatesAutoresizingMaskIntoConstraints = false; stack.isUserInteractionEnabled = false; stack.accessibilityElementsHidden = true; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-18),stack.topAnchor.constraint(equalTo:topAnchor,constant:18),stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-18),heightAnchor.constraint(greaterThanOrEqualToConstant:132)])
        addAction(UIAction { _ in action() },for:.touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Four visible lines grow with Dynamic Type; longer text scrolls inside the editor.
final class LianaEditorView:UITextView {
    var minimumHeight:CGFloat=120 { didSet { invalidateIntrinsicContentSize() } }
    var visibleLines:CGFloat=4 { didSet { invalidateIntrinsicContentSize() } }
    override var font:UIFont? { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize:CGSize { CGSize(width:UIView.noIntrinsicMetric,height:max(minimumHeight,(font?.lineHeight ?? 20)*visibleLines+textContainerInset.top+textContainerInset.bottom)) }
    override func traitCollectionDidChange(_ previousTraitCollection:UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); invalidateIntrinsicContentSize() }
}
