import AppKit
import QuartzCore

/// 桌宠场景：看你正在用什么应用，给它摆上对应的道具（打游戏 = 手柄 + 霓虹灯，写代码 = 桌子 + 机械键盘 + 显示器……）。
///
/// 只读前台应用的 bundle id / 应用类别（系统公开信息，不需要任何权限），不看窗口内容。
/// 道具画在桌宠窗口里：背景层在角色后面，前景层（桌子、手柄、手机）挡在角色前面；不拦截鼠标。
enum PetScene: String {
    case none, office, coding, game, music, video, chat, design, meeting, reading, browse

    /// 场景里用户是「在忙但不打字」：不要打瞌睡
    var keepsAwake: Bool { [.game, .music, .video, .meeting, .design, .reading].contains(self) }

    /// 纸偶的场景姿态（pet.js 的 petSetScene）
    var pose: String {
        switch self {
        case .game: return "game"
        case .music: return "music"
        case .video: return "watch"
        default: return ""
        }
    }

    var emote: String? {
        switch self {
        case .game: return "🎮"
        case .coding: return "💻"
        case .office: return "☕"
        case .music: return "🎵"
        case .video: return "🍿"
        case .chat: return "💬"
        case .design: return "🎨"
        case .meeting: return "🤫"
        case .reading: return "📖"
        default: return nil
        }
    }

    var lines: [String] {
        switch self {
        case .game: return ["开黑吗？我来当你的队友！", "冲呀！", "这把稳了"]
        case .coding: return ["写代码啦，我帮你看着 bug", "今天也要少写点 bug 哦"]
        case .office: return ["开工！我陪你", "先来杯咖啡吧"]
        case .music: return ["这首好听～", "一起摇摆！"]
        case .video: return ["看什么呢？带我一个", "爆米花准备好了"]
        case .design: return ["画得真好看", "需要灵感吗？"]
        case .reading: return ["我也想看～", "安静读书时间"]
        default: return []
        }
    }
}

final class PetSceneDetector {
    static let shared = PetSceneDetector()

