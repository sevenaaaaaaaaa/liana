import AppKit
import Carbon
import QuartzCore

/// 桌宠 v2：内置玻璃小猫 + 社区形象包（声明式数据包，零代码执行）。
///
/// 形象包 pet.json 形如：
/// {"size":96,
///  "states":{"idle":"idle.png","composing":"typing.png","commit":"happy.png"},
///  "follow_cursor":true,"typing_bounce":true,"commit_particles":"spark"}
///
/// 特效：打字跟随（组字时每次按键轻微弹动）、上屏礼花、鼠标追踪
/// （身体朝光标方向轻微倾斜——用 NSEvent.mouseLocation 轮询，不需要任何系统权限）。
final class PetWindowController {
    enum State: String {
        case idle
        case composing
        case commit
    }

    static let shared = PetWindowController()
    private static let enabledKey = "LianaPetEnabled"
    private static let originKey = "LianaPetOrigin"
    private static let packKey = "LianaPetPackId"
    private static let emojiKey = "LianaPetEmoji"
    private static let framingKey = "LianaPetFraming"
    private static let zoomKey = "LianaPetZoom"

    /// 画幅：full（全身）/ bust（半身），菜单可改，覆盖形象包默认
    static var framingOverride: String {
        get { UserDefaults.standard.string(forKey: framingKey) ?? "full" }
        set { UserDefaults.standard.set(newValue, forKey: framingKey); shared.rebuild() }
    }

