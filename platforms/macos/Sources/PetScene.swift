import AppKit
import QuartzCore

private extension NSBezierPath {
    /// 纯色填充：AppKit 只有 fill() + setFill()，写多了很啰嗦。
    func fill(with color: NSColor, alpha: CGFloat = 1) {
        color.withAlphaComponent(color.alphaComponent * alpha).setFill()
        fill()
    }
}

/// 桌宠场景：看你正在用什么应用，给它摆上对应的道具（打游戏 = 手柄 + 霓虹灯，写代码 = 桌子 + 机械键盘 + 显示器……）。
///
/// 只读前台应用的 bundle id / 应用类别（系统公开信息，不需要任何权限），不看窗口内容。
/// 道具画在桌宠窗口里：背景层在角色后面，前景层（桌子、手柄、手机）挡在角色前面；不拦截鼠标。
enum PetScene: String {
    case none, office, coding, game, music, video, chat, design, meeting, reading, browse

    /// 场景里用户是「在忙但不打字」：不要打瞌睡
    var keepsAwake: Bool { [.game, .music, .video, .meeting, .design, .reading].contains(self) }

    /// 纸偶的场景姿态（pet-puppet.js 的 petSetScene）：打游戏 / 听歌 / 看视频总有专门的循环动作，
    /// 其余场景只有形象包里有对应的姿势图（写代码、喝咖啡、看手机…）时才生效
    var pose: String {
        switch self {
        case .video: return "watch"
        case .none, .browse: return ""
        default: return rawValue
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
            // 弯月：两个圆做 even-odd 填充，不依赖 emoji
            let r = NSRect(x: w * 0.80, y: h * 0.855, width: w * 0.088, height: w * 0.088)
            let crescent = NSBezierPath(ovalIn: r)
            crescent.append(NSBezierPath(ovalIn: r.offsetBy(dx: r.width * 0.34, dy: r.height * 0.14)))
            crescent.windingRule = .evenOdd
            fill(crescent, [NSColor(srgbRed: 1, green: 0.98, blue: 0.88, alpha: 0.95),
                            NSColor(srgbRed: 0.98, green: 0.90, blue: 0.70, alpha: 0.85)])
        }
        switch scene {
        case .game:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.55, green: 0.30, blue: 1, alpha: 0.30),
                    center: NSPoint(x: w * 0.5, y: h * 0.46), radius: w * 0.66)
            neonFloor(w: w, h: h, color: NSColor(srgbRed: 0.15, green: 0.85, blue: 1, alpha: 0.35))
        case .coding:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 0.26),
                    center: NSPoint(x: w * 0.74, y: h * 0.38), radius: w * 0.58)
            monitor(NSRect(x: w * 0.55, y: h * 0.195, width: w * 0.42, height: h * 0.27))
        case .office:
            ambient(w: w, h: h, color: NSColor(srgbRed: 1, green: 0.80, blue: 0.48, alpha: 0.20),
                    center: NSPoint(x: w * 0.24, y: h * 0.34), radius: w * 0.52)
            lamp(base: NSPoint(x: w * 0.10, y: h * 0.20), height: h * 0.32)
        case .video:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.35, green: 0.60, blue: 1, alpha: 0.26),
                    center: NSPoint(x: w * 0.5, y: h * 0.66), radius: w * 0.66)
            screenGlow(w: w, h: h)
        case .music:
            ambient(w: w, h: h, color: NSColor(srgbRed: 1, green: 0.42, blue: 0.70, alpha: 0.22),
                    center: NSPoint(x: w * 0.5, y: h * 0.52), radius: w * 0.60)
            neonFloor(w: w, h: h, color: NSColor(srgbRed: 1, green: 0.55, blue: 0.8, alpha: 0.22))
        case .meeting:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.75, alpha: 0.20),
                    center: NSPoint(x: w * 0.5, y: h * 0.58), radius: w * 0.55)
            meetingBadge(w: w, h: h)
        case .chat:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.35, green: 0.85, blue: 0.55, alpha: 0.18),
                    center: NSPoint(x: w * 0.62, y: h * 0.46), radius: w * 0.55)
        case .design:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.65, green: 0.45, blue: 1, alpha: 0.22),
                    center: NSPoint(x: w * 0.62, y: h * 0.42), radius: w * 0.55)
        case .reading:
            ambient(w: w, h: h, color: NSColor(srgbRed: 1, green: 0.72, blue: 0.42, alpha: 0.16),
                    center: NSPoint(x: w * 0.5, y: h * 0.4), radius: w * 0.52)
        case .browse:
            ambient(w: w, h: h, color: NSColor(srgbRed: 0.45, green: 0.62, blue: 0.95, alpha: 0.16),
                    center: NSPoint(x: w * 0.5, y: h * 0.4), radius: w * 0.5)
        case .none:
            return
        }
    }

    // MARK: 前景层

    private func drawFront(w: CGFloat, h: CGFloat) {
        switch scene {
        case .office, .coding, .browse:
            desk(w: w, h: h)
            keyboard(NSRect(x: w * 0.24, y: h * 0.198, width: w * 0.52, height: h * 0.05),
                     rgb: scene == .coding)
            if scene == .office {
                coffee(w: w, h: h)
                plant(w: w, h: h)
            } else if scene == .coding {
                duck(w: w, h: h)
            } else {
                coffee(w: w, h: h)
            }
        case .game:
            contactShadow(x: w * 0.5, y: h * 0.245, w: w * 0.52, alpha: 0.18)
            controller(center: NSPoint(x: w * 0.5, y: h * 0.31), width: w * 0.40)
        case .music:
            equalizerBase(w: w, h: h)
            headphones(w: w, h: h)
        case .video:
            popcorn(w: w, h: h)
            drink(w: w, h: h)
        case .chat:
            contactShadow(x: w * 0.64, y: h * 0.30, w: w * 0.24, alpha: 0.16)
            phone(center: NSPoint(x: w * 0.64, y: h * 0.37), size: NSSize(width: w * 0.17, height: w * 0.30))
        case .design:
            tablet(NSRect(x: w * 0.18, y: h * 0.075, width: w * 0.64, height: h * 0.10))
            palette(w: w, h: h)
        case .reading:
            contactShadow(x: w * 0.5, y: h * 0.27, w: w * 0.46, alpha: 0.14)
            book(w: w, h: h)
        case .meeting:
            headphones(w: w, h: h)
        case .none:
            break
        }
    }

    // MARK: 场景氛围

    private func ambient(w: CGFloat, h: CGFloat, color: NSColor, center: NSPoint, radius: CGFloat) {
        radialGlow(center: center, radius: radius, color: color)
        radialGlow(center: NSPoint(x: w * 0.5, y: h * 0.01), radius: w * 0.72,
                   color: color.withAlphaComponent(color.alphaComponent * 0.55), squash: 0.24)
    }

    private func neonFloor(w: CGFloat, h: CGFloat, color: NSColor) {
        let path = NSBezierPath(roundedRect: NSRect(x: w * 0.16, y: h * 0.012, width: w * 0.68, height: h * 0.016),
                                xRadius: h * 0.008, yRadius: h * 0.008)
        fill(path, [color, color.withAlphaComponent(0)], angle: 0)
    }

    private func screenGlow(w: CGFloat, h: CGFloat) {
        // 墙上电视：机身边框 + 落日画面 + 字幕条 + 底座
        let r = NSRect(x: w * 0.42, y: h * 0.585, width: w * 0.56, height: h * 0.255)
        radialGlow(center: NSPoint(x: r.midX, y: r.midY), radius: w * 0.62,
                   color: NSColor(srgbRed: 0.35, green: 0.60, blue: 1, alpha: 0.20))
        shadowed(10, -5, 0.30) {
            fill(NSBezierPath(roundedRect: r, xRadius: r.width * 0.035, yRadius: r.width * 0.035),
                 [NSColor(white: 0.26, alpha: 1), NSColor(white: 0.10, alpha: 1)])
        }
        let screen = r.insetBy(dx: r.width * 0.026, dy: r.height * 0.055)
        let screenPath = NSBezierPath(roundedRect: screen,
                                      xRadius: screen.width * 0.018, yRadius: screen.width * 0.018)
        fill(screenPath, [NSColor(srgbRed: 0.18, green: 0.24, blue: 0.44, alpha: 1),
                          NSColor(srgbRed: 0.42, green: 0.22, blue: 0.40, alpha: 1)])
        // 落日
        let sunSide = screen.width * 0.20
        let sun = NSBezierPath(ovalIn: NSRect(x: screen.midX - sunSide * 0.5,
                                              y: screen.midY - sunSide * 0.1,
                                              width: sunSide, height: sunSide))
        fillRadial(sun, [NSColor(srgbRed: 1, green: 0.82, blue: 0.48, alpha: 0.95),
                         NSColor(srgbRed: 1, green: 0.55, blue: 0.35, alpha: 0.15)],
                   center: NSPoint(x: 0, y: 0.2))
        // 远山剪影
        let hill = NSBezierPath()
        hill.move(to: NSPoint(x: screen.minX, y: screen.minY))
        hill.line(to: NSPoint(x: screen.minX, y: screen.minY + screen.height * 0.22))
        hill.curve(to: NSPoint(x: screen.midX, y: screen.minY + screen.height * 0.15),
                   controlPoint1: NSPoint(x: screen.minX + screen.width * 0.18, y: screen.minY + screen.height * 0.36),
                   controlPoint2: NSPoint(x: screen.midX - screen.width * 0.12, y: screen.minY + screen.height * 0.06))
        hill.curve(to: NSPoint(x: screen.maxX, y: screen.minY + screen.height * 0.26),
                   controlPoint1: NSPoint(x: screen.midX + screen.width * 0.16, y: screen.minY + screen.height * 0.06),
                   controlPoint2: NSPoint(x: screen.maxX - screen.width * 0.10, y: screen.minY + screen.height * 0.34))
        hill.line(to: NSPoint(x: screen.maxX, y: screen.minY))
        hill.close()
        hill.fill(with: NSColor(srgbRed: 0.12, green: 0.10, blue: 0.20, alpha: 0.75), alpha: 1)
        // 字幕
        let subtitle = NSBezierPath(roundedRect: NSRect(x: screen.midX - screen.width * 0.13,
                                                        y: screen.minY + screen.height * 0.10,
                                                        width: screen.width * 0.26,
                                                        height: screen.height * 0.045),
                                    xRadius: 2, yRadius: 2)
        subtitle.fill(with: NSColor.white.withAlphaComponent(0.55), alpha: 1)
        // 底座
        let stand = NSBezierPath(roundedRect: NSRect(x: r.midX - r.width * 0.10, y: r.minY - r.height * 0.10,
                                                     width: r.width * 0.20, height: r.height * 0.10),
                                 xRadius: 2, yRadius: 2)
        fill(stand, [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.16, alpha: 1)])
    }

    private func meetingBadge(w: CGFloat, h: CGFloat) {
        let side = w * 0.14
        let r = NSRect(x: w * 0.80, y: h * 0.84, width: side, height: side)
        let path = NSBezierPath(ovalIn: r)
        fill(path, [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.26, alpha: 0.92),
                    NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 0.96)])
        let mic = NSBezierPath(roundedRect: NSRect(x: r.midX - side * 0.09, y: r.midY - side * 0.12,
                                                   width: side * 0.18, height: side * 0.30),
                               xRadius: side * 0.09, yRadius: side * 0.09)
        fill(mic, [NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0.55)])
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: r.midX, y: r.midY - side * 0.18))
        stand.line(to: NSPoint(x: r.midX, y: r.midY - side * 0.28))
        stand.lineWidth = max(1, side * 0.045)
        stand.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.7).setStroke()
        stand.stroke()
    }

    // MARK: 动态小细节

    private func addAnimatedBits() {
        guard let host = layer, bounds.width >= 110 else { return }
        let w = bounds.width, h = bounds.height
        if layerKind == .front && scene == .office {
            let steam = emitter(text: "～", color: NSColor.white.withAlphaComponent(0.55),
                                at: CGPoint(x: w * 0.835, y: h * 0.29),
                                rate: 1.5, velocity: 10, life: 2.2, size: w * 0.05)
            host.addSublayer(steam)
            animated.append(steam)
        }
        if layerKind == .front && scene == .music {
            let notes = emitter(text: "♪", color: NSColor(srgbRed: 1, green: 0.52, blue: 0.78, alpha: 1),
                                at: CGPoint(x: w * 0.82, y: h * 0.22), rate: 0.8,
                                velocity: 20, life: 2.6, size: w * 0.06, spread: .pi * 0.5)
            host.addSublayer(notes)
            animated.append(notes)
            for i in 0..<7 {
                let bar = CALayer()
                let bw = w * 0.055
                bar.frame = CGRect(x: w * 0.2 + CGFloat(i) * bw * 1.35, y: h * 0.02, width: bw, height: h * 0.1)
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                bar.position = CGPoint(x: bar.frame.midX, y: h * 0.02)
                bar.backgroundColor = NSColor(srgbRed: 1, green: 0.42 + CGFloat(i) * 0.055, blue: 0.74, alpha: 0.8).cgColor
                bar.cornerRadius = bw * 0.3
                bar.shadowColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.75, alpha: 0.8).cgColor
                bar.shadowOpacity = 0.55
                bar.shadowRadius = 4
                let pulse = CABasicAnimation(keyPath: "transform.scale.y")
                pulse.fromValue = 0.22
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
            let bubbles = emitter(text: "💬", color: .white, at: CGPoint(x: w * 0.72, y: h * 0.52), rate: 0.3,
                                  velocity: 14, life: 2.6, size: w * 0.055)
            host.addSublayer(bubbles)
            animated.append(bubbles)
        }
        if layerKind == .back && night {
            for (x, y, r) in [(0.30, 0.93, 0.016), (0.82, 0.88, 0.014), (0.70, 0.96, 0.010), (0.08, 0.70, 0.010)] as [(CGFloat, CGFloat, CGFloat)] {
                let twinkle = CALayer()
                twinkle.frame = CGRect(x: w * x - w * r, y: h * y - w * r, width: w * r * 2, height: w * r * 2)
                twinkle.cornerRadius = w * r
                twinkle.backgroundColor = NSColor.white.cgColor
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 0.06
                blink.toValue = 0.55
                blink.duration = 1.1 + Double(x) * 1.4
                blink.autoreverses = true
                blink.repeatCount = .infinity
                twinkle.add(blink, forKey: "twinkle")
                host.addSublayer(twinkle)
                animated.append(twinkle)
            }
            moodStars(w: w, h: h)
        }
    }

    private func moodStars(w: CGFloat, h: CGFloat) {
        for (x, y, s) in [(0.18, 0.86, 0.02), (0.74, 0.92, 0.016), (0.90, 0.74, 0.013)] as [(CGFloat, CGFloat, CGFloat)] {
            star(at: NSPoint(x: w * x, y: h * y), r: w * s)
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

    // MARK: 绘制小工具

    private func fill(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat = -90) {
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: path, angle: angle)
        } else {
            path.fill()
        }
    }

    private func fillRadial(_ path: NSBezierPath, _ colors: [NSColor], center: NSPoint = .zero) {
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: path, relativeCenterPosition: center)
        } else {
            path.fill()
        }
    }

    private func shadowed(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return draw() }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur,
                      color: NSColor.black.withAlphaComponent(alpha).cgColor)
        draw()
        ctx.restoreGState()
    }

    private func contactShadow(x: CGFloat, y: CGFloat, w: CGFloat, alpha: CGFloat) {
        let rect = NSRect(x: x - w / 2, y: y, width: w, height: w * 0.10)
        fillRadial(NSBezierPath(ovalIn: rect), [NSColor.black.withAlphaComponent(alpha), .clear])
    }

    private func star(at p: NSPoint, r: CGFloat) {
        NSColor.white.withAlphaComponent(0.85).setFill()
        let path = NSBezierPath()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 + .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.42
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

    // MARK: 道具 · 桌子与键盘

    private func desk(w: CGFloat, h: CGFloat) {
        let topY = h * 0.195
        let faceH = topY
        let top = NSBezierPath(roundedRect: NSRect(x: -w * 0.02, y: topY, width: w * 1.04, height: h * 0.045),
                               xRadius: h * 0.02, yRadius: h * 0.02)
        fill(top, [NSColor(srgbRed: 0.80, green: 0.61, blue: 0.44, alpha: 1),
                   NSColor(srgbRed: 0.62, green: 0.44, blue: 0.30, alpha: 1)])
        // 桌沿高光
        let edge = NSBezierPath(roundedRect: NSRect(x: 0, y: topY + h * 0.041, width: w, height: h * 0.005),
                                xRadius: 2, yRadius: 2)
        edge.fill(with: NSColor.white.withAlphaComponent(0.32), alpha: 1)
        // 桌面下的立面 + 抽屉
        let face = NSBezierPath(roundedRect: NSRect(x: w * 0.01, y: 0, width: w * 0.98, height: faceH),
                                xRadius: h * 0.015, yRadius: h * 0.015)
        fill(face, [NSColor(srgbRed: 0.52, green: 0.35, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.40, green: 0.26, blue: 0.18, alpha: 1)])
        let drawer = NSBezierPath(roundedRect: NSRect(x: w * 0.30, y: faceH * 0.18,
                                                      width: w * 0.40, height: faceH * 0.62),
                                  xRadius: h * 0.012, yRadius: h * 0.012)
        fill(drawer, [NSColor(srgbRed: 0.57, green: 0.39, blue: 0.27, alpha: 1),
                      NSColor(srgbRed: 0.45, green: 0.29, blue: 0.20, alpha: 1)])
        let handle = NSBezierPath(roundedRect: NSRect(x: w * 0.44, y: faceH * 0.56,
                                                      width: w * 0.12, height: h * 0.012),
                                  xRadius: h * 0.006, yRadius: h * 0.006)
        fill(handle, [NSColor(srgbRed: 0.88, green: 0.74, blue: 0.55, alpha: 1),
                      NSColor(srgbRed: 0.62, green: 0.46, blue: 0.31, alpha: 1)])
        // 木纹
        NSColor.black.withAlphaComponent(0.05).setStroke()
        for i in 0..<3 {
            let line = NSBezierPath()
            let y = faceH * (0.22 + CGFloat(i) * 0.22)
            line.move(to: NSPoint(x: w * 0.04, y: y))
            line.curve(to: NSPoint(x: w * 0.96, y: y + h * 0.004),
                       controlPoint1: NSPoint(x: w * 0.34, y: y + h * 0.008),
                       controlPoint2: NSPoint(x: w * 0.66, y: y - h * 0.006))
            line.lineWidth = 0.8
            line.stroke()
        }
        // 桌面阴影：让道具“落在”桌上
        let shade = NSBezierPath(rect: NSRect(x: 0, y: topY - h * 0.004, width: w, height: h * 0.006))
        shade.fill(with: NSColor.black.withAlphaComponent(0.14), alpha: 1)
    }

    private func keyboard(_ r: NSRect, rgb: Bool) {
        if rgb {
            let glow = NSRect(x: r.minX - r.width * 0.06, y: r.minY - r.height * 0.45,
                              width: r.width * 1.12, height: r.height * 0.7)
            fillRadial(NSBezierPath(ovalIn: glow),
                       [NSColor(srgbRed: 0.45, green: 0.35, blue: 1, alpha: 0.40),
                        NSColor(srgbRed: 0.20, green: 0.70, blue: 1, alpha: 0.10), .clear])
        }
        contactShadow(x: r.midX, y: r.minY - r.height * 0.16, w: r.width * 1.02, alpha: 0.18)
        let body = NSBezierPath(roundedRect: r, xRadius: r.height * 0.22, yRadius: r.height * 0.22)
        fill(body, [NSColor(srgbRed: 0.30, green: 0.31, blue: 0.36, alpha: 1),
                    NSColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1)])
        let inner = NSBezierPath(roundedRect: r.insetBy(dx: r.width * 0.012, dy: r.height * 0.08),
                                 xRadius: r.height * 0.16, yRadius: r.height * 0.16)
        fill(inner, [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                     NSColor(srgbRed: 0.18, green: 0.19, blue: 0.23, alpha: 1)])
        let rows = 3, cols = 12
        let kw = (r.width * 0.96) / CGFloat(cols)
        let kh = (r.height * 0.66) / CGFloat(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let key = NSRect(
                    x: r.minX + r.width * 0.02 + CGFloat(col) * kw + kw * 0.12,
                    y: r.minY + r.height * 0.17 + CGFloat(row) * kh + kh * 0.12,
                    width: kw * 0.76, height: kh * 0.72
                )
                let cap = NSBezierPath(roundedRect: key, xRadius: kw * 0.14, yRadius: kw * 0.14)
                let tone = rgb
                    ? NSColor(srgbRed: 0.42, green: 0.38, blue: 0.60, alpha: 1)
                    : NSColor(srgbRed: 0.44, green: 0.46, blue: 0.52, alpha: 1)
                fill(cap, [NSColor.white.withAlphaComponent(0.22).blended(withFraction: 0.15, of: tone) ?? tone,
                           tone.blended(withFraction: 0.35, of: .black) ?? tone])
            }
        }
        let lip = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.maxY - r.height * 0.12,
                                                   width: r.width, height: r.height * 0.08),
                               xRadius: r.height * 0.05, yRadius: r.height * 0.05)
        lip.fill(with: NSColor.white.withAlphaComponent(0.10), alpha: 1)
    }

    // MARK: 道具 · 显示器 / 台灯 / 游戏柄

    private func monitor(_ r: NSRect) {
        contactShadow(x: r.midX, y: r.minY - r.height * 0.02, w: r.width * 0.5, alpha: 0.16)
        // 支架
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: r.midX - r.width * 0.05, y: r.minY))
        stand.line(to: NSPoint(x: r.midX - r.width * 0.08, y: r.minY - r.height * 0.10))
        stand.line(to: NSPoint(x: r.midX + r.width * 0.08, y: r.minY - r.height * 0.10))
        stand.line(to: NSPoint(x: r.midX + r.width * 0.05, y: r.minY))
        stand.close()
        fill(stand, [NSColor(white: 0.42, alpha: 1), NSColor(white: 0.24, alpha: 1)])
        let base = NSBezierPath(ovalIn: NSRect(x: r.midX - r.width * 0.16, y: r.minY - r.height * 0.14,
                                               width: r.width * 0.32, height: r.height * 0.07))
        fill(base, [NSColor(white: 0.38, alpha: 1), NSColor(white: 0.20, alpha: 1)])
        // 机身
        shadowed(8, -4, 0.35) {
            let body = NSBezierPath(roundedRect: r, xRadius: r.width * 0.035, yRadius: r.width * 0.035)
            fill(body, [NSColor(white: 0.28, alpha: 1), NSColor(white: 0.10, alpha: 1)])
        }
        let screen = r.insetBy(dx: r.width * 0.035, dy: r.height * 0.06)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: r.width * 0.02, yRadius: r.width * 0.02)
        fill(screenPath, [NSColor(srgbRed: 0.10, green: 0.14, blue: 0.22, alpha: 1),
                          NSColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 1)])
        // 窗口栏
        let bar = NSRect(x: screen.minX + screen.width * 0.06, y: screen.maxY - screen.height * 0.16,
                         width: screen.width * 0.88, height: screen.height * 0.10)
        fill(NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2),
             [NSColor(srgbRed: 0.20, green: 0.25, blue: 0.36, alpha: 1),
              NSColor(srgbRed: 0.14, green: 0.18, blue: 0.27, alpha: 1)])
        for (i, c) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            c.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: bar.minX + bar.width * 0.03 + CGFloat(i) * bar.height * 1.1,
                                        y: bar.midY - bar.height * 0.16,
                                        width: bar.height * 0.32, height: bar.height * 0.32)).fill()
        }
        let colors: [NSColor] = [.systemPink, .systemTeal, .systemYellow, .systemGreen, .systemPurple, .systemTeal]
        for i in 0..<6 {
            colors[i].withAlphaComponent(0.78).setFill()
            let indent = CGFloat([0, 1, 2, 2, 1, 0][i]) * screen.width * 0.07
            let len = screen.width * [0.52, 0.40, 0.60, 0.34, 0.46, 0.28][i]
            NSBezierPath(roundedRect: NSRect(
                x: screen.minX + screen.width * 0.10 + indent,
                y: screen.maxY - screen.height * (0.34 + CGFloat(i) * 0.10),
                width: len, height: screen.height * 0.035
            ), xRadius: 1.5, yRadius: 1.5).fill()
        }
        // 屏幕反光
        let glint = NSBezierPath()
        glint.move(to: NSPoint(x: screen.minX, y: screen.maxY - screen.height * 0.30))
        glint.line(to: NSPoint(x: screen.maxX, y: screen.maxY * 0.82))
        glint.line(to: NSPoint(x: screen.maxX, y: screen.maxY))
        glint.line(to: NSPoint(x: screen.minX + screen.width * 0.3, y: screen.maxY))
        glint.close()
        glint.fill(with: NSColor.white.withAlphaComponent(0.05), alpha: 1)
    }

    private func lamp(base: NSPoint, height: CGFloat) {
        radialGlow(center: NSPoint(x: base.x + height * 0.26, y: base.y + height * 0.62),
                   radius: height * 1.05,
                   color: NSColor(srgbRed: 1, green: 0.84, blue: 0.5, alpha: night ? 0.42 : 0.26))
        contactShadow(x: base.x, y: base.y - height * 0.02, w: height * 0.34, alpha: 0.20)
        let foot = NSBezierPath(ovalIn: NSRect(x: base.x - height * 0.14, y: base.y - height * 0.02,
                                               width: height * 0.28, height: height * 0.05))
        fill(foot, [NSColor(white: 0.34, alpha: 1), NSColor(white: 0.18, alpha: 1)])
        let arm = NSBezierPath()
        arm.move(to: NSPoint(x: base.x, y: base.y + height * 0.02))
        arm.line(to: NSPoint(x: base.x, y: base.y + height * 0.70))
        arm.curve(to: NSPoint(x: base.x + height * 0.24, y: base.y + height * 0.88),
                  controlPoint1: NSPoint(x: base.x, y: base.y + height * 0.84),
                  controlPoint2: NSPoint(x: base.x + height * 0.10, y: base.y + height * 0.88))
        arm.lineWidth = max(2, height * 0.035)
        arm.lineCapStyle = .round
        NSColor(white: 0.30, alpha: 1).setStroke()
        arm.stroke()
        let joint = NSBezierPath(ovalIn: NSRect(x: base.x - height * 0.035, y: base.y + height * 0.66,
                                                width: height * 0.07, height: height * 0.07))
        fill(joint, [NSColor(white: 0.46, alpha: 1), NSColor(white: 0.26, alpha: 1)])
        let tip = NSPoint(x: base.x + height * 0.24, y: base.y + height * 0.88)
        let shade = NSBezierPath()
        shade.move(to: NSPoint(x: tip.x - height * 0.10, y: tip.y + height * 0.07))
        shade.line(to: NSPoint(x: tip.x + height * 0.18, y: tip.y + height * 0.03))
        shade.line(to: NSPoint(x: tip.x + height * 0.12, y: tip.y - height * 0.13))
        shade.line(to: NSPoint(x: tip.x - height * 0.04, y: tip.y - height * 0.10))
        shade.close()
        fill(shade, [NSColor(srgbRed: 1, green: 0.74, blue: 0.36, alpha: 1),
                     NSColor(srgbRed: 0.72, green: 0.42, blue: 0.16, alpha: 1)])
        let inner = NSBezierPath(ovalIn: NSRect(x: tip.x - height * 0.045, y: tip.y - height * 0.11,
                                                width: height * 0.19, height: height * 0.055))
        inner.fill(with: NSColor(white: 1, alpha: night ? 0.95 : 0.8), alpha: 1)
    }

    private func controller(center c: NSPoint, width w: CGFloat) {
        let h = w * 0.46
        let shell = NSBezierPath(roundedRect: NSRect(x: c.x - w * 0.34, y: c.y - h * 0.24,
                                                     width: w * 0.68, height: h * 0.50),
                                 xRadius: h * 0.22, yRadius: h * 0.22)
        shell.append(NSBezierPath(ovalIn: NSRect(x: c.x - w * 0.46, y: c.y - h * 0.44,
                                                 width: w * 0.28, height: h * 0.68)))
        shell.append(NSBezierPath(ovalIn: NSRect(x: c.x + w * 0.18, y: c.y - h * 0.44,
                                                 width: w * 0.28, height: h * 0.68)))
        shadowed(10, -5, 0.38) {
            fill(shell, [NSColor(srgbRed: 0.30, green: 0.30, blue: 0.38, alpha: 1),
                         NSColor(srgbRed: 0.13, green: 0.13, blue: 0.18, alpha: 1)])
        }
        // 顶部高光
        let gloss = NSBezierPath(roundedRect: NSRect(x: c.x - w * 0.26, y: c.y + h * 0.02,
                                                     width: w * 0.52, height: h * 0.16),
                                 xRadius: h * 0.08, yRadius: h * 0.08)
        gloss.fill(with: NSColor.white.withAlphaComponent(0.08), alpha: 1)
        // 摇杆：靠内、实色环 + 浅色帽，避免在深色机身上出现突兀的亮斑
        for dx in [-w * 0.19, w * 0.19] {
            let cx2 = c.x + dx, cy2 = c.y + h * 0.02
            let well = NSBezierPath(ovalIn: NSRect(x: cx2 - w * 0.042, y: cy2 - w * 0.042,
                                                   width: w * 0.084, height: w * 0.084))
            NSColor(white: 0.07, alpha: 1).setFill()
            well.fill()
            let cap = NSBezierPath(ovalIn: NSRect(x: cx2 - w * 0.030, y: cy2 - w * 0.030,
                                                  width: w * 0.060, height: w * 0.060))
            NSColor(white: 0.34, alpha: 1).setFill()
            cap.fill()
            NSColor(white: 0.52, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx2 - w * 0.018, y: cy2 + w * 0.002,
                                        width: w * 0.036, height: w * 0.024)).fill()
        }
        // 十字键
        let dx = c.x - w * 0.24, dy = c.y + h * 0.14
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: dx - w * 0.075, y: dy - w * 0.024,
                                         width: w * 0.15, height: w * 0.048), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: NSRect(x: dx - w * 0.024, y: dy - w * 0.075,
                                         width: w * 0.048, height: w * 0.15), xRadius: 2, yRadius: 2).fill()
        // ABXY
        let bx = c.x + w * 0.24
        for (ox, oy, color) in [(0.0, 0.062, NSColor.systemYellow), (0.062, 0.0, NSColor.systemRed),
                                (0.0, -0.062, NSColor.systemGreen), (-0.062, 0.0, NSColor.systemBlue)] as [(CGFloat, CGFloat, NSColor)] {
            let r = NSRect(x: bx + ox * w - w * 0.028, y: dy + oy * w - w * 0.028,
                           width: w * 0.056, height: w * 0.056)
            fillRadial(NSBezierPath(ovalIn: r), [color.blended(withFraction: 0.35, of: .white) ?? color, color], center: NSPoint(x: 0, y: 0.4))
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.22, dy: r.height * 0.52)).fill()
        }
        // 中央灯条
        let led = NSBezierPath(roundedRect: NSRect(x: c.x - w * 0.06, y: dy + h * 0.16,
                                                   width: w * 0.12, height: h * 0.045),
                               xRadius: 2, yRadius: 2)
        let glowColor = night ? NSColor.systemCyan : NSColor.systemTeal
        shadowed(8, 0, 0.6) { glowColor.withAlphaComponent(0.9).setFill(); led.fill() }
        glowColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - w * 0.14, y: dy + h * 0.10,
                                    width: w * 0.28, height: h * 0.14)).fill()
    }

    // MARK: 道具 · 桌面小物

    private func coffee(w: CGFloat, h: CGFloat) {
        let cx = w * 0.84, base = h * 0.195
        contactShadow(x: cx, y: base, w: w * 0.20, alpha: 0.20)
        let saucer = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.095, y: base, width: w * 0.19, height: h * 0.018))
        fill(saucer, [NSColor(srgbRed: 0.86, green: 0.86, blue: 0.90, alpha: 1),
                      NSColor(srgbRed: 0.62, green: 0.62, blue: 0.68, alpha: 1)])
        // 把手
        let handle = NSBezierPath()
        handle.appendArc(withCenter: NSPoint(x: cx + w * 0.055, y: base + h * 0.045),
                         radius: w * 0.035, startAngle: -70, endAngle: 110)
        handle.lineWidth = w * 0.018
        handle.lineCapStyle = .round
        NSColor(srgbRed: 0.92, green: 0.92, blue: 0.95, alpha: 1).setStroke()
        handle.stroke()
        // 杯身
        let cup = NSBezierPath()
        cup.move(to: NSPoint(x: cx - w * 0.056, y: base + h * 0.014))
        cup.line(to: NSPoint(x: cx - w * 0.066, y: base + h * 0.060))
        cup.curve(to: NSPoint(x: cx + w * 0.066, y: base + h * 0.060),
                  controlPoint1: NSPoint(x: cx - w * 0.03, y: base + h * 0.082),
                  controlPoint2: NSPoint(x: cx + w * 0.03, y: base + h * 0.082))
        cup.line(to: NSPoint(x: cx + w * 0.056, y: base + h * 0.014))
        cup.curve(to: NSPoint(x: cx - w * 0.056, y: base + h * 0.014),
                  controlPoint1: NSPoint(x: cx + w * 0.03, y: base + h * 0.002),
                  controlPoint2: NSPoint(x: cx - w * 0.03, y: base + h * 0.002))
        cup.close()
        fill(cup, [NSColor(white: 0.98, alpha: 1), NSColor(white: 0.80, alpha: 1)])
        let rim = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.066, y: base + h * 0.060,
                                              width: w * 0.132, height: h * 0.024))
        fill(rim, [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.76, alpha: 1)])
        let crema = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.055, y: base + h * 0.063,
                                                width: w * 0.110, height: h * 0.019))
        fillRadial(crema, [NSColor(srgbRed: 0.72, green: 0.50, blue: 0.30, alpha: 1),
                           NSColor(srgbRed: 0.46, green: 0.29, blue: 0.16, alpha: 1)])
        // 高光
        let shine = NSBezierPath(roundedRect: NSRect(x: cx - w * 0.052, y: base + h * 0.024,
                                                     width: w * 0.016, height: h * 0.042),
                                 xRadius: w * 0.008, yRadius: w * 0.008)
        shine.fill(with: NSColor.white.withAlphaComponent(0.65), alpha: 1)
    }

    private func plant(w: CGFloat, h: CGFloat) {
        let cx = w * 0.10, base = h * 0.195
        contactShadow(x: cx, y: base, w: w * 0.20, alpha: 0.18)
        let pot = NSBezierPath()
        pot.move(to: NSPoint(x: cx - w * 0.058, y: base + h * 0.012))
        pot.line(to: NSPoint(x: cx - w * 0.045, y: base + h * 0.075))
        pot.line(to: NSPoint(x: cx + w * 0.045, y: base + h * 0.075))
        pot.line(to: NSPoint(x: cx + w * 0.058, y: base + h * 0.012))
        pot.close()
        fill(pot, [NSColor(srgbRed: 0.80, green: 0.42, blue: 0.30, alpha: 1),
                   NSColor(srgbRed: 0.55, green: 0.25, blue: 0.18, alpha: 1)])
        let rim = NSBezierPath(roundedRect: NSRect(x: cx - w * 0.066, y: base + h * 0.070,
                                                   width: w * 0.132, height: h * 0.020),
                               xRadius: 3, yRadius: 3)
        fill(rim, [NSColor(srgbRed: 0.88, green: 0.50, blue: 0.36, alpha: 1),
                   NSColor(srgbRed: 0.62, green: 0.30, blue: 0.22, alpha: 1)])
        // 叶子
        for (angle, length, tone) in [(-0.55, 0.15, 0.0), (0.10, 0.19, 0.08), (0.65, 0.16, -0.05)] as [(CGFloat, CGFloat, CGFloat)] {
            let tip = NSPoint(x: cx + sin(angle) * w * length,
                              y: base + h * 0.075 + cos(angle) * h * length)
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: cx, y: base + h * 0.08))
            leaf.curve(to: tip,
                       controlPoint1: NSPoint(x: cx - w * 0.06 + sin(angle) * w * 0.05, y: base + h * 0.12),
                       controlPoint2: NSPoint(x: tip.x - w * 0.05, y: tip.y + h * 0.02))
            leaf.curve(to: NSPoint(x: cx, y: base + h * 0.08),
                       controlPoint1: NSPoint(x: tip.x + w * 0.02, y: tip.y - h * 0.03),
                       controlPoint2: NSPoint(x: cx + w * 0.04, y: base + h * 0.11))
            leaf.close()
            let green = NSColor(srgbRed: 0.32 + tone, green: 0.68 + tone, blue: 0.42, alpha: 1)
            fill(leaf, [green.blended(withFraction: 0.35, of: .white) ?? green,
                        green.blended(withFraction: 0.25, of: .black) ?? green], angle: -80)
        }
    }

    private func duck(w: CGFloat, h: CGFloat) {
        let cx = w * 0.88, base = h * 0.195
        contactShadow(x: cx, y: base, w: w * 0.16, alpha: 0.18)
        let body = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.055, y: base + h * 0.006,
                                               width: w * 0.11, height: h * 0.055))
        fillRadial(body, [NSColor(srgbRed: 1, green: 0.92, blue: 0.42, alpha: 1),
                          NSColor(srgbRed: 0.94, green: 0.70, blue: 0.16, alpha: 1)], center: NSPoint(x: 0, y: 0.5))
        let head = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.032, y: base + h * 0.044,
                                               width: w * 0.064, height: h * 0.048))
        fillRadial(head, [NSColor(srgbRed: 1, green: 0.95, blue: 0.52, alpha: 1),
                          NSColor(srgbRed: 0.95, green: 0.74, blue: 0.18, alpha: 1)], center: NSPoint(x: 0, y: 0.5))
        let beak = NSBezierPath(ovalIn: NSRect(x: cx + w * 0.024, y: base + h * 0.058,
                                               width: w * 0.030, height: h * 0.014))
        fill(beak, [NSColor(srgbRed: 1, green: 0.52, blue: 0.20, alpha: 1),
                    NSColor(srgbRed: 0.88, green: 0.36, blue: 0.10, alpha: 1)], angle: 0)
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx + w * 0.006, y: base + h * 0.070,
                                    width: w * 0.008, height: w * 0.008)).fill()
        NSColor.white.withAlphaComponent(0.7).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - w * 0.020, y: base + h * 0.024,
                                    width: w * 0.018, height: h * 0.012)).fill()
    }

    private func phone(center c: NSPoint, size: NSSize) {
        let r = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        shadowed(9, -4, 0.35) {
            let body = NSBezierPath(roundedRect: r, xRadius: size.width * 0.20, yRadius: size.width * 0.20)
            fill(body, [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.08, alpha: 1)])
        }
        let screen = r.insetBy(dx: size.width * 0.07, dy: size.width * 0.09)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: size.width * 0.13, yRadius: size.width * 0.13)
        fill(screenPath, [NSColor(srgbRed: 0.86, green: 0.93, blue: 1, alpha: 1),
                          NSColor(srgbRed: 0.72, green: 0.85, blue: 0.98, alpha: 1)])
        // 灵动岛
        let island = NSBezierPath(roundedRect: NSRect(x: screen.midX - screen.width * 0.14, y: screen.maxY - screen.height * 0.075,
                                                      width: screen.width * 0.28, height: screen.height * 0.030),
                                  xRadius: screen.height * 0.015, yRadius: screen.height * 0.015)
        island.fill(with: NSColor(white: 0.08, alpha: 0.95), alpha: 1)
        // 对话气泡
        let bubbles: [(CGFloat, NSColor, CGFloat)] = [
            (0.82, NSColor.white, 0.66), (0.66, NSColor.systemGreen.withAlphaComponent(0.85), 0.54),
            (0.50, NSColor.white, 0.60), (0.34, NSColor.systemGreen.withAlphaComponent(0.85), 0.44),
        ]
        for (i, (y, color, widthFactor)) in bubbles.enumerated() {
            let bw = screen.width * widthFactor
            let x = i % 2 == 0 ? screen.minX + screen.width * 0.08 : screen.maxX - bw - screen.width * 0.08
            let bubble = NSBezierPath(roundedRect: NSRect(x: x, y: screen.maxY - screen.height * y,
                                                          width: bw, height: screen.height * 0.11),
                                      xRadius: screen.width * 0.09, yRadius: screen.width * 0.09)
            color.withAlphaComponent(i % 2 == 0 ? 0.95 : 0.9).setFill()
            bubble.fill()
        }
        // 输入条
        let bar = NSBezierPath(roundedRect: NSRect(x: screen.minX + screen.width * 0.08,
                                                   y: screen.minY + screen.height * 0.05,
                                                   width: screen.width * 0.84, height: screen.height * 0.08),
                               xRadius: screen.width * 0.05, yRadius: screen.width * 0.05)
        bar.fill(with: NSColor.white.withAlphaComponent(0.85), alpha: 1)
    }

    private func tablet(_ r: NSRect) {
        contactShadow(x: r.midX, y: r.minY - r.height * 0.12, w: r.width * 0.9, alpha: 0.14)
        let body = NSBezierPath(roundedRect: r, xRadius: r.height * 0.28, yRadius: r.height * 0.28)
        fill(body, [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.12, alpha: 1)])
        let canvas = r.insetBy(dx: r.height * 0.14, dy: r.height * 0.16)
        fill(NSBezierPath(roundedRect: canvas, xRadius: r.height * 0.12, yRadius: r.height * 0.12),
             [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.88, alpha: 1)])
        for (i, color) in [NSColor.systemPink, NSColor.systemTeal, NSColor.systemYellow, NSColor.systemPurple].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: canvas.minX + canvas.width * (0.08 + CGFloat(i) * 0.11),
                                        y: canvas.midY - canvas.height * 0.10,
                                        width: canvas.height * 0.20, height: canvas.height * 0.20)).fill()
        }
        let stroke = NSBezierPath()
        stroke.move(to: NSPoint(x: canvas.minX + canvas.width * 0.08, y: canvas.minY + canvas.height * 0.22))
        stroke.curve(to: NSPoint(x: canvas.maxX - canvas.width * 0.10, y: canvas.minY + canvas.height * 0.42),
                     controlPoint1: NSPoint(x: canvas.midX - canvas.width * 0.16, y: canvas.minY + canvas.height * 0.55),
                     controlPoint2: NSPoint(x: canvas.midX + canvas.width * 0.16, y: canvas.minY + canvas.height * 0.10))
        stroke.lineWidth = max(1.4, canvas.height * 0.06)
        stroke.lineCapStyle = .round
        NSColor(white: 0.24, alpha: 0.85).setStroke()
        stroke.stroke()
        // 触控笔
        let pen = NSBezierPath()
        pen.move(to: NSPoint(x: r.maxX - r.width * 0.04, y: r.maxY + r.height * 1.10))
        pen.line(to: NSPoint(x: r.maxX - r.width * 0.26, y: r.midY))
        pen.lineWidth = max(2.4, r.height * 0.10)
        pen.lineCapStyle = .round
        NSColor(white: 0.92, alpha: 1).setStroke()
        pen.stroke()
        pen.lineWidth = max(1.0, r.height * 0.045)
        NSColor(white: 0.35, alpha: 1).setStroke()
        pen.stroke()
    }

    // MARK: 道具 · 耳机 / 爆米花 / 饮料 / 书 / 调色盘

    private func headphones(w: CGFloat, h: CGFloat) {
        let cx = w * 0.84, base = h * 0.20
        contactShadow(x: cx, y: base, w: w * 0.22, alpha: 0.16)
        let band = NSBezierPath()
        band.appendArc(withCenter: NSPoint(x: cx, y: base + h * 0.055), radius: w * 0.085,
                       startAngle: 20, endAngle: 160)
        band.lineWidth = max(3, w * 0.022)
        band.lineCapStyle = .round
        NSColor(white: 0.18, alpha: 1).setStroke()
        band.stroke()
        band.lineWidth = max(1, w * 0.008)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        band.stroke()
        for dx in [-w * 0.078, w * 0.078] {
            let cupRect = NSRect(x: cx + dx - w * 0.032, y: base + h * 0.012,
                                 width: w * 0.064, height: h * 0.075)
            let cup = NSBezierPath(roundedRect: cupRect, xRadius: w * 0.026, yRadius: w * 0.026)
            fill(cup, [NSColor(srgbRed: 0.34, green: 0.34, blue: 0.40, alpha: 1),
                       NSColor(srgbRed: 0.16, green: 0.16, blue: 0.20, alpha: 1)])
            let cushion = NSBezierPath(roundedRect: cupRect.insetBy(dx: w * 0.014, dy: h * 0.012),
                                       xRadius: w * 0.016, yRadius: w * 0.016)
            fill(cushion, [NSColor(srgbRed: 0.24, green: 0.24, blue: 0.30, alpha: 1),
                           NSColor(srgbRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)])
            NSColor(srgbRed: 1, green: 0.45, blue: 0.72, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: cupRect.midX - w * 0.006, y: cupRect.midY - w * 0.006,
                                        width: w * 0.012, height: w * 0.012)).fill()
        }
    }

    private func popcorn(w: CGFloat, h: CGFloat) {
        let cx = w * 0.84, base = h * 0.195
        contactShadow(x: cx, y: base, w: w * 0.20, alpha: 0.18)
        let bucket = NSBezierPath()
        bucket.move(to: NSPoint(x: cx - w * 0.060, y: base + h * 0.006))
        bucket.line(to: NSPoint(x: cx - w * 0.078, y: base + h * 0.088))
        bucket.line(to: NSPoint(x: cx + w * 0.078, y: base + h * 0.088))
        bucket.line(to: NSPoint(x: cx + w * 0.060, y: base + h * 0.006))
        bucket.close()
        bucket.fill(with: NSColor(srgbRed: 0.88, green: 0.22, blue: 0.24, alpha: 1), alpha: 1)
        // 白色条纹
        NSColor(white: 1, alpha: 0.9).setFill()
        for i in 0..<3 {
            let x = cx - w * 0.040 + CGFloat(i) * w * 0.040
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: x, y: base + h * 0.008))
            stripe.line(to: NSPoint(x: x - w * 0.004, y: base + h * 0.086))
            stripe.line(to: NSPoint(x: x + w * 0.012, y: base + h * 0.086))
            stripe.line(to: NSPoint(x: x + w * 0.016, y: base + h * 0.008))
            stripe.close()
            stripe.fill()
        }
        // 桶口与爆米花
        let rim = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.080, y: base + h * 0.078,
                                              width: w * 0.160, height: h * 0.022))
        rim.fill(with: NSColor(srgbRed: 0.72, green: 0.14, blue: 0.16, alpha: 1), alpha: 1)
        for (dx, dy, s) in [(-0.045, 0.098, 0.020), (-0.012, 0.106, 0.018), (0.022, 0.100, 0.019),
                            (0.048, 0.092, 0.016), (-0.028, 0.090, 0.017), (0.006, 0.088, 0.015)] as [(CGFloat, CGFloat, CGFloat)] {
            let kernel = NSRect(x: cx + w * dx - w * s * 0.5, y: base + h * dy,
                                width: w * s, height: w * s)
            fillRadial(NSBezierPath(ovalIn: kernel),
                       [NSColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 1),
                        NSColor(srgbRed: 0.92, green: 0.82, blue: 0.58, alpha: 1)], center: NSPoint(x: 0, y: 0.5))
        }
    }

    private func drink(w: CGFloat, h: CGFloat) {
        let cx = w * 0.16, base = h * 0.195
        contactShadow(x: cx, y: base, w: w * 0.16, alpha: 0.18)
        let cup = NSBezierPath()
        cup.move(to: NSPoint(x: cx - w * 0.046, y: base + h * 0.008))
        cup.line(to: NSPoint(x: cx - w * 0.058, y: base + h * 0.098))
        cup.line(to: NSPoint(x: cx + w * 0.058, y: base + h * 0.098))
        cup.line(to: NSPoint(x: cx + w * 0.046, y: base + h * 0.008))
        cup.close()
        fill(cup, [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.84, alpha: 1)])
        // 液体按杯形裁剪，别从杯壁露出来
        NSGraphicsContext.current?.saveGraphicsState()
        cup.addClip()
        let liquid = NSBezierPath(rect: NSRect(x: cx - w * 0.070, y: base + h * 0.008,
                                               width: w * 0.14, height: h * 0.052))
        fill(liquid, [NSColor(srgbRed: 0.45, green: 0.22, blue: 0.13, alpha: 1),
                      NSColor(srgbRed: 0.26, green: 0.11, blue: 0.07, alpha: 1)])
        NSGraphicsContext.current?.restoreGraphicsState()
        let lid = NSBezierPath(roundedRect: NSRect(x: cx - w * 0.062, y: base + h * 0.092,
                                                   width: w * 0.124, height: h * 0.014),
                               xRadius: 3, yRadius: 3)
        lid.fill(with: NSColor(white: 0.94, alpha: 1), alpha: 1)
        let straw = NSBezierPath()
        straw.move(to: NSPoint(x: cx + w * 0.008, y: base + h * 0.100))
        straw.line(to: NSPoint(x: cx + w * 0.028, y: base + h * 0.150))
        straw.lineWidth = max(1.6, w * 0.010)
        straw.lineCapStyle = .round
        NSColor(srgbRed: 0.95, green: 0.40, blue: 0.42, alpha: 1).setStroke()
        straw.stroke()
    }

    private func book(w: CGFloat, h: CGFloat) {
        let cx = w * 0.5, base = h * 0.22
        let left = NSBezierPath()
        left.move(to: NSPoint(x: cx, y: base))
        left.curve(to: NSPoint(x: cx - w * 0.24, y: base + h * 0.045),
                   controlPoint1: NSPoint(x: cx - w * 0.08, y: base + h * 0.012),
                   controlPoint2: NSPoint(x: cx - w * 0.16, y: base + h * 0.030))
        left.line(to: NSPoint(x: cx - w * 0.22, y: base + h * 0.105))
        left.curve(to: NSPoint(x: cx, y: base + h * 0.075),
                   controlPoint1: NSPoint(x: cx - w * 0.14, y: base + h * 0.105),
                   controlPoint2: NSPoint(x: cx - w * 0.06, y: base + h * 0.090))
        left.close()
        fill(left, [NSColor(srgbRed: 1, green: 0.99, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.90, green: 0.87, blue: 0.80, alpha: 1)])
        let right = NSBezierPath()
        right.move(to: NSPoint(x: cx, y: base))
        right.curve(to: NSPoint(x: cx + w * 0.24, y: base + h * 0.045),
                    controlPoint1: NSPoint(x: cx + w * 0.08, y: base + h * 0.012),
                    controlPoint2: NSPoint(x: cx + w * 0.16, y: base + h * 0.030))
        right.line(to: NSPoint(x: cx + w * 0.22, y: base + h * 0.105))
        right.curve(to: NSPoint(x: cx, y: base + h * 0.075),
                    controlPoint1: NSPoint(x: cx + w * 0.14, y: base + h * 0.105),
                    controlPoint2: NSPoint(x: cx + w * 0.06, y: base + h * 0.090))
        right.close()
        fill(right, [NSColor(srgbRed: 1, green: 0.99, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.86, green: 0.83, blue: 0.76, alpha: 1)])
        // 装订
        let spine = NSBezierPath(roundedRect: NSRect(x: cx - w * 0.008, y: base, width: w * 0.016, height: h * 0.078),
                                 xRadius: 2, yRadius: 2)
        spine.fill(with: NSColor(srgbRed: 0.72, green: 0.38, blue: 0.30, alpha: 1), alpha: 1)
        // 文字线
        NSColor(white: 0.55, alpha: 0.35).setStroke()
        for i in 0..<4 {
            for side in [-1.0, 1.0] {
                let line = NSBezierPath()
                let y = base + h * (0.045 + CGFloat(i) * 0.012)
                line.move(to: NSPoint(x: cx + CGFloat(side) * w * 0.035, y: y))
                line.line(to: NSPoint(x: cx + CGFloat(side) * w * (0.16 - CGFloat(i) * 0.012), y: y + h * 0.006))
                line.lineWidth = 1
                line.stroke()
            }
        }
    }

    private func palette(w: CGFloat, h: CGFloat) {
        let cx = w * 0.13, base = h * 0.20
        contactShadow(x: cx, y: base, w: w * 0.18, alpha: 0.14)
        let board = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.075, y: base + h * 0.006,
                                                width: w * 0.15, height: h * 0.070))
        fill(board, [NSColor(srgbRed: 0.86, green: 0.72, blue: 0.55, alpha: 1),
                     NSColor(srgbRed: 0.66, green: 0.48, blue: 0.32, alpha: 1)])
        let hole = NSBezierPath(ovalIn: NSRect(x: cx + w * 0.012, y: base + h * 0.030,
                                               width: w * 0.028, height: h * 0.020))
        hole.fill(with: NSColor(white: 0.93, alpha: 1), alpha: 1)
        for (i, color) in [NSColor.systemPink, NSColor.systemYellow, NSColor.systemTeal, NSColor.systemPurple, NSColor.systemOrange].enumerated() {
            color.setFill()
            let a = CGFloat(i) * 0.7
            NSBezierPath(ovalIn: NSRect(x: cx - w * 0.055 + cos(a) * w * 0.038,
                                        y: base + h * 0.030 + sin(a) * h * 0.018,
                                        width: w * 0.020, height: h * 0.016)).fill()
        }
        let brush = NSBezierPath()
        brush.move(to: NSPoint(x: cx + w * 0.060, y: base + h * 0.070))
        brush.line(to: NSPoint(x: cx + w * 0.120, y: base + h * 0.170))
        brush.lineWidth = max(2, w * 0.014)
        brush.lineCapStyle = .round
        NSColor(srgbRed: 0.78, green: 0.56, blue: 0.34, alpha: 1).setStroke()
        brush.stroke()
        brush.lineWidth = max(1.2, w * 0.008)
        NSColor(white: 0.90, alpha: 1).setStroke()
        brush.stroke()
    }

    private func equalizerBase(w: CGFloat, h: CGFloat) {
        let base = NSBezierPath(roundedRect: NSRect(x: w * 0.17, y: h * 0.008, width: w * 0.66, height: h * 0.018),
                                xRadius: 4, yRadius: 4)
        fill(base, [NSColor(white: 0.26, alpha: 0.55), NSColor(white: 0.10, alpha: 0.35)])
    }
}