    private static let games = ["com.valvesoftware.steam", "com.blizzard", "net.battle", "com.epicgames", "com.riotgames",
                                "com.mojang", "com.gog", "com.nintendo", "com.playstation", "com.ea.", "com.ubisoft",
                                "com.mihoyo", "com.hoyoverse", "com.tencent.lol", "com.netease.mrzh", "com.feralinteractive",
                                "com.aspyr", "com.paradox", "com.devolverdigital", "com.supercell"]
    private static let coding = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop", "com.jetbrains", "com.apple.Terminal",
                                 "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "com.sublimetext", "dev.zed",
                                 "com.panic.Nova", "co.zeit.hyper", "net.kovidgoyal.kitty", "io.alacritty", "com.github.atom",
                                 "com.anthropic.claude", "com.openai.codex"]
    private static let office = ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.iWork",
                                 "com.apple.Notes", "notion.id", "md.obsidian", "com.kingsoft.wpsoffice", "com.apple.TextEdit",
                                 "com.ulyssesapp", "com.typora", "abnerworks.Typora", "com.craft", "com.electron.lark",
                                 "com.bytedance.macos.feishu", "com.apple.reminders", "com.culturedcode.ThingsMac", "com.flomoapp"]
    private static let music = ["com.spotify.client", "com.apple.Music", "com.netease.163music", "com.tencent.QQMusicMac",
                                "com.kugou", "com.apple.podcasts", "com.coppertino.Vox"]
    private static let video = ["com.apple.TV", "io.iina", "com.colliderli.iina", "org.videolan.vlc", "tv.danmaku.bili",
                                "com.apple.QuickTimePlayerX", "com.netflix", "com.youku", "com.iqiyi", "com.tencent.tenvideo",
                                "com.firecore.infuse"]
    private static let chat = ["com.tencent.xinWeChat", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "com.apple.MobileSMS",
                               "com.tencent.qq", "com.hnc.Discord", "net.whatsapp", "com.facebook.archon", "com.alibaba.DingTalkMac",
                               "com.bytedance.lark.Feishu"]
    private static let design = ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.adobe", "com.seriflabs", "com.pixelmatorteam",
                                 "com.linearity.curve", "com.procreate"]
    private static let meeting = ["us.zoom.xos", "com.microsoft.teams", "com.tencent.meeting", "com.cisco.webexmeetings",
                                  "com.apple.FaceTime", "com.bytedance.vc"]
    private static let reading = ["com.apple.iBooksX", "com.readdle.PDFExpert", "net.sourceforge.skim-app", "com.amazon.Kindle",
                                  "com.reederapp", "com.apple.Preview"]
    private static let browse = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser", "org.mozilla.firefox",
                                 "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware", "com.vivaldi", "com.ego"]

    private(set) var appScene: PetScene = .none
    private var observer: NSObjectProtocol?

    func start(onChange: @escaping () -> Void) {
        appScene = Self.scene(for: NSWorkspace.shared.frontmostApplication)
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.appScene = Self.scene(for: app)
            onChange()
        }
    }

    static func scene(for app: NSRunningApplication?) -> PetScene {
        guard let app, let id = app.bundleIdentifier else { return .none }
        func hit(_ list: [String]) -> Bool { list.contains { id == $0 || id.hasPrefix($0) } }
        if hit(games) { return .game }
        if hit(meeting) { return .meeting }
        if hit(coding) { return .coding }
        if hit(design) { return .design }
        if hit(music) { return .music }
        if hit(video) { return .video }
        if hit(chat) { return .chat }
        if hit(office) { return .office }
        if hit(reading) { return .reading }
        if hit(browse) { return .browse }
        // 没列出来的应用看它自己声明的类别
        let category = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String } ?? ""
        if category.contains("games") { return .game }
        if category.contains("developer-tools") { return .coding }
        if category.contains("productivity") || category.contains("business") { return .office }
        if category.contains("music") { return .music }
        if category.contains("entertainment") || category.contains("video") { return .video }
        if category.contains("social-networking") { return .chat }
        if category.contains("graphics-design") || category.contains("photography") { return .design }
        if category.contains("books") || category.contains("reference") { return .reading }
        return .none
    }
}

// MARK: - 道具绘制

/// 场景道具层：back 画在角色后面，front 挡在角色前面。鼠标事件穿透给桌宠。
final class PetSceneView: NSView {
    enum Layer { case back, front }

    let layerKind: Layer
    private(set) var scene: PetScene = .none
    private(set) var night = false
    private var animated: [CALayer] = []

    init(frame: NSRect, layer kind: Layer) {
        layerKind = kind
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 换场景：旧道具淡出，新道具从下往上滑入
    func show(_ scene: PetScene, night: Bool, animated animate: Bool) {
        guard scene != self.scene || night != self.night else { return }
        self.scene = scene
        self.night = night
        let rebuild = { [weak self] in
            guard let self else { return }
            self.animated.forEach { $0.removeFromSuperlayer() }
            self.animated.removeAll()
            self.needsDisplay = true
            self.addAnimatedBits()
        }
        guard animate, let layer else { return rebuild() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 0
        }, completionHandler: {
            rebuild()
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = -self.bounds.height * 0.08
            slide.toValue = 0
            slide.duration = 0.35
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(slide, forKey: "slide")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 1
            }
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w >= 110 else { return }   // 太小的桌宠不摆道具
        switch layerKind {
        case .back: drawBack(w: w, h: h)
        case .front: drawFront(w: w, h: h)
        }
    }

    // MARK: 背景层

    private func drawBack(w: CGFloat, h: CGFloat) {
        if night {
            emoji("🌙", at: NSPoint(x: w * 0.14, y: h * 0.86), size: w * 0.11)
            for (x, y, s) in [(0.3, 0.93, 0.025), (0.82, 0.88, 0.02), (0.7, 0.96, 0.015), (0.08, 0.7, 0.015)] as [(CGFloat, CGFloat, CGFloat)] {
                star(at: NSPoint(x: w * x, y: h * y), r: w * s)
            }
        }
        switch scene {
        case .game:
            radialGlow(center: NSPoint(x: w * 0.5, y: h * 0.45), radius: w * 0.62,
                       color: NSColor(srgbRed: 0.55, green: 0.3, blue: 1, alpha: 0.32))
            radialGlow(center: NSPoint(x: w * 0.5, y: h * 0.04), radius: w * 0.45,
                       color: NSColor(srgbRed: 0.1, green: 0.85, blue: 1, alpha: 0.35), squash: 0.18)
        case .coding:
            monitor(NSRect(x: w * 0.56, y: h * 0.2, width: w * 0.42, height: h * 0.26), code: true)
        case .office:
            lamp(base: NSPoint(x: w * 0.12, y: h * 0.2), height: h * 0.3)
        case .video:
            radialGlow(center: NSPoint(x: w * 0.5, y: h * 0.62), radius: w * 0.6,
                       color: NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 0.28))
        case .music:
            radialGlow(center: NSPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.55,
                       color: NSColor(srgbRed: 1, green: 0.45, blue: 0.7, alpha: 0.22))
        case .meeting:
            emoji("🎥", at: NSPoint(x: w * 0.86, y: h * 0.86), size: w * 0.09)
        default:
            break
        }
    }