    /// 缩放：0.8 / 1.0 / 1.25 / 1.5
    static var zoomOverride: Double {
        get { UserDefaults.standard.object(forKey: zoomKey) as? Double ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: zoomKey); shared.rebuild() }
    }

    /// 内置 emoji 形象（未选形象包时使用）。默认女孩。
    static var builtinEmoji: String {
        get { UserDefaults.standard.string(forKey: emojiKey) ?? "👧" }
        set {
            UserDefaults.standard.set(newValue, forKey: emojiKey)
            // emoji 形象与形象包互斥：清掉形象包
            UserDefaults.standard.set("", forKey: packKey)
            shared.rebuild()
            if isEnabled {
                shared.show()
            }
        }
    }

    private static let quietKey = "LianaPetQuiet"
    private static let breakReminderKey = "LianaPetBreakReminder"
    private static let hintCountKey = "LianaPetHintCount"

    /// 安静模式：桌宠不主动说话（问候/闲聊/打盹台词），只回应用户的直接互动。
    static var quietMode: Bool {
        get { UserDefaults.standard.bool(forKey: quietKey) }
        set { UserDefaults.standard.set(newValue, forKey: quietKey) }
    }

    /// 休息提醒：连续打字超过 `breakMinutes` 分钟时提醒起身活动（默认开）。
    static var breakReminder: Bool {
        get { UserDefaults.standard.object(forKey: breakReminderKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: breakReminderKey) }
    }

    static let breakMinutes = 50

    private static let roamKey = "LianaPetRoam"
    /// 允许纸偶形象偶尔在屏幕底边溜达（会移动窗口，默认关）。
    static var roamEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: roamKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: roamKey)
            shared.rebuild()
        }
    }

    static var isEnabled: Bool {
        // 默认开启：仅当用户显式关过（键已存在且为 false）时才关闭。
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 激活的形象包 id；"" = 内置 emoji 形象。未显式选择时按首选渲染器解析（默认 live2d）。
    static var activePackId: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: packKey) { return stored }
            return resolvedDefaultPackId()
        }
        set {
            NSLog("松萝桌宠: 切换形象包 → \(newValue)")
            UserDefaults.standard.set(newValue, forKey: packKey)
            shared.rebuild()
            if isEnabled {
                shared.show()
            }
        }
    }

    private static let rendererKey = "LianaPetRenderer"
    /// 首选渲染器：live2d（默认）/ vrm / emoji。仅在用户未显式选择形象包时生效。
    static var preferredRenderer: String {
        get { UserDefaults.standard.string(forKey: rendererKey) ?? "live2d" }
        set {
            UserDefaults.standard.set(newValue, forKey: rendererKey)
            shared.rebuild()
        }
    }

    /// 默认形象包解析（未显式选择时）：首选 live2d 且已装 live2d 包 → 用之；否则内置 VRM 样例。
    static func resolvedDefaultPackId() -> String {
        if preferredRenderer == "live2d", let id = firstLive2DPackId() { return id }
        return "pet-vrm-sample"
    }

    /// 扫描已安装形象包中第一个 renderer=live2d 的（读 pet.json）。
    private static func firstLive2DPackId() -> String? {
        for pack in availablePets() {
            let pet = PluginStore.pluginsDir
                .appendingPathComponent(pack.id, isDirectory: true)
                .appendingPathComponent("pet.json")
            if let data = try? Data(contentsOf: pet),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["renderer"] as? String) == "live2d" {
                return pack.id
            }
        }
        return nil
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            shared.show()
        } else {
            shared.hide()
            PetChatController.shared.close()
        }
        PetChatAutoTrigger.shared.refresh()
    }

    static func restoreIfEnabled() {
        guard isEnabled else { return }
        shared.show()
        PetChatAutoTrigger.shared.refresh()
    }

    /// 扫描社区形象包。
    static func availablePets() -> [PluginCatalog.Pack] {
        PluginStore.packs(kind: "pet", in: PluginStore.scan())
    }

    private var panel: NSPanel?
    private let face = NSTextField(labelWithString: "👧")
    private var imageView: NSImageView?
    private var emojiLabel: NSTextField?
    private var propLabel: NSTextField?
    private var unsupportedRenderer: String?
    private var petView: PetWebView?
    private var gazeTick = 0
    /// 最后一次输入/互动时间：长时间无输入就让桌宠发呆睡着
    private var lastActivity = Date()
    private var greetedPeriod = ""
    private var particleEmitter: CAEmitterLayer?
    private var resetWorkItem: DispatchWorkItem?
    private var modeButton: PetQuickButton?
    private var statsButton: PetQuickButton?
    private var chatButton: PetQuickButton?
    /// 形象包名字（聊天时的称呼）
    private(set) var petName = "小松"
    /// 鼠标追踪：30fps 轮询（无权限需求），只在包声明 follow_cursor 时启动。
    private var mouseTimer: Timer?
    /// 生活节律：1Hz，与渲染器无关（打盹 / 问候 / 休息提醒 / 心情），emoji 与图片形象同样生效。
    private var lifeTimer: Timer?
    private var sleepy = false
    private var zzzLabel: NSTextField?
    private var groundShadow: CAGradientLayer?
    /// 连续打字段：段内相邻输入间隔 < 5 分钟；超过 breakMinutes 提醒一次
    private var sessionStart: Date?
    private var breakReminded = false
    /// 最近一次用户直接互动（点按/戳/拖动/菜单）：安静模式下仍允许这之后的回应台词
    private var lastUserTouch = Date.distantPast
    private var lastMilestone = 0
    private var lastMood = -1
    /// 形象包自定义的台词（纸偶 pet.json 的 puppet.lines），情绪事件优先用它
    private var packLines: [String: [String]] = [:]
    private var emoteLabel: NSTextField?
    private var emoteWork: DispatchWorkItem?
    private var shakeTimer: Timer?
    private var shakeSamples: [(t: CFTimeInterval, x: CGFloat)] = []
    private var hovering = false
    private var stareWork: DispatchWorkItem?
    /// 持续姿态：cover（输入密码捂眼）/ listen（语音倾听）
    private var holds: Set<String> = []
    private var secureSince: Date?
    private var secureIgnored = false
    private var voiceListening = false
    private var voiceHeardAny = false
    private var lastVoiceNod = Date.distantPast
    private var pollTick = 0
    private var dragSamples: [(t: CFTimeInterval, p: NSPoint)] = []
    private var dragStarted = Date()
    private var dragWork: DispatchWorkItem?
    private var lastModeChinese: Bool?

    private struct PetPack {
        var size: CGFloat = 84
        var fps: Double = 6
        /// 分状态帧率：idle 慢（省电）、typing 快（跟手）。缺省从 fps 推导。
        var idleFps: Double = 3
        var typingFps: Double = 9
        /// 帧动画：idle 闲时小动作 / typing 敲击乐器 / commit 上屏开心。单图包退化为单帧。
        var idle: [NSImage] = []
        var typing: [NSImage] = []
        var commit: [NSImage] = []
        var followCursor = false
        var typingBounce = true
        var commitParticles = true
        /// emoji 角色：用系统 emoji 作为形象（`emoji` + 可选 `prop` 道具）
        var emoji: String?
        var prop: String?
        /// 渲染器：emoji | sprites | rive | live2d | vrm | puppet（见 ADR-0007 / ADR-0011）
        var renderer: String = "emoji"
        var entry: String?
        /// 画幅（宽×高）；缺省用 size 正方形
        var width: CGFloat?
        var height: CGFloat?
        /// 构图：full（全身，默认）/ bust（半身）
        var framing: String = "full"
        var zoom: Double = 1.0
        /// Live2D 专属：模型整体缩放（构图微调，独立于用户 zoom）
        var scale: Double = 1.0

        static func load(dir: URL) -> PetPack? {
            guard
                let data = try? Data(contentsOf: dir.appendingPathComponent("pet.json")),
                let json = try? JSONDecoder().decode(PetFile.self, from: data)
            else { return nil }
            func images(_ names: [String]?) -> [NSImage] {
                (names ?? []).compactMap { name in
                    name.isEmpty ? nil : NSImage(contentsOf: dir.appendingPathComponent(name))
                }
            }
            func image(_ name: String?) -> NSImage? {
                guard let name, !name.isEmpty else { return nil }
                return NSImage(contentsOf: dir.appendingPathComponent(name))
            }
            var pack = PetPack()
            if let size = json.size, size >= 48, size <= 256 { pack.size = CGFloat(size) }
            if let fps = json.fps, fps >= 1, fps <= 30 { pack.fps = fps }
            pack.idleFps = max(2, pack.fps / 2)
            pack.typingFps = max(pack.fps, 9)
            if let v = json.fps_idle, v >= 1, v <= 30 { pack.idleFps = v }
            if let v = json.fps_typing, v >= 1, v <= 30 { pack.typingFps = v }
            // 帧数组优先；缺省回落到单图 states
            pack.idle = images(json.frames?.idle)
            pack.typing = images(json.frames?.typing)
            pack.commit = images(json.frames?.commit)
            if let singleIdle = image(json.states?.idle) {
                if pack.idle.isEmpty { pack.idle = [singleIdle] }
                if pack.typing.isEmpty { pack.typing = [image(json.states?.composing) ?? singleIdle] }
                if pack.commit.isEmpty { pack.commit = [image(json.states?.commit) ?? singleIdle] }
            }
            pack.followCursor = json.follow_cursor ?? false
            pack.typingBounce = json.typing_bounce ?? true
            pack.commitParticles = json.commit_particles ?? true
            if let e = json.emoji, !e.isEmpty { pack.emoji = e }
            if let p = json.prop, !p.isEmpty { pack.prop = p }
            if let r = json.renderer, !r.isEmpty { pack.renderer = r }
            pack.entry = json.entry
            if let w = json.width, w >= 100, w <= 600 { pack.width = CGFloat(w) }
            if let h = json.height, h >= 100, h <= 800 { pack.height = CGFloat(h) }
            if let f = json.framing, !f.isEmpty { pack.framing = f }
            if let z = json.zoom, z >= 0.4, z <= 2.0 { pack.zoom = z }
            if let sc = json.scale, sc >= 0.4, sc <= 2.0 { pack.scale = sc }
            if pack.renderer == "emoji" && pack.emoji == nil && !pack.idle.isEmpty {
                pack.renderer = "sprites"
            }
            // 可用性：有帧图 / 有 emoji / 或声明了独立渲染器（vrm/live2d/rive）
            let usable = !pack.idle.isEmpty || pack.emoji != nil
                || ["vrm", "live2d", "rive", "puppet"].contains(pack.renderer)
            return usable ? pack : nil
        }

        struct PetFile: Codable {
            var size: Double?
            var fps: Double?
            var fps_idle: Double?
            var fps_typing: Double?
            var states: StateFiles?
            var frames: FrameFiles?
            var follow_cursor: Bool?
            var typing_bounce: Bool?
            var commit_particles: Bool?
            var emoji: String?
            var prop: String?
            var renderer: String?
            var entry: String?
            var width: Double?
            var height: Double?
            var framing: String?
            var zoom: Double?
            var scale: Double?

            struct StateFiles: Codable {
                var idle: String?
                var composing: String?
                var commit: String?
            }

            struct FrameFiles: Codable {
                var idle: [String]?
                var typing: [String]?
                var commit: [String]?
            }
        }
    }

    private var pack: PetPack?

    private init() {}

    private func loadPack() {
        let id = Self.activePackId
        guard !id.isEmpty else {
            pack = nil
            return
        }
        let dir = PluginStore.pluginsDir.appendingPathComponent(id, isDirectory: true)
        pack = PetPack.load(dir: dir)
        packLines = [:]
        petName = "小松"
        if let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
           let plugin = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = plugin["name"] as? String, !name.isEmpty, name.count <= 12 {
            petName = name
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("pet.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lines = (json["puppet"] as? [String: Any])?["lines"] as? [String: Any] {
            for (key, value) in lines {
                if let list = value as? [String], !list.isEmpty { packLines[key] = list }
            }
        }
    }

    /// 形象包切换 / 数据目录变化时重建窗口内容。
    func rebuild() {
        stopMouseTracking()
        stopAnimTimer()
        panel?.orderOut(nil)
        self.panel = nil
        imageView = nil
        emojiLabel = nil
        propLabel = nil
        petView = nil
        unsupportedRenderer = nil
        particleEmitter = nil
        zzzLabel = nil
        groundShadow = nil
        sleepy = false
        loadPack()
        if Self.isEnabled {
            show()
        }
    }

    func show() {
        if panel == nil {
            loadPack()
            panel = makePanel()
            restoreOrigin()
        }
        panel?.orderFrontRegardless()
        startMouseTrackingIfNeeded()
        startAnimTimerIfNeeded()
        startLifeTimer()
        react(.idle)
        lastMood = -1
        lastMilestone = Self.milestone(for: PetStats.shared.today.chars)
        refreshMood()
        greetedPeriod = ""
        if let renderer = unsupportedRenderer {
            showToast("该形象包需要 \(renderer.uppercased()) 渲染器（尚未接入，见 ADR-0007）", duration: 5)
        }
    }

    func hide() {
        stopMouseTracking()
        stopAnimTimer()
        lifeTimer?.invalidate()
        lifeTimer = nil
        shakeTimer?.invalidate()
        shakeTimer = nil
        hideToast()
        panel?.orderOut(nil)
    }

    /// 开发用：把当前桌宠渲染为 PNG（离屏快照，便于检查形象与排版）。
    func snapshot(to path: String) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 今天的输入量 → 心情等级 0..3（仅本机统计，不上传）。
    private static func moodLevel(chars: Int) -> Int {
        switch chars {
        case ..<200: return 0
        case ..<1_000: return 1
        case ..<5_000: return 2
        default: return 3
        }
    }

    /// 当日字数里程碑：跨过时庆祝一次。
    private static let milestones = [1_000, 3_000, 5_000, 10_000, 20_000]

    private static func milestone(for chars: Int) -> Int {
        milestones.last(where: { chars >= $0 }) ?? 0
    }

    private func refreshMood() {
        let level = Self.moodLevel(chars: PetStats.shared.today.chars)
        guard level != lastMood else { return }
        lastMood = level
        petView?.setMood(level)
    }

    /// 上屏后检查当日字数里程碑。
    private func checkMilestone() {
        let chars = PetStats.shared.today.chars
        let reached = Self.milestone(for: chars)
        // 跨过午夜，当日计数归零：里程碑跟着重来
        if reached < lastMilestone { lastMilestone = reached }
        guard reached > lastMilestone else { return }
        lastMilestone = reached
        refreshMood()
        emitSparks(hearts: true)
        petView?.trigger("milestone")
        showToast("🎉 今天已经输入 \(reached.formatted()) 字啦！", duration: 4)
    }

    /// 按时间段问候（每天每段只问候一次；VRM 走页面台词，其他渲染器用气泡）。
    private func greetIfNeeded() {
        let hour = Calendar.current.component(.hour, from: Date())
        let period = hour < 11 ? "morning" : (hour < 18 ? "afternoon" : "evening")
        guard period != greetedPeriod else { return }
        greetedPeriod = period
        guard !Self.quietMode else { return }
        if let petView {
            petView.greet(period)
        } else {
            let text = period == "morning" ? "早上好呀" : (period == "afternoon" ? "下午好" : "晚上好")
            showToast(text, duration: 3.5)
        }
    }

    /// 页面（VRM/Live2D）主动说话：安静模式下只放行用户刚互动后的回应。
    func pageSays(_ line: String) {
        if Self.quietMode, Date().timeIntervalSince(lastUserTouch) > 2.5 { return }
        showToast(line, duration: 3.5)
    }

    /// 庆祝特效（供 WebKit 页面上报 hearts / sparks 时调用）。
    func celebrate(hearts: Bool = true) {
        emitSparks(hearts: hearts)
    }

    /// 纸偶溜达：沿水平方向平移若干个身位（夹在当前屏幕内）。
    func walk(byWidths widths: Double, duration: Double) {
        guard let panel, panel.isVisible, Self.roamEnabled else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var x = panel.frame.minX + CGFloat(widths) * panel.frame.width
        x = min(max(x, visible.minX), visible.maxX - panel.frame.width)
        guard abs(x - panel.frame.minX) > 4 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = max(0.4, min(6, duration))
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            panel.animator().setFrameOrigin(NSPoint(x: x, y: panel.frame.minY))
        }
    }

    // MARK: - 生活节律（打盹 / 问候 / 休息提醒）

    private func startLifeTimer() {
        if shakeTimer == nil {
            // 30Hz 只读鼠标坐标（不需要任何权限），光标不在桌宠附近时几乎不做事
            let shake = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.shakeTick() }
            RunLoop.main.add(shake, forMode: .common)
            shakeTimer = shake
        }
        guard lifeTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.lifeTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        lifeTimer = timer
    }

    // MARK: - 情感互动（PetEmotion 判断情绪，这里负责表现）

    /// 执行一个情绪事件：纸偶播对应动作（动作自己带情绪符号），其他形象由这里冒情绪符号；再说一句话。
    func perform(_ event: PetEmotion.Event) {
        petView?.trigger(event.trigger)
        if pack?.renderer != "puppet", let emote = event.emote {
            showEmote(emote)
            if event.trigger == "love" { emitSparks(hearts: true) }
        }
        guard !(event.proactive && Self.quietMode) else { return }
        if let line = packLines[event.trigger]?.randomElement() ?? event.line {
            showToast(line, duration: 3.5)
        }
    }

    /// 头顶冒一个情绪符号（💢 ❤️ 💧 ✨ …）：弹出、上浮、淡出。
    func showEmote(_ emote: String) {
        guard let host = panel?.contentView else { return }
        let label = emoteLabel ?? {
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: max(18, host.bounds.width * 0.14))
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: host.centerXAnchor, constant: host.bounds.width * 0.22),
                l.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
            ])
            emoteLabel = l
            return l
        }()
        label.stringValue = String(emote.prefix(4))
        label.isHidden = false
        label.alphaValue = 1
        label.wantsLayer = true
        if let layer = label.layer {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.2, 1.3, 0.95, 1.0]
            pop.duration = 0.35
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0
            rise.toValue = 8
            rise.duration = 1.6
            layer.add(pop, forKey: "pop")
            layer.add(rise, forKey: "rise")
        }
        emoteWork?.cancel()
        let work = DispatchWorkItem { [weak label] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; label?.animator().alphaValue = 0 },
                                                completionHandler: { label?.isHidden = true })
        }
        emoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: - 复制即动作的表现

    /// 复制了命令 / 链接：桌宠抬头看一眼
    func clipNoticed(emote: String) {
        guard panel?.isVisible == true else { return }
        petView?.trigger("tap_miss")
        showEmote(emote)
    }

    func linkTaskStarted(_ line: String) {
        setHold("listen", true)
        showEmote("🔍")
        showToast(line, duration: 3)
    }

    func linkTaskFinished(ok: Bool, line: String?) {
        setHold("listen", false)
        petView?.trigger(ok ? "voice_done" : "lonely")
        showEmote(ok ? "✅" : "💦")
        if let line { showToast(line, duration: 5) }
    }

    // MARK: - 聊天时的表现

    var petFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    func petSpeak(seconds: Double) {
        petView?.speak(seconds: seconds)
    }

    func chatOpened() {
        lastUserTouch = Date()
        PetEmotion.shared.touched()
        markActive(typing: false)
        petView?.trigger("chat")
    }

    func chatHeard() {
        PetInteraction.shared.noteInteraction()
        petView?.trigger("chat")
    }

    func chatReplied(_ reply: PetChatBrain.Reply) {
        if let action = reply.action {
            petView?.play(action)
        } else if let trigger = reply.trigger {
            petView?.trigger(trigger)
        }
        if petView == nil { pulse(scale: 1.08, duration: 0.2) }
        petView?.speak(seconds: min(3, max(0.6, Double(reply.text.count) * 0.12)))
        PetEmotion.shared.reward(0.3)
    }

    // MARK: - 打字方式 / 密码 / 语音 / 拖动 的反应

    /// 按键类反应（PetKeyObserver 判断）：纸偶播动作，所有形象都冒情绪符号；台词遵守安静模式。
    func keyReaction(_ reaction: PetKeyObserver.Reaction) {
        guard panel?.isVisible == true else { return }
        if pack?.renderer == "puppet" { petView?.trigger(reaction.trigger) } else if reaction.emote == nil { pulse(scale: 1.05, duration: 0.15) }
        if let emote = reaction.emote { showEmote(emote) }
        if let line = reaction.line, !Self.quietMode { showToast(line, duration: 2.5) }
    }

    private func setHold(_ name: String, _ on: Bool) {
        let before = holds
        if on { holds.insert(name) } else { holds.remove(name) }
        guard holds != before else { return }
        let effective = holds.contains("cover") ? "cover" : (holds.contains("listen") ? "listen" : "")
        petView?.setHold(effective)
    }

    /// 系统进入「安全输入」（密码框）→ 捂眼睛；退出 → 偷看一眼。
    /// 有的应用会长期开着安全输入（终端的安全键盘输入、密码管理器），捂 90 秒还没结束就放下手，等它关了再说。
    private func pollSecureInput() {
        let secure = IsSecureEventInputEnabled()
        if secure {
            if secureSince == nil {
                secureSince = Date()
                guard !secureIgnored else { return }
                setHold("cover", true)
                showEmote("🙈")
                if !Self.quietMode { showToast(["我不看我不看", "捂好眼睛了，放心输", "嘘——我什么都没看到"].randomElement()!, duration: 2.5) }
            } else if !secureIgnored, let since = secureSince, Date().timeIntervalSince(since) > 90 {
                secureIgnored = true
                setHold("cover", false)
            }
        } else if secureSince != nil {
            secureSince = nil
            let wasCovering = holds.contains("cover")
            secureIgnored = false
            setHold("cover", false)
            if wasCovering {
                petView?.trigger("cover_end")
                showEmote("👀")
                if !Self.quietMode { showToast(["输好了吗？", "我可以睁眼了吗～"].randomElement()!, duration: 2) }
            }
        }
    }

    /// 语音输入：开始 → 凑过来竖起耳朵；说完 → 开心回应。
    private func pollVoice() {
        let listening = VoiceInputController.shared.isListening
        guard listening != voiceListening else { return }
        voiceListening = listening
        setHold("listen", listening)
        if listening {
            voiceHeardAny = false
            showEmote("👂")
        } else if voiceHeardAny {
            petView?.trigger("voice_done")
            showEmote("😊")
        }
    }

    /// 语音识别有新内容（InputController 调）：听着听着点点头。
    func voiceHeard() {
        voiceHeardAny = true
        guard Date().timeIntervalSince(lastVoiceNod) > 1.6 else { return }
        lastVoiceNod = Date()
        petView?.trigger("voice_heard")
    }

    /// 中 / 英切换：头顶冒「中」或「EN」。
    private func modeChanged(chinese: Bool) {
        defer { lastModeChinese = chinese }
        guard let last = lastModeChinese, last != chinese, panel?.isVisible == true else { return }
        petView?.trigger("mode")
        showEmote(chinese ? "中" : "EN")
    }

    private func dragBegan() {
        dragSamples.removeAll()
        dragStarted = Date()
        dragWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !Self.quietMode else { return }
            self.showToast(["放我下来嘛～", "要带我去哪儿呀？", "我恐高…"].randomElement()!, duration: 2.5)
        }
        dragWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// 放下时：拎着来回晃 → 晕；用力一甩 → 转着圈落地。
    private func dragEnded() {
        dragWork?.cancel()
        defer { dragSamples.removeAll() }
        guard dragSamples.count > 4, let last = dragSamples.last else { return }
        var reversals = 0, dir = 0
        var extreme = dragSamples[0].p.x
        for sample in dragSamples.dropFirst() {
            let x = sample.p.x
            switch dir {
            case 0: if x - extreme > 25 { dir = 1; extreme = x } else if extreme - x > 25 { dir = -1; extreme = x }
            case 1: if x > extreme { extreme = x } else if extreme - x > 25 { reversals += 1; dir = -1; extreme = x }
            default: if x < extreme { extreme = x } else if x - extreme > 25 { reversals += 1; dir = 1; extreme = x }
            }
        }
        let recent = dragSamples.filter { last.t - $0.t < 0.08 }
        var speed: CGFloat = 0
        if let first = recent.first, last.t - first.t > 0.01 {
            speed = hypot(last.p.x - first.p.x, last.p.y - first.p.y) / CGFloat(last.t - first.t)
        }
        if reversals >= 4 {
            petView?.trigger("drag_dizzy")
            showEmote("💫")
            if !Self.quietMode { showToast(["晕晕晕…", "别晃了，天旋地转的"].randomElement()!, duration: 2.5) }
        } else if speed > 1800 {
            petView?.trigger("fling")
            showEmote("💫")
            if !Self.quietMode { showToast("哇啊啊——", duration: 1.8) }
        }
    }

    /// 删字（InputController 调）：短时间删很多会被安慰。
    func noteDelete() {
        guard panel?.isVisible == true, let event = PetEmotion.shared.deleted() else { return }
        perform(event)
    }

    /// 鼠标在桌宠附近左右猛晃 → 晕。统计 1.2 秒内幅度超过 30pt 的折返次数。
    private func shakeTick() {
        guard let panel, panel.isVisible else { return }
        pollTick += 1
        if pollTick % 15 == 0 { pollSecureInput() }
        pollVoice()
        let mouse = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        guard panel.frame.insetBy(dx: -160, dy: -160).contains(mouse) else {
            if !shakeSamples.isEmpty { shakeSamples.removeAll() }
            return
        }
        shakeSamples.append((now, mouse.x))
        shakeSamples.removeAll { now - $0.t > 1.2 }
        guard shakeSamples.count > 6, let first = shakeSamples.first else { return }
        var reversals = 0, dir = 0
        var extreme = first.x
        for sample in shakeSamples.dropFirst() {
            let x = sample.x
            switch dir {
            case 0:
                if x - extreme > 30 { dir = 1; extreme = x } else if extreme - x > 30 { dir = -1; extreme = x }
            case 1:
                if x > extreme { extreme = x } else if extreme - x > 30 { reversals += 1; dir = -1; extreme = x }
            default:
                if x < extreme { extreme = x } else if x - extreme > 30 { reversals += 1; dir = 1; extreme = x }
            }
        }
        if reversals >= 4, let event = PetEmotion.shared.shaken() {
            shakeSamples.removeAll()
            markActive(typing: false)
            perform(event)
        }
    }

    private func lifeTick() {
        guard panel?.isVisible == true else { return }
        let idleFor = Date().timeIntervalSince(lastActivity)
        // 90 秒无输入 → 发呆打盹；有输入或被摸时 wake()
        if !sleepy, idleFor > 90 { setSleepy(true) }
        // 休息 5 分钟以上视为新的一段打字
        if idleFor > 300 {
            sessionStart = nil
            breakReminded = false
        }
        if Self.breakReminder, !breakReminded, let start = sessionStart,
           Date().timeIntervalSince(start) > Double(Self.breakMinutes * 60) {
            breakReminded = true
            emitSparks(hearts: true)
            petView?.trigger("break")
            showToast("已经连续打字 \(Self.breakMinutes) 分钟了，起来伸个懒腰、喝口水吧 ☕️", duration: 8)
        }
        greetIfNeeded()
        if let event = PetEmotion.shared.tick(typingRecently: idleFor < 120) { perform(event) }
        // 人在、醒着、有一阵没跟它玩了 → 偶尔用你最喜欢的方式邀请你
        if idleFor < 120, !sleepy, Date().timeIntervalSince(lastUserTouch) > 300,
           let invite = PetInteraction.shared.invite() {
            performReaction(invite, proactive: true)
            if invite.trigger == "tap_hand" { scheduleHighFiveCheck(after: 8.2) }
        }
    }

    private func setSleepy(_ on: Bool) {
        guard sleepy != on else { return }
        sleepy = on
        if let petView {
            petView.setSleepy(on)
            return
        }
        // 非 WebKit 形象：变淡 + 头顶 💤
        guard let host = panel?.contentView else { return }
        if on {
            let label = zzzLabel ?? {
                let l = NSTextField(labelWithString: "💤")
                l.font = .systemFont(ofSize: max(12, host.bounds.width * 0.18))
                l.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(l)
                NSLayoutConstraint.activate([
                    l.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -2),
                    l.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
                ])
                zzzLabel = l
                return l
            }()
            label.isHidden = false
            label.wantsLayer = true
            let float = CABasicAnimation(keyPath: "transform.translation.y")
            float.fromValue = 0
            float.toValue = 4
            float.duration = 1.6
            float.autoreverses = true
            float.repeatCount = .infinity
            label.layer?.add(float, forKey: "zzz")
        } else {
            zzzLabel?.isHidden = true
            zzzLabel?.layer?.removeAnimation(forKey: "zzz")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            for view in host.subviews where view !== zzzLabel {
                view.animator().alphaValue = on ? 0.72 : 1
            }
        }
    }

    /// 有输入或被互动：记活跃、唤醒、累计连续打字段。
    private func markActive(typing: Bool) {
        lastActivity = Date()
        if typing, sessionStart == nil { sessionStart = Date() }
        setSleepy(false)
    }

    /// 把桌宠移到「输入所在屏幕」：保持相对位置，跟随光标/输入焦点跨屏。
    func moveToScreen(containing point: NSPoint) {
        guard let panel, panel.isVisible else { return }
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main else { return }
        if let current = panel.screen, current == target { return }
        let from = panel.screen ?? target
        let fv = from.visibleFrame
        let fracX = (panel.frame.minX - fv.minX) / max(1, fv.width)
        let fracY = (panel.frame.minY - fv.minY) / max(1, fv.height)
        let tv = target.visibleFrame
        var origin = NSPoint(
            x: tv.minX + fracX * tv.width,
            y: tv.minY + fracY * tv.height
        )
        origin.x = min(max(origin.x, tv.minX + 8), tv.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, tv.minY + 8), tv.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// 开发用：强制进入某个状态（便于截图核对姿态）。
    func debugApplyState(_ name: String) {
        lastActivity = Date()
        switch name {
        case "typing": react(.composing)
        case "commit": react(.commit)
        case "petted", "happy": petView?.petted()
        case "sleepy": setSleepy(true)
        case "drag": petView?.setDragging(true)
        default: react(.idle)
        }
    }

    /// 开发用：抓取 VRM 画面到 PNG。
    func captureVrmPNG(to path: String, completion: @escaping (Bool) -> Void) {
        guard let petView else {
            completion(false)
            return
        }
        petView.capturePNG { data in
            guard let data else {
                completion(false)
                return
            }
            try? data.write(to: URL(fileURLWithPath: path))
            completion(true)
        }
    }

    /// 开发用：VRM 页面内部状态。
    func vrmDebugState(_ completion: @escaping (String) -> Void) {
        if let petView {
            petView.debugState(completion)
        } else {
            completion("no-vrm-view")
        }
    }

    /// 异步快照：VRM（WKWebView/WebGL）需要 takeSnapshot 才能截到内容。
    func snapshotAsync(to path: String, completion: @escaping (Bool) -> Void) {
        if let petView {
            petView.capturePNG { data in
                guard let data else {
                    completion(false)
                    return
                }
                try? data.write(to: URL(fileURLWithPath: path))
                completion(true)
            }
            return
        }
        snapshot(to: path)
        completion(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - 帧动画状态机

    private var currentState: State = .idle
    private var frameIndex = 0
    private var animTimer: Timer?
    private var animFps: Double = 0

    private func startAnimTimerIfNeeded() {
        guard animTimer == nil else { return }
        restartAnimTimer()
    }

    /// 按当前状态用对应帧率重启计时器：idle 慢速省电，typing 提速跟手。
    private func restartAnimTimer() {
        guard pack != nil else { return }
        let fps: Double
        switch currentState {
        case .idle: fps = pack?.idleFps ?? 3
        case .composing, .commit: fps = pack?.typingFps ?? 9
        }
        // 每次按键都会 react(.composing)：帧率没变就不重建计时器
        if animTimer != nil, fps == animFps { return }
        animTimer?.invalidate()
        animFps = fps
        let timer = Timer(timeInterval: 1.0 / max(1, fps), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stopAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func tick() {
        guard panel?.isVisible == true else { return }
        // VRM：状态给 JS 处理；这里只按鼠标更新注视（约 20fps 节流）
        if let petView {
            gazeTick += 1
            if gazeTick % 3 == 0, let panel {
                let mouse = NSEvent.mouseLocation
                let dx = (mouse.x - panel.frame.midX) / max(120, panel.frame.width)
                let dy = (mouse.y - panel.frame.midY) / max(120, panel.frame.height)
                petView.setGaze(dx: Double(dx), dy: Double(dy))
            }
            return
        }
        // emoji 角色包：轻微上下浮动（idle 慢、打字快），不换帧
        if let emojiLabel, let pack, pack.emoji != nil {
            let t = CACurrentMediaTime()
            let speed = currentState == .idle ? 1.7 : 5.2
            let amp: CGFloat = currentState == .idle ? 2.2 : 3.8
            emojiLabel.wantsLayer = true
            emojiLabel.layer?.setAffineTransform(
                CGAffineTransform(translationX: 0, y: CGFloat(sin(t * speed)) * amp)
            )
            return
        }
        guard let pack, let imageView else { return }
        switch currentState {
        case .idle:
            frameIndex = (frameIndex + 1) % max(1, pack.idle.count)
            imageView.image = pack.idle[frameIndex]
        case .composing:
            frameIndex = (frameIndex + 1) % max(1, pack.typing.count)
            imageView.image = pack.typing[frameIndex]
        case .commit:
            // commit 帧只播一遍，播完回到 idle 小动作
            if frameIndex < max(1, pack.commit.count) - 1 {
                frameIndex += 1
            } else {
                currentState = .idle
                frameIndex = 0
                imageView.image = pack.idle.first
                return
            }
            imageView.image = pack.commit[frameIndex]
        }
    }

    func react(_ state: State) {
        guard let panel, panel.isVisible else { return }
        resetWorkItem?.cancel()
        var welcome: PetEmotion.Event?
        if state == .composing || state == .commit {
            // 离开很久后回来打字：先醒，再欢迎
            welcome = PetEmotion.shared.resumed(afterIdle: Date().timeIntervalSince(lastActivity))
            markActive(typing: true)
        }
        if state == .commit {
            checkMilestone()
            PetEmotion.shared.committed()
        }
        if let welcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.perform(welcome) }
        }
        // 形象包：切状态、帧归零、按状态换帧率
        if let pack, let imageView {
            currentState = state
            frameIndex = 0
            restartAnimTimer()
            switch state {
            case .idle: imageView.image = pack.idle.first
            case .composing: imageView.image = pack.typing.first
            case .commit:
                imageView.image = pack.commit.first
                if pack.commitParticles {
                    emitSparks()
                }
            }
            return
        }
        // WebKit 渲染器（VRM / Live2D）：状态交给 JS（poseIdle/poseTyping/poseCommit）
        if let pack, let petView, ["vrm", "live2d", "puppet"].contains(pack.renderer) {
            currentState = state
            restartAnimTimer()
            petView.setState(state == .composing ? "typing" : (state == .commit ? "commit" : "idle"))
            if state == .commit {
                if pack.commitParticles { emitSparks() }
                let item = DispatchWorkItem { [weak self] in self?.react(.idle) }
                resetWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
            }
            return
        }
        // emoji 角色包：不改帧，按状态给弹性动效
        if let pack, let emojiLabel, pack.emoji != nil {
            currentState = state
            restartAnimTimer()
            emojiLabel.stringValue = pack.emoji ?? Self.builtinEmoji
            switch state {
            case .idle:
                break
            case .composing:
                if pack.typingBounce { pulse(scale: 1.1, duration: 0.16) }
            case .commit:
                pulse(scale: 1.26, duration: 0.34)
                if pack.commitParticles { emitSparks() }
                let item = DispatchWorkItem { [weak self] in self?.react(.idle) }
                resetWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
            }
            return
        }
        // 内置表情（emoji 形象）：干净、可放大，作为默认推荐
        switch state {
        case .idle:
            face.stringValue = Self.builtinEmoji
        case .composing:
            face.stringValue = Self.builtinEmoji
            pulse(scale: 1.08, duration: 0.16)
        case .commit:
            face.stringValue = Self.builtinEmoji
            pulse(scale: 1.22, duration: 0.34)
            emitSparks()
            let item = DispatchWorkItem { [weak self] in self?.react(.idle) }
            resetWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
    }

    private func makePanel() -> NSPanel {
        let size = pack?.size ?? 84
        let panelW = pack?.width ?? size
        let panelH = pack?.height ?? size
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false   // 拖动由 PetBackgroundView 手动处理（需要上报状态）
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 角色直接悬浮在桌面上：无托盘、无材质背景，只有角色本体
        let background = PetBackgroundView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        background.onClick = { [weak self] point in self?.tapBody(at: point) }
        background.onHover = { [weak self] hovering in
            self?.hoverBody(hovering)
        }
        background.onRightClick = { [weak self] event in
            self?.presentPetMenu(event)
        }
        background.onDoubleClick = { [weak self] _ in self?.pokeBody() }
        background.onDragChanged = { [weak self] dragging in
            guard let self else { return }
            self.lastUserTouch = Date()
            PetEmotion.shared.touched()
            self.markActive(typing: false)
            self.petView?.setDragging(dragging)
            if dragging { self.dragBegan() } else { self.dragEnded() }
            if !dragging { self.clampToScreen(animated: true) }
        }
        background.onDragMoved = { [weak self] point in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.dragSamples.append((now, point))
            self.dragSamples.removeAll { now - $0.t > 1.5 }
        }

        // 脚下柔和的椭圆投影：让角色「站」在桌面上（半身构图没有脚，不画）
        let webBust = (pack?.renderer == "vrm" || pack?.renderer == "live2d") && Self.framingOverride == "bust"
        background.wantsLayer = true   // 投影与礼花粒子都挂在这一层
        if !webBust {
            let shadow = CAGradientLayer()
            shadow.type = .radial
            shadow.colors = [
                NSColor.black.withAlphaComponent(0.28).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor,
            ]
            shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
            shadow.endPoint = CGPoint(x: 1, y: 1)
            let w = panelW * 0.56
            let h = max(8, panelW * 0.09)
            shadow.frame = CGRect(x: (panelW - w) / 2, y: 2, width: w, height: h)
            background.layer?.addSublayer(shadow)
            groundShadow = shadow
        }

        if let pack, pack.renderer == "vrm" {
            // VRM 3D：WKWebView + three.js/three-vrm（注视/眨眼/物理/状态机）
            if let modelPath = PetRuntimeStore.modelPath(for: Self.activePackId, entry: pack.entry) {
                let view = VRMPetView(
                    frame: background.bounds,
                    modelPath: modelPath,
                    framing: Self.framingOverride,
                    zoom: pack.zoom * Self.zoomOverride
                )
                view.autoresizingMask = [.width, .height]
                view.onError = { [weak self] message in
                    self?.showToast("VRM 加载失败：\(message)", duration: 6)
                }
                background.addSubview(view)
                petView = view
            } else {
                unsupportedRenderer = "vrm(缺少模型)"
            }
        } else if let pack, pack.renderer == "live2d" {
            // Live2D：WKWebView + pixi-live2d-display（方案 A：自带运行时，见 ADR-0009）
            if PetRuntimeStore.live2DCoreAvailable(),
               let modelPath = PetRuntimeStore.live2DModelPath(for: Self.activePackId, entry: pack.entry) {
                let view = Live2DPetView(
                    frame: background.bounds,
                    modelPath: modelPath,
                    framing: Self.framingOverride,
                    zoom: pack.zoom * Self.zoomOverride,
                    scale: pack.scale
                )
                view.autoresizingMask = [.width, .height]
                view.onError = { [weak self] message in
                    self?.showToast("Live2D 加载失败：\(message)", duration: 6)
                }
                view.onNeedsRuntime = { [weak self] in
                    self?.showToast("Live2D 运行时未就绪（见 ADR-0009：需自备 Cubism Core）", duration: 6)
                }
                background.addSubview(view)
                petView = view
            } else {
                unsupportedRenderer = "live2d(缺少运行时/模型)"
            }
        } else if let pack, pack.renderer == "puppet" {
            // 纸偶：图片 + 网格形变（我们自己的开放格式，见 ADR-0011）
            if let packPath = PetRuntimeStore.puppetPackPath(for: Self.activePackId) {
                let view = PuppetPetView(
                    frame: background.bounds,
                    packPath: packPath,
                    zoom: pack.zoom * Self.zoomOverride,
                    roam: Self.roamEnabled
                )
                view.autoresizingMask = [.width, .height]
                view.onError = { [weak self] message in
                    self?.showToast("纸偶形象加载失败：\(message)", duration: 6)
                }
                background.addSubview(view)
                petView = view
            } else {
                unsupportedRenderer = "puppet(形象包缺失)"
            }
        } else if let pack, pack.renderer == "rive" {
            // 高级渲染器（Rive）尚未接入：明确提示，不用程序化丑图糊弄
            let note = NSTextField(wrappingLabelWithString:
                "\(pack.renderer.uppercased()) 形象\n渲染器未接入\n（见 ADR-0007）")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.alignment = .center
            note.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(note)
            NSLayoutConstraint.activate([
                note.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                note.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                note.widthAnchor.constraint(lessThanOrEqualTo: background.widthAnchor, constant: -8),
            ])
            unsupportedRenderer = pack.renderer
        } else if let pack, pack.renderer == "sprites", let idle = pack.idle.first {
            let view = NSImageView(frame: background.bounds)
            view.image = idle
            view.imageScaling = .scaleProportionallyUpOrDown
            view.autoresizingMask = [.width, .height]
            background.addSubview(view)
            imageView = view
        } else if let pack, let emoji = pack.emoji {
            // emoji 角色包：系统 emoji 作形象（可爱/好看），可选道具 emoji
            let label = NSTextField(labelWithString: emoji)
            label.font = .systemFont(ofSize: size * 0.62)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: -size * 0.06),
            ])
            emojiLabel = label
            if let prop = pack.prop, !prop.isEmpty {
                let p = NSTextField(labelWithString: prop)
                p.font = .systemFont(ofSize: size * 0.3)
                p.alignment = .center
                p.translatesAutoresizingMaskIntoConstraints = false
                background.addSubview(p)
                NSLayoutConstraint.activate([
                    p.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                    p.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -size * 0.02),
                ])
                propLabel = p
            }
        } else {
            face.stringValue = Self.builtinEmoji
            face.font = .systemFont(ofSize: size * 0.62)
            face.alignment = .center
            face.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(face)
            NSLayoutConstraint.activate([
                face.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                face.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            ])
        }

        // 悬停时才出现的小圆钮，吸附在角色下沿
        let modeBtn = PetQuickButton(title: "中")
        modeBtn.toolTip = "切换中 / 英（左 Shift 同效）"
        modeBtn.handler = {
            NotificationCenter.default.post(name: .petToggleLanguage, object: nil)
        }
        let statsBtn = PetQuickButton(title: "📊")
        statsBtn.toolTip = "今日输入小结"
        statsBtn.handler = { [weak self] in
            self?.showStatsCard(yesterday: false)
        }
        let chatBtn = PetQuickButton(title: "💬")
        chatBtn.toolTip = "和它聊天"
        chatBtn.handler = { PetChatController.shared.open() }
        let dock = NSStackView(views: [modeBtn, statsBtn, chatBtn])
        dock.orientation = .horizontal
        dock.spacing = 6
        dock.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -1),
            modeBtn.widthAnchor.constraint(equalToConstant: 22),
            modeBtn.heightAnchor.constraint(equalToConstant: 22),
            statsBtn.widthAnchor.constraint(equalToConstant: 22),
            statsBtn.heightAnchor.constraint(equalToConstant: 22),
            chatBtn.widthAnchor.constraint(equalToConstant: 22),
            chatBtn.heightAnchor.constraint(equalToConstant: 22),
        ])
        modeBtn.isHidden = true
        statsBtn.isHidden = true
        modeButton = modeBtn
        statsButton = statsBtn
        chatBtn.isHidden = true
        chatButton = chatBtn

        panel.contentView = background

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { _ in
            PetWindowController.shared.saveOrigin()
            // 气泡跟着桌宠走（拖动 / 跨屏）
            PetWindowController.shared.positionToast()
        }
        return panel
    }

    // MARK: - 互动（悬停 / 点按 / 右键）

    /// 左键点按：先判断点在哪个部位（头 / 脸 / 身体 / 手 / 脚 / 空白），再给对应反应。
    private func tapBody(at point: NSPoint) {
        pulse(scale: 1.08, duration: 0.18)
        lastUserTouch = Date()
        markActive(typing: false)
        resolveRegion(at: point) { [weak self] region in
            self?.handleTap(region)
        }
    }

    /// 纸偶形象按骨架 + 透明度精确判断；其他形象按画面比例粗分。
    private func resolveRegion(at point: NSPoint, _ done: @escaping (PetInteraction.Region) -> Void) {
        guard let host = panel?.contentView else { return done(.body) }
        let fx = point.x / max(1, host.bounds.width)
        let fy = point.y / max(1, host.bounds.height)   // 非翻转坐标：y 自下而上，与页面一致
        if pack?.renderer == "puppet", let petView {
            petView.hitRegion(fx: fx, fy: fy) { done(PetInteraction.Region(rawValue: $0) ?? .body) }
            return
        }
        let region: PetInteraction.Region
        if fy > 0.72 { region = .head } else if fy > 0.6 { region = .face } else if fy < 0.12 { region = .feet } else if abs(fx - 0.5) > 0.3 { region = .hand } else { region = .body }
        done(region)
    }

    private func handleTap(_ region: PetInteraction.Region) {
        // 连着摸头 → 心动（情感引擎优先）
        if region == .head, let event = PetEmotion.shared.petted() {
            PetInteraction.shared.noteInteraction()
            perform(event)
            return
        }
        let reaction = PetInteraction.shared.tapped(region)
        performReaction(reaction, proactive: false)
        if reaction.trigger == "tap_hand" { scheduleHighFiveCheck(after: 3.3) }
    }

    private func scheduleHighFiveCheck(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let miss = PetInteraction.shared.highFiveMissed() else { return }
            self.performReaction(miss, proactive: false)
        }
    }

    /// 执行部位反应：纸偶播学到偏好加权的动作；其他形象用摸头 / 戳一戳反馈 + 情绪符号。
    func performReaction(_ reaction: PetInteraction.Reaction, proactive: Bool) {
        if reaction.affection != 0 { PetEmotion.shared.reward(reaction.affection) }
        if pack?.renderer == "puppet" {
            petView?.trigger(reaction.trigger, weights: PetInteraction.shared.weights(for: reaction.trigger))
        } else {
            if let petView {
                reaction.positive ? petView.petted() : petView.poke()
            } else if reaction.positive {
                emitSparks(hearts: true)
            }
            if let emote = reaction.emote { showEmote(emote) }
        }
        if proactive && Self.quietMode { return }
        if let line = packLines[reaction.trigger]?.randomElement() ?? reaction.line {
            showToast(line, duration: 2.8)
        }
    }

    /// 双击 = 戳一戳：惊讶小跳。
    private func pokeBody() {
        pulse(scale: 1.2, duration: 0.26)
        lastUserTouch = Date()
        markActive(typing: false)
        PetInteraction.shared.noteInteraction()
        // 连戳 → 生气背过身（替代普通戳一戳反应）
        if let event = PetEmotion.shared.poked() {
            perform(event)
            return
        }
        if let petView {
            petView.poke()
        } else {
            showToast(pickPetLine(["哎呀！", "干嘛呀～", "戳我干嘛"]), duration: 2.5)
        }
    }

    private func pickPetLine(_ lines: [String]) -> String {
        lines.randomElement() ?? lines[0]
    }

    /// 悬停：轻晃 + 显示吸附按钮；操作提示只在前 3 次悬停时出现，之后不再打扰。
    private func hoverBody(_ hovering: Bool) {
        modeButton?.isHidden = !hovering
        statsButton?.isHidden = !hovering
        chatButton?.isHidden = !hovering
        statsButton?.toolTip = "今日已输入 \(PetStats.shared.today.chars.formatted()) 字 · 点开看小结"
        petView?.setHover(hovering)
        self.hovering = hovering
        stareWork?.cancel()
        guard hovering else { return }
        // 鼠标一直停在身上 → 害羞
        let stare = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, let event = PetEmotion.shared.stared() else { return }
            self.perform(event)
        }
        stareWork = stare
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: stare)
        pulse(scale: 1.06, duration: 0.16)
        let shown = UserDefaults.standard.integer(forKey: Self.hintCountKey)
        guard shown < 3 else { return }
        UserDefaults.standard.set(shown + 1, forKey: Self.hintCountKey)
        showToast("点我摸头 · 双击戳一戳 · 右键更多", duration: 3.5)
    }

    /// 右键菜单：模式、标点、统计、桌宠设置、隐私。
    private func presentPetMenu(_ event: NSEvent?) {
        lastUserTouch = Date()
        PetEmotion.shared.touched()
        let menu = NSMenu()
        let affection = NSMenuItem(title: "好感度 \(PetEmotion.shared.hearts)", action: nil, keyEquivalent: "")
        affection.toolTip = "\(Int(PetEmotion.shared.affection))/100 · 摸头、陪它打字会涨，冷落和连戳会降"
        affection.isEnabled = false
        menu.addItem(affection)
        if let favorite = PetInteraction.shared.favoriteRegion {
            let fav = NSMenuItem(title: "它记得你最喜欢：\(favorite.title)", action: nil, keyEquivalent: "")
            fav.isEnabled = false
            menu.addItem(fav)
        }
        menu.addItem(.separator())
        let lang = NSMenuItem(title: "切换 中/英", action: #selector(petMenuToggleLanguage(_:)), keyEquivalent: "")
        lang.target = self
        menu.addItem(lang)
        let punct = NSMenuItem(
            title: "强制半角标点",
            action: #selector(petMenuTogglePunctuation(_:)),
            keyEquivalent: ""
        )
        punct.target = self
        punct.state = UserDefaults.standard.bool(forKey: "LianaForceHalfPunctuation") ? .on : .off
        menu.addItem(punct)
        // 桌宠形象：直接在桌宠上右键切换（最直接、可发现）
        let petImage = NSMenuItem(title: "桌宠形象", action: nil, keyEquivalent: "")
        let imageMenu = NSMenu(title: "桌宠形象")
        let activePack = Self.activePackId
        let installed = Self.availablePets()
        let installedIds = Set(installed.map { $0.id })
        for pack in installed {
            let item = NSMenuItem(title: pack.name, action: #selector(petMenuSelectPack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.id
            item.state = pack.id == activePack ? .on : .off
            imageMenu.addItem(item)
        }
        for entry in PetCatalogStore.entries() where !installedIds.contains(entry.id) {
            let item = NSMenuItem(
                title: "\(entry.name)（未装 · \(entry.sizeText)）",
                action: #selector(petMenuDownloadPack(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            item.toolTip = "\(entry.license) · 点击下载并切换"
            imageMenu.addItem(item)
        }
        petImage.submenu = imageMenu
        menu.addItem(petImage)
        let more = NSMenuItem(title: "更多 VRM 形象…", action: #selector(petMenuOpenCatalog(_:)), keyEquivalent: "")
        more.target = self
        menu.addItem(more)
        let isPuppet = pack?.renderer == "puppet"
        let workshop = NSMenuItem(
            title: isPuppet ? "在形象工坊里编辑…" : "用图片做桌宠…",
            action: #selector(petMenuWorkshop(_:)),
            keyEquivalent: ""
        )
        workshop.target = self
        menu.addItem(workshop)
        let chat = NSMenuItem(title: "和它聊天…", action: #selector(petMenuChat(_:)), keyEquivalent: "")
        chat.target = self
        menu.addItem(chat)
        let auto = NSMenuItem(title: "不在输入框时打字就聊天", action: #selector(petMenuToggleChatAuto(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = PetChatAutoTrigger.enabled ? .on : .off
        auto.toolTip = "需要辅助功能权限：只判断当前是不是输入框，不记录任何按键"
        menu.addItem(auto)
        let community = NSMenuItem(title: "形象源…", action: #selector(petMenuCommunity(_:)), keyEquivalent: "")
        community.target = self
        menu.addItem(community)
        if isPuppet {
            let roam = NSMenuItem(title: "允许四处溜达", action: #selector(petMenuToggleRoam(_:)), keyEquivalent: "")
            roam.target = self
            roam.state = Self.roamEnabled ? .on : .off
            menu.addItem(roam)
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "大小")
        for (title, value) in [("80%", 0.8), ("100%", 1.0), ("125%", 1.25), ("150%", 1.5)] {
            let item = NSMenuItem(title: title, action: #selector(petMenuZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(Self.zoomOverride - value) < 0.01 ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let quiet = NSMenuItem(title: "安静模式（不主动说话）", action: #selector(petMenuToggleQuiet(_:)), keyEquivalent: "")
        quiet.target = self
        quiet.state = Self.quietMode ? .on : .off
        menu.addItem(quiet)
        let rest = NSMenuItem(
            title: "连续打字 \(Self.breakMinutes) 分钟提醒休息",
            action: #selector(petMenuToggleBreak(_:)),
            keyEquivalent: ""
        )
        rest.target = self
        rest.state = Self.breakReminder ? .on : .off
        menu.addItem(rest)
        menu.addItem(.separator())
        let today = NSMenuItem(title: "今日输入小结", action: #selector(petMenuShowToday(_:)), keyEquivalent: "")
        today.target = self
        menu.addItem(today)
        let stats = NSMenuItem(title: "昨日输入总结", action: #selector(petMenuShowStats(_:)), keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)
        let forget = NSMenuItem(title: "清空互动记忆", action: #selector(petMenuForgetInteraction(_:)), keyEquivalent: "")
        forget.target = self
        forget.toolTip = "忘掉学到的互动偏好（最喜欢的部位、喜欢的反应）；好感度保留"
        menu.addItem(forget)
        let perms = NSMenuItem(title: "权限与隐私…", action: #selector(petMenuPermissions(_:)), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏桌宠", action: #selector(petMenuHide(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func petMenuWorkshop(_ sender: Any) {
        let active = Self.activePackId
        PetWorkshopWindowController.shared.show(editing: PuppetPackStore.isPuppet(packId: active) ? active : nil)
    }

    @objc private func petMenuCommunity(_ sender: Any) {
        PetCommunityWindowController.shared.show()
    }

    @objc private func petMenuToggleRoam(_ sender: Any) {
        Self.roamEnabled.toggle()
        showToast(Self.roamEnabled ? "我偶尔会出去溜达一下～" : "好，我乖乖待在这", duration: 2.5)
    }

    @objc private func petMenuChat(_ sender: Any) {
        PetChatController.shared.open()
    }

    @objc private func petMenuToggleChatAuto(_ sender: Any) {
        PetChatAutoTrigger.enabled.toggle()
        if PetChatAutoTrigger.enabled {
            showToast(PetChatAutoTrigger.permitted
                      ? "好！在没有输入框的地方直接打字，我就来陪你聊"
                      : "请在系统设置 › 隐私与安全性 › 辅助功能 里允许「松萝」，开启后自动生效", duration: 6)
        }
    }

    @objc private func petMenuForgetInteraction(_ sender: Any) {
        PetInteraction.shared.forget()
        showToast("好，之前的互动习惯我都忘掉了，重新认识一下吧", duration: 3)
    }

    @objc private func petMenuZoom(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Self.zoomOverride = value
    }

    @objc private func petMenuToggleQuiet(_ sender: Any) {
        Self.quietMode.toggle()
        showToast(Self.quietMode ? "好的，我安静陪着你 🤫" : "我又可以说话啦", duration: 2.5)
    }

    @objc private func petMenuToggleBreak(_ sender: Any) {
        Self.breakReminder.toggle()
        breakReminded = false
        showToast(Self.breakReminder ? "连续打字 \(Self.breakMinutes) 分钟会提醒你休息" : "已关闭休息提醒", duration: 2.5)
    }

    @objc private func petMenuShowToday(_ sender: Any) {
        showStatsCard(yesterday: false)
    }

    @objc private func petMenuHide(_ sender: Any) {
        Self.setEnabled(false)
        GlassToast.shared.show("桌宠已隐藏，可在输入法菜单或设置 › 桌宠里重新打开", duration: 5)
    }

    @objc private func petMenuToggleLanguage(_ sender: Any) {
        NotificationCenter.default.post(name: .petToggleLanguage, object: nil)
    }

    @objc private func petMenuSelectPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Self.activePackId = id
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
        showToast("已切换桌宠形象：\(sender.title)", duration: 2.5)
    }

    @objc private func petMenuOpenCatalog(_ sender: Any) {
        PetCatalogWindowController.shared.show()
    }

    /// 右键菜单里点未安装的目录条目：下载（sha256 校验）后切换。
    @objc private func petMenuDownloadPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = PetCatalogStore.entries().first(where: { $0.id == id }) else { return }
        if Self.availablePets().contains(where: { $0.id == id }) {
            Self.activePackId = id
            showToast("已切换：\(entry.name)", duration: 2.5)
            return
        }
        showToast("下载 \(entry.name)（\(entry.sizeText)）…", duration: 4)
        PetModelInstaller.install(entry, onProgress: { _ in }) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    PetWindowController.activePackId = id
                    if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
                    PetWindowController.shared.showToast("\(entry.name) 已下载并切换（sha256 校验通过）", duration: 5)
                case .failure(let error):
                    PetWindowController.shared.showToast("下载失败：\(error.localizedDescription)", duration: 6)
                }
            }
        }
    }

    @objc private func petMenuTogglePunctuation(_ sender: Any) {
        NotificationCenter.default.post(name: .petTogglePunctuation, object: nil)
    }

    @objc private func petMenuShowStats(_ sender: Any) {
        NotificationCenter.default.post(name: .petShowStats, object: nil)
    }

    @objc private func petMenuPermissions(_ sender: Any) {
        PermissionCenterWindowController.shared.show()
    }

    // MARK: - 气泡提示

    private var toastPanel: NSPanel?
    private var toastLabel = NSTextField(wrappingLabelWithString: "")
    private var toastWorkItem: DispatchWorkItem?

    /// 桌宠头顶气泡：任务完成提醒 / 模式反馈 / 统计卡片都走这里。
    /// 只展示本机任务与本地统计，绝不承载任何商务、付款类内容。
    func showToast(_ text: String, duration: TimeInterval = 5) {
        // 桌宠关闭时改用屏幕顶部的玻璃气泡：语音 / 同传 / 模式反馈不能因为没开桌宠就消失
        guard let petPanel = panel, petPanel.isVisible else {
            GlassToast.shared.show(text, duration: min(duration, 8))
            return
        }
        let panel = ensureToastPanel()
        toastLabel.stringValue = text
        // 纸偶：边说边动嘴（约每字 0.12 秒，最多 3 秒）
        petView?.speak(seconds: min(3, max(0.6, Double(text.count) * 0.12)))
        toastLabel.preferredMaxLayoutWidth = 200
        let size = toastLabel.intrinsicContentSize
        let width = min(230, max(120, size.width + 24))
        let height = max(34, size.height + 18) + Self.tailHeight
        panel.setContentSize(NSSize(width: width, height: height))
        positionToast()
        if !panel.isVisible {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        toastWorkItem?.cancel()
        panel.orderFrontRegardless()
        let item = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func hideToast() {
        toastWorkItem?.cancel()
        toastPanel?.orderOut(nil)
    }

    private func ensureToastPanel() -> NSPanel {
        if let toastPanel { return toastPanel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.autoresizingMask = [.width, .height]
        toastLabel.font = .systemFont(ofSize: 11.5)
        toastLabel.textColor = .labelColor
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(toastLabel)
        let centerY = toastLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            centerY,
        ])
        toastLabelCenterY = centerY
        panel.contentView = box
        toastBox = box
        toastPanel = panel
        return panel
    }

    private static let tailHeight: CGFloat = 7
    private var toastBox: NSVisualEffectView?
    private var toastLabelCenterY: NSLayoutConstraint?

    /// 气泡放在桌宠头顶；头顶放不下就翻到脚下。水平方向夹在屏幕内，尾巴始终指向桌宠。
    fileprivate func positionToast() {
        guard let toast = toastPanel, let pet = panel else { return }
        let size = toast.frame.size
        let visible = (pet.screen ?? NSScreen.main)?.visibleFrame ?? pet.frame
        var x = pet.frame.midX - size.width / 2
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        var y = pet.frame.maxY + 2
        let below = y + size.height > visible.maxY
        if below {
            y = max(visible.minY, pet.frame.minY - size.height - 2)
        }
        toast.setFrameOrigin(NSPoint(x: x, y: y))
        // 尾巴横坐标：桌宠中心相对气泡左边缘（避开圆角）
        let tailX = min(max(pet.frame.midX - x, 16), size.width - 16)
        toastBox?.maskImage = Self.bubbleMask(size: size, tailX: tailX, tailOnTop: below)
        // 文字避开尾巴所在的那一条
        toastLabelCenterY?.constant = below ? Self.tailHeight / 2 : -Self.tailHeight / 2
    }

    /// 圆角气泡 + 三角尾巴的遮罩（尾巴朝向桌宠）。
    private static func bubbleMask(size: NSSize, tailX: CGFloat, tailOnTop: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            let t = tailHeight
            let body = NSRect(
                x: 0, y: tailOnTop ? 0 : t,
                width: size.width, height: size.height - t
            )
            let path = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
            let tail = NSBezierPath()
            if tailOnTop {
                tail.move(to: NSPoint(x: tailX - 7, y: body.maxY - 1))
                tail.line(to: NSPoint(x: tailX, y: size.height))
                tail.line(to: NSPoint(x: tailX + 7, y: body.maxY - 1))
            } else {
                tail.move(to: NSPoint(x: tailX - 7, y: t + 1))
                tail.line(to: NSPoint(x: tailX, y: 0))
                tail.line(to: NSPoint(x: tailX + 7, y: t + 1))
            }
            tail.close()
            NSColor.black.setFill()
            path.fill()
            tail.fill()
            return true
        }
    }

    /// 快启动台的模式徽标：中文模式显示「中」，英文显示「EN」。
    func setModeLabel(chinese: Bool) {
        modeChanged(chinese: chinese)
        modeButton?.title = chinese ? "中" : "EN"
    }

    /// 展示昨日（或今日）总结卡片。
    func showStatsCard(yesterday: Bool) {
        let day = yesterday ? PetStats.shared.yesterday : PetStats.shared.today
        let title = yesterday ? "昨日输入总结" : "今日输入小结"
        if let text = PetStats.summaryText(for: day, title: title) {
            showToast(text + "\n好感度 " + PetEmotion.shared.hearts, duration: 12)
        }
    }

    // MARK: - 动效

    private func pulse(scale: CGFloat, duration: CGFloat) {
        let host = imageView ?? face
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, scale, 1.0 - (scale - 1.0) * 0.25, 1.0]
        animation.duration = CFTimeInterval(duration)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "pulse")
    }

    /// 上屏礼花：在桌宠脚下撒一小把 accent 色光点；摸头/里程碑时从头顶飘出小爱心。
    private func emitSparks(hearts: Bool = false) {
        if hearts {
            emitHearts()
            return
        }
        guard let panel, let background = panel.contentView else { return }
        particleEmitter?.removeFromSuperlayer()
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: background.bounds.midX, y: background.bounds.height * 0.3)
        emitter.emitterSize = CGSize(width: background.bounds.width * 0.6, height: 4)
        emitter.emitterShape = .rectangle
        let cell = CAEmitterCell()
        cell.birthRate = 46
        cell.lifetime = 0.55
        cell.velocity = 68
        cell.velocityRange = 34
        cell.emissionRange = .pi * 0.85
        cell.emissionLongitude = .pi / 2
        cell.scale = 0.05
        cell.scaleRange = 0.04
        cell.spin = 4
        cell.color = NSColor.controlAccentColor.cgColor
        cell.contents = nil
        // 没有贴图时画一个小圆点
        let dot = NSImage(size: NSSize(width: 8, height: 8))
        dot.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 6, height: 6)).fill()
        dot.unlockFocus()
        cell.contents = dot.tiffRepresentation.map { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) } ?? nil
        emitter.emitterCells = [cell]
        background.layer?.addSublayer(emitter)
        particleEmitter = emitter
        // 0.4 秒后停止发射并清理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak emitter] in
            emitter?.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, weak emitter] in
            emitter?.removeFromSuperlayer()
            if self?.particleEmitter === emitter {
                self?.particleEmitter = nil
            }
        }
    }

    private static let heartImage: CGImage? = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: NSColor.systemPink,
            ]
            NSAttributedString(string: "♥", attributes: attrs).draw(at: NSPoint(x: 4, y: 2))
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    private func emitHearts() {
        guard let panel, let background = panel.contentView, let layer = background.layer else { return }
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: background.bounds.midX, y: background.bounds.height * 0.78)
        emitter.emitterSize = CGSize(width: background.bounds.width * 0.4, height: 2)
        emitter.emitterShape = .line
        let cell = CAEmitterCell()
        cell.contents = Self.heartImage
        cell.birthRate = 9
        cell.lifetime = 1.3
        cell.velocity = 34
        cell.velocityRange = 12
        cell.yAcceleration = 12
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = .pi / 5
        cell.scale = 0.6
        cell.scaleRange = 0.25
        cell.alphaSpeed = -0.7
        cell.spinRange = 0.8
        emitter.emitterCells = [cell]
        layer.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak emitter] in
            emitter?.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak emitter] in
            emitter?.removeFromSuperlayer()
        }
    }

    // MARK: - 鼠标追踪（NSEvent.mouseLocation 轮询，不需要辅助功能权限）

    private func startMouseTrackingIfNeeded() {
        guard pack?.followCursor == true, mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.trackCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        if let imageView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageView.layer?.setAffineTransform(.identity)
            imageView.layer?.position = CGPoint(
                x: imageView.bounds.midX,
                y: imageView.bounds.midY
            )
            CATransaction.commit()
        }
    }

    private func trackCursor() {
        guard let panel, let imageView, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + panel.frame.height / 2
        )
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = max(1, sqrt(dx * dx + dy * dy))
        // 朝光标方向最多倾斜 6°、漂移 5px，像在「看」鼠标
        let angle = max(-6, min(6, dx / distance * 6)) * .pi / 180
        let position = CGPoint(
            x: imageView.bounds.midX + dx / distance * 5,
            y: imageView.bounds.midY + dy / distance * 5
        )
        imageView.wantsLayer = true
        imageView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        imageView.layer?.position = position
    }

    // MARK: - 位置记忆

    private func restoreOrigin() {
        guard let panel else { return }
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
            // 外接屏拔掉 / 分辨率变化后，旧位置可能落在屏外：拉回可见区域
            clampToScreen(animated: false)
            return
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 28,
                y: visible.minY + 28
            ))
        }
    }

    /// 保证桌宠至少大半个身子在某块屏幕的可见区域内（拖出屏外 / 屏幕消失时拉回）。
    private func clampToScreen(animated: Bool) {
        guard let panel else { return }
        let frame = panel.frame
        let screen = NSScreen.screens.max(by: {
            $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area
        })
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let keep = frame.width * 0.6
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX - frame.width + keep), visible.maxX - keep)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        guard origin != frame.origin else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    private func saveOrigin() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originKey)
    }
}

