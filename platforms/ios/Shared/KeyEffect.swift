import UIKit

/// 按键的点击特效。全部是「按下瞬间在键上叠一层短动画」，不改布局、不拦触摸，
/// 0.4–0.7 秒后自己移除；关掉时零开销。
enum KeyEffect: String, CaseIterable, Codable {
    case off, ink, jelly, palette, spark, stars, ripple, rgb, flame, snow

    var title: String {
        switch self {
        case .off: return "关闭"
        case .ink: return "墨染"
        case .jelly: return "果冻"
        case .palette: return "调色盘"
        case .spark: return "火花"
        case .stars: return "星辰"
        case .ripple: return "液晶水波"
        case .rgb: return "机械键盘 RGB"
        case .flame: return "紫色火焰"
        case .snow: return "雪花融化"
        }
    }
}

/// 特效偏好存本进程 UserDefaults（键盘与宿主各一份，键盘里调的才生效）。
enum KeyEffectSettings {
    static let defaultsKey = "liana.keyeffect"
    static var current: KeyEffect {
        get { KeyEffect(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ripple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

enum KeyEffectPlayer {

    static func play(_ effect: KeyEffect, on button: UIView, tint: UIColor) {
        guard effect != .off, button.window != nil else { return }
        switch effect {
        case .off: return
        case .jelly: jelly(button)
        case .ink: ink(button, tint: tint)
        case .ripple: ripple(button, tint: tint)
        case .palette: palette(button)
        case .rgb: rgb(button)
        case .spark: emitter(button, kind: .spark, tint: tint)
        case .stars: emitter(button, kind: .stars, tint: tint)
        case .flame: emitter(button, kind: .flame, tint: tint)
        case .snow: emitter(button, kind: .snow, tint: tint)
        }
    }

    // MARK: - 形变类

    private static func jelly(_ button: UIView) {
        let original = button.transform
        UIView.animate(withDuration: 0.09, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            button.transform = original.scaledBy(x: 0.93, y: 0.93)
        } completion: { _ in
            UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.42, initialSpringVelocity: 0.9, options: [.allowUserInteraction]) {
                button.transform = original.scaledBy(x: 1.02, y: 1.02)
            } completion: { _ in
                UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction]) { button.transform = original }
            }
        }
    }

    // MARK: - 扩散类

    private static func ink(_ button: UIView, tint: UIColor) {
        let size = max(button.bounds.width, button.bounds.height) * 1.6
        let dot = CAShapeLayer()
        dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        dot.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
        dot.fillColor = tint.withAlphaComponent(0.16).cgColor
        dot.opacity = 0
        button.layer.insertSublayer(dot, at: 0)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.18
        grow.toValue = 1.0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.55, 0.0]
        fade.keyTimes = [0, 0.25, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dot.add(group, forKey: "ink")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { dot.removeFromSuperlayer() }
    }

    private static func ripple(_ button: UIView, tint: UIColor) {
        let maxSize = max(button.bounds.width, button.bounds.height) * 1.5
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: 0, y: 0, width: maxSize, height: maxSize)
        ring.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        ring.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: maxSize, height: maxSize)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = tint.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 2
        ring.transform = CATransform3DMakeScale(0.15, 0.15, 1)
        button.layer.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.15
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.57) { ring.removeFromSuperlayer() }
    }

    private static func palette(_ button: UIView) {
        let colors: [UIColor] = [.systemPink, .systemOrange, .systemTeal, .systemPurple]
        let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        for (index, color) in colors.enumerated() {
            let dab = UIView(frame: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            dab.backgroundColor = color.withAlphaComponent(0.85)
            dab.layer.cornerRadius = 4
            button.addSubview(dab)
            let angle = Double(index) / Double(colors.count) * .pi * 2
            UIView.animate(withDuration: 0.45, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                dab.center = CGPoint(x: center.x + CGFloat(cos(angle)) * 26, y: center.y + CGFloat(sin(angle)) * 26)
                dab.alpha = 0
                dab.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
            } completion: { _ in dab.removeFromSuperview() }
        }
    }

    private static func rgb(_ button: UIView) {
        let glow = CAGradientLayer()
        glow.frame = button.bounds
        glow.type = .conic
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        glow.colors = [UIColor.systemRed, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemRed].map { $0.withAlphaComponent(0.75).cgColor }
        glow.cornerRadius = button.layer.cornerRadius
        let mask = CAShapeLayer()
        mask.path = UIBezierPath(roundedRect: button.bounds.insetBy(dx: 1, dy: 1), cornerRadius: button.layer.cornerRadius).cgPath
        mask.fillColor = UIColor.clear.cgColor
        mask.strokeColor = UIColor.white.cgColor
        mask.lineWidth = 2.5
        glow.mask = mask
        button.layer.addSublayer(glow)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 0.8
        spin.repeatCount = 1
        glow.add(spin, forKey: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) { glow.removeFromSuperlayer() }
    }

    // MARK: - 粒子类

    private enum EmitterKind { case spark, stars, flame, snow }

    private static func emitter(_ button: UIView, kind: EmitterKind, tint: UIColor) {
        let birth = CAEmitterLayer()
        birth.frame = button.bounds
        birth.emitterPosition = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        birth.emitterSize = CGSize(width: button.bounds.width * 0.6, height: button.bounds.height * 0.5)
        birth.emitterShape = .rectangle
        birth.renderMode = .additive

        let cell = CAEmitterCell()
        cell.birthRate = 1
        cell.lifetime = 0.55
        cell.lifetimeRange = 0.2
        cell.velocity = 0
        cell.velocityRange = 0
        cell.scale = 0.5
        cell.scaleRange = 0.25
        cell.alphaSpeed = -1.6
        cell.spinRange = 0
        cell.contents = dotImage().cgImage

        switch kind {
        case .spark:
            cell.emissionLongitude = -CGFloat.pi / 2
            cell.emissionRange = CGFloat.pi * 2
            cell.velocity = 42
            cell.velocityRange = 26
            cell.yAcceleration = 90
            cell.scale = 0.32
            cell.color = tint.cgColor
        case .stars:
            cell.emissionRange = CGFloat.pi * 2
            cell.velocity = 18
            cell.velocityRange = 14
            cell.scale = 0.22
            cell.scaleRange = 0.16
            cell.lifetime = 0.7
            cell.alphaSpeed = -1.1
            cell.color = UIColor.white.cgColor
        case .flame:
            cell.emissionLongitude = -CGFloat.pi / 2
            cell.emissionRange = CGFloat.pi / 6
            cell.velocity = 34
            cell.velocityRange = 16
            cell.yAcceleration = -34
            cell.scale = 0.42
            cell.scaleSpeed = -0.6
            cell.color = UIColor(red: 0.62, green: 0.36, blue: 1.0, alpha: 1).cgColor
            cell.lifetime = 0.48
        case .snow:
            cell.emissionRange = CGFloat.pi * 2
            cell.velocity = 12
            cell.velocityRange = 8
            cell.yAcceleration = 40
            cell.scale = 0.2
            cell.scaleRange = 0.12
            cell.color = UIColor.white.cgColor
            cell.lifetime = 0.65
        }

        birth.emitterCells = [cell]
        button.layer.addSublayer(birth)
        // 只爆发一瞬间，随后让粒子自然衰减
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            birth.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { birth.removeFromSuperlayer() }
    }

    /// 1×1 的圆点，作为粒子贴图；缓存一次，避免每次按键都画图。
    private static let dot: UIImage = {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()

    private static func dotImage() -> UIImage { dot }
}