    // MARK: 前景层

    private func drawFront(w: CGFloat, h: CGFloat) {
        switch scene {
        case .office, .coding:
            desk(w: w, h: h)
            keyboard(NSRect(x: w * 0.25, y: h * 0.172, width: w * 0.5, height: h * 0.045), rgb: scene == .coding)
            if scene == .office {
                emoji("☕", at: NSPoint(x: w * 0.86, y: h * 0.235), size: w * 0.12)
                emoji("🪴", at: NSPoint(x: w * 0.11, y: h * 0.25), size: w * 0.13)
            } else {
                emoji("🦆", at: NSPoint(x: w * 0.87, y: h * 0.23), size: w * 0.11)
            }
        case .game:
            controller(center: NSPoint(x: w * 0.5, y: h * 0.33), width: w * 0.36)
        case .music:
            equalizerBase(w: w, h: h)
            emoji("🎧", at: NSPoint(x: w * 0.84, y: h * 0.12), size: w * 0.12)
        case .video:
            emoji("🍿", at: NSPoint(x: w * 0.82, y: h * 0.12), size: w * 0.15)
            emoji("🥤", at: NSPoint(x: w * 0.16, y: h * 0.11), size: w * 0.12)
        case .chat:
            phone(center: NSPoint(x: w * 0.62, y: h * 0.36), size: NSSize(width: w * 0.16, height: w * 0.28))
        case .design:
            tablet(NSRect(x: w * 0.2, y: h * 0.06, width: w * 0.6, height: h * 0.09))
            emoji("🎨", at: NSPoint(x: w * 0.13, y: h * 0.2), size: w * 0.12)
        case .reading:
            emoji("📖", at: NSPoint(x: w * 0.5, y: h * 0.33), size: w * 0.2)
        case .meeting:
            emoji("🎧", at: NSPoint(x: w * 0.84, y: h * 0.12), size: w * 0.11)
        case .browse:
            emoji("☕", at: NSPoint(x: w * 0.86, y: h * 0.1), size: w * 0.11)
        case .none:
            break
        }
    }

    // MARK: 动态小细节（热气、音符、音柱、屏幕代码、星星闪）