// MARK: - 互动视图件

/// 桌宠身体：区分「点按」与「拖动」，支持悬停与右键。
/// 透明无背景，角色直接悬浮在桌面上。
private final class PetBackgroundView: NSView {
    var onClick: ((NSPoint) -> Void)?
    var onDoubleClick: ((NSPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// 拖动状态变化（true = 正在被拎起来）
    var onDragChanged: ((Bool) -> Void)?
    /// 拖动中的鼠标位置（屏幕坐标）：晃动、甩出去的判断
    var onDragMoved: ((NSPoint) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var downLocation: NSPoint = .zero
    private var downAt: TimeInterval = 0
    private var grabOffset: NSPoint = .zero
    private var dragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        downLocation = NSEvent.mouseLocation
        downAt = ProcessInfo.processInfo.systemUptime
        dragging = false
        if let origin = window?.frame.origin {
            grabOffset = NSPoint(
                x: downLocation.x - origin.x,
                y: downLocation.y - origin.y
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        if !dragging,
           hypot(current.x - downLocation.x, current.y - downLocation.y) > 4 {
            dragging = true
            onDragChanged?(true)
        }
        guard dragging, let window else { return }
        window.setFrameOrigin(NSPoint(
            x: current.x - grabOffset.x,
            y: current.y - grabOffset.y
        ))
        onDragMoved?(current)
    }

    override func mouseUp(with event: NSEvent) {
        // 只有「短按且几乎没移动」才算点按：避免拖动桌宠被当成摸头
        let moved = hypot(
            NSEvent.mouseLocation.x - downLocation.x,
            NSEvent.mouseLocation.y - downLocation.y
        )
        let held = ProcessInfo.processInfo.systemUptime - downAt
        if dragging {
            dragging = false
            onDragChanged?(false)
        } else if moved < 3, held < 0.35 {
            let point = convert(event.locationInWindow, from: nil)
            if event.clickCount >= 2 {
                onDoubleClick?(point)
            } else {
                onClick?(point)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

/// 悬停浮出的小圆钮：半透明深色底 + 白字，吸附在角色下沿。
private final class PetQuickButton: NSButton {
    var handler: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        contentTintColor = .white
        font = .systemFont(ofSize: 11, weight: .semibold)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func fire() {
        handler?()
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension Notification.Name {
    static let petToggleLanguage = Notification.Name("LianaPetToggleLanguage")
    static let petTogglePunctuation = Notification.Name("LianaPetTogglePunctuation")
    static let petShowStats = Notification.Name("LianaPetShowStats")
}