    private func addAnimatedBits() {
        guard let host = layer, bounds.width >= 110 else { return }
        let w = bounds.width, h = bounds.height
        if layerKind == .front && scene == .office {
            let steam = emitter(text: "～", color: NSColor.white.withAlphaComponent(0.7), at: CGPoint(x: w * 0.86, y: h * 0.3),
                                rate: 1.6, velocity: 10, life: 2.2, size: w * 0.05)
            host.addSublayer(steam)
            animated.append(steam)
        }
        if layerKind == .front && scene == .music {
            let notes = emitter(text: "♪", color: NSColor.systemPink, at: CGPoint(x: w * 0.5, y: h * 0.55), rate: 0.9,
                                velocity: 22, life: 2.6, size: w * 0.07, spread: .pi * 0.7)
            host.addSublayer(notes)
            animated.append(notes)
            for i in 0..<7 {
                let bar = CALayer()
                let bw = w * 0.055
                bar.frame = CGRect(x: w * 0.2 + CGFloat(i) * bw * 1.35, y: h * 0.02, width: bw, height: h * 0.1)
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                bar.position = CGPoint(x: bar.frame.midX, y: h * 0.02)
                bar.backgroundColor = NSColor(srgbRed: 1, green: 0.4 + CGFloat(i) * 0.06, blue: 0.75, alpha: 0.75).cgColor
                bar.cornerRadius = bw * 0.3
                let pulse = CABasicAnimation(keyPath: "transform.scale.y")
                pulse.fromValue = 0.25
                pulse.toValue = 1
                pulse.duration = 0.3 + Double(i % 3) * 0.12
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timeOffset = Double(i) * 0.17
                bar.add(pulse, forKey: "eq")
                host.addSublayer(bar)
                animated.append(bar)
            }
        }
        if layerKind == .front && scene == .chat {
            let bubbles = emitter(text: "💬", color: .white, at: CGPoint(x: w * 0.7, y: h * 0.5), rate: 0.35,
                                  velocity: 16, life: 2.4, size: w * 0.06)
            host.addSublayer(bubbles)
            animated.append(bubbles)
        }
        if layerKind == .back && night {
            for (x, y) in [(0.3, 0.93), (0.82, 0.88)] as [(CGFloat, CGFloat)] {
                let twinkle = CALayer()
                twinkle.frame = CGRect(x: w * x - 3, y: h * y - 3, width: 6, height: 6)
                twinkle.cornerRadius = 3
                twinkle.backgroundColor = NSColor.white.cgColor
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 0.1
                blink.toValue = 0.9
                blink.duration = 1.2 + Double(x)
                blink.autoreverses = true
                blink.repeatCount = .infinity
                twinkle.add(blink, forKey: "twinkle")
                host.addSublayer(twinkle)
                animated.append(twinkle)
            }
        }
    }

    private func emitter(text: String, color: NSColor, at point: CGPoint, rate: Float, velocity: CGFloat,
                         life: Float, size: CGFloat, spread: CGFloat = .pi / 6) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        let cell = CAEmitterCell()
        let image = NSImage(size: NSSize(width: size * 2, height: size * 2), flipped: false) { rect in
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size * 1.4), .foregroundColor: color])
                .draw(at: NSPoint(x: rect.width * 0.15, y: rect.height * 0.1))
            return true
        }
        cell.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cell.birthRate = rate
        cell.lifetime = life
        cell.velocity = velocity
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = spread
        cell.alphaSpeed = -1 / life
        cell.scale = 0.5
        cell.scaleSpeed = 0.1
        cell.spinRange = 0.6
        emitter.emitterCells = [cell]
        return emitter
    }

    // MARK: 图形

    private func emoji(_ s: String, at center: NSPoint, size: CGFloat) {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let sz = str.size()
        str.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    }

    private func star(at p: NSPoint, r: CGFloat) {
        NSColor.white.withAlphaComponent(0.8).setFill()
        let path = NSBezierPath()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 + .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.45
            let pt = NSPoint(x: p.x + cos(a) * rr, y: p.y + sin(a) * rr)
            i == 0 ? path.move(to: pt) : path.line(to: pt)
        }
        path.close()
        path.fill()
    }

    private func radialGlow(center: NSPoint, radius: CGFloat, color: NSColor, squash: CGFloat = 1) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: squash)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    private func desk(w: CGFloat, h: CGFloat) {
        let top = h * 0.2
        // 桌面（浅木色）+ 桌沿（深一点）+ 底下一道阴影
        let front = NSBezierPath(roundedRect: NSRect(x: 2, y: 0, width: w - 4, height: top - h * 0.03), xRadius: 4, yRadius: 4)
        NSColor(srgbRed: 0.55, green: 0.39, blue: 0.27, alpha: 1).setFill()
        front.fill()
        let surface = NSBezierPath(roundedRect: NSRect(x: 0, y: top - h * 0.045, width: w, height: h * 0.045), xRadius: 5, yRadius: 5)
        NSColor(srgbRed: 0.76, green: 0.58, blue: 0.42, alpha: 1).setFill()
        surface.fill()
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: NSRect(x: 2, y: top - h * 0.05, width: w - 4, height: h * 0.006)).fill()
        // 抽屉把手
        NSColor(srgbRed: 0.42, green: 0.29, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: w * 0.44, y: top * 0.45, width: w * 0.12, height: h * 0.012), xRadius: 2, yRadius: 2).fill()
    }

    private func keyboard(_ r: NSRect, rgb: Bool) {
        if rgb, let ctx = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
               NSColor.systemRed.cgColor, NSColor.systemYellow.cgColor, NSColor.systemGreen.cgColor,
               NSColor.systemTeal.cgColor, NSColor.systemPurple.cgColor,
           ] as CFArray, locations: nil) {
            ctx.saveGState()
            ctx.setAlpha(0.7)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -2, dy: -2), cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
            ctx.restoreGState()
        }
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        NSColor(white: 0.38, alpha: 1).setFill()
        let rows = 3, cols = 12
        let kw = r.width / CGFloat(cols), kh = r.height / CGFloat(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let key = NSRect(x: r.minX + CGFloat(col) * kw + kw * 0.15, y: r.minY + CGFloat(row) * kh + kh * 0.18,
                                 width: kw * 0.7, height: kh * 0.62)
                NSBezierPath(roundedRect: key, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    private func monitor(_ r: NSRect, code: Bool) {
        NSColor(white: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        let screen = r.insetBy(dx: r.width * 0.05, dy: r.height * 0.08)
        NSColor(srgbRed: 0.1, green: 0.12, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 3, yRadius: 3).fill()
        if code {
            let colors: [NSColor] = [.systemPink, .systemTeal, .systemYellow, .systemGreen, .systemPurple, .systemTeal]
            for i in 0..<6 {
                colors[i].withAlphaComponent(0.85).setFill()
                let indent = CGFloat([0, 1, 2, 2, 1, 0][i]) * screen.width * 0.08
                let len = screen.width * [0.6, 0.45, 0.55, 0.35, 0.5, 0.3][i]
                NSBezierPath(roundedRect: NSRect(x: screen.minX + screen.width * 0.08 + indent,
                                                 y: screen.maxY - screen.height * (0.15 + CGFloat(i) * 0.13),
                                                 width: len, height: screen.height * 0.06), xRadius: 1, yRadius: 1).fill()
            }
        }
        NSColor(white: 0.25, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: r.midX - r.width * 0.04, y: r.minY - r.height * 0.12, width: r.width * 0.08, height: r.height * 0.12)).fill()
    }

    private func lamp(base: NSPoint, height: CGFloat) {
        radialGlow(center: NSPoint(x: base.x + height * 0.25, y: base.y + height * 0.6), radius: height * 0.9,
                   color: NSColor(srgbRed: 1, green: 0.85, blue: 0.5, alpha: night ? 0.45 : 0.25))
        let arm = NSBezierPath()
        arm.move(to: base)
        arm.line(to: NSPoint(x: base.x, y: base.y + height * 0.75))
        arm.line(to: NSPoint(x: base.x + height * 0.22, y: base.y + height * 0.9))
        arm.lineWidth = max(2, height * 0.04)
        arm.lineCapStyle = .round
        NSColor(white: 0.3, alpha: 1).setStroke()
        arm.stroke()
        let shade = NSBezierPath()
        let tip = NSPoint(x: base.x + height * 0.22, y: base.y + height * 0.9)
        shade.move(to: NSPoint(x: tip.x - height * 0.08, y: tip.y + height * 0.06))
        shade.line(to: NSPoint(x: tip.x + height * 0.16, y: tip.y + height * 0.02))
        shade.line(to: NSPoint(x: tip.x + height * 0.1, y: tip.y - height * 0.12))
        shade.close()
        NSColor(srgbRed: 0.95, green: 0.65, blue: 0.3, alpha: 1).setFill()
        shade.fill()
    }

    private func controller(center c: NSPoint, width w: CGFloat) {
        let h = w * 0.42
        let body = NSBezierPath(roundedRect: NSRect(x: c.x - w * 0.36, y: c.y - h * 0.3, width: w * 0.72, height: h * 0.62),
                                xRadius: h * 0.3, yRadius: h * 0.3)
        body.append(NSBezierPath(ovalIn: NSRect(x: c.x - w * 0.5, y: c.y - h * 0.55, width: w * 0.34, height: h * 0.85)))
        body.append(NSBezierPath(ovalIn: NSRect(x: c.x + w * 0.16, y: c.y - h * 0.55, width: w * 0.34, height: h * 0.85)))
        NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -2), blur: 4,
                                                        color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(srgbRed: 0.18, green: 0.19, blue: 0.24, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
        // 十字键
        NSColor(white: 0.55, alpha: 1).setFill()
        let dx = c.x - w * 0.28, dy = c.y
        NSBezierPath(rect: NSRect(x: dx - w * 0.07, y: dy - w * 0.022, width: w * 0.14, height: w * 0.044)).fill()
        NSBezierPath(rect: NSRect(x: dx - w * 0.022, y: dy - w * 0.07, width: w * 0.044, height: w * 0.14)).fill()
        // 四个按键
        let bx = c.x + w * 0.28
        for (ox, oy, color) in [(0.0, 0.06, NSColor.systemYellow), (0.06, 0.0, NSColor.systemRed),
                                (0.0, -0.06, NSColor.systemGreen), (-0.06, 0.0, NSColor.systemBlue)] as [(CGFloat, CGFloat, NSColor)] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bx + ox * w - w * 0.025, y: dy + oy * w - w * 0.025, width: w * 0.05, height: w * 0.05)).fill()
        }
        // 中间的灯条
        NSColor.systemTeal.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: c.x - w * 0.06, y: c.y + h * 0.12, width: w * 0.12, height: h * 0.06), xRadius: 2, yRadius: 2).fill()
    }

    private func phone(center c: NSPoint, size: NSSize) {
        let r = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: size.width * 0.18, yRadius: size.width * 0.18).fill()
        let screen = r.insetBy(dx: size.width * 0.08, dy: size.width * 0.1)
        NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: size.width * 0.1, yRadius: size.width * 0.1).fill()
        for i in 0..<3 {
            (i % 2 == 0 ? NSColor.systemGreen : NSColor(white: 0.8, alpha: 1)).setFill()
            let bw = screen.width * (i % 2 == 0 ? 0.55 : 0.6)
            let x = i % 2 == 0 ? screen.maxX - bw - screen.width * 0.08 : screen.minX + screen.width * 0.08
            NSBezierPath(roundedRect: NSRect(x: x, y: screen.maxY - screen.height * (0.25 + CGFloat(i) * 0.25),
                                             width: bw, height: screen.height * 0.15), xRadius: 3, yRadius: 3).fill()
        }
    }

    private func tablet(_ r: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        NSColor(white: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: r.width * 0.12, dy: r.height * 0.2), xRadius: 3, yRadius: 3).fill()
        let pen = NSBezierPath()
        pen.move(to: NSPoint(x: r.maxX - r.width * 0.05, y: r.maxY + r.height * 0.9))
        pen.line(to: NSPoint(x: r.maxX - r.width * 0.25, y: r.midY))
        pen.lineWidth = 3
        pen.lineCapStyle = .round
        NSColor.systemOrange.setStroke()
        pen.stroke()
    }

    private func equalizerBase(w: CGFloat, h: CGFloat) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: NSRect(x: w * 0.17, y: h * 0.005, width: w * 0.66, height: h * 0.02), xRadius: 3, yRadius: 3).fill()
    }
}
