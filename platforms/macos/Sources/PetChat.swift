import AppKit
import ApplicationServices

/// 和桌宠聊天：对话气泡（自带拼音输入）+ 回复大脑（本机规则 / 本机模型）+ 自动进入对话模式。
///
/// 隐私：聊天内容只在内存里，关掉窗口就没了；本机模型走 127.0.0.1 的 llama-server，不联网（ADR-0004）。
/// 自动进入对话模式默认关闭；开启后需要辅助功能权限，只用来判断「当前焦点是不是输入框」并在
/// 不是输入框时看到按键，**不记录任何按键**，判断完即丢弃。

// MARK: - 回复大脑

enum PetChatBrain {
    struct Reply {
        let text: String
        /// 纸偶触发器（chat / chat_happy / chat_sad / 具体动作）
        let trigger: String?
        let action: String?
    }

    /// 先匹配指令与常见话题（立刻回复），匹配不到再交给本机模型；都没有就用陪聊兜底。
    static func reply(to message: String, history: [(fromUser: Bool, text: String)], petName: String,
                      completion: @escaping (Reply) -> Void) {
        if let quick = rules(message, petName: petName) {
            completion(quick)
            return
        }
        guard TranslateClient.findRuntime() != nil, TranslateClient.translateModelPath() != nil else {
            completion(fallback(message))
            return
        }
        let level = ["还不太熟", "挺熟了", "很亲近", "最喜欢对方"][PetEmotion.shared.level]
        let system = """
        你是「\(petName)」，住在用户电脑桌面上的桌宠，性格可爱、温柔、有点调皮，和用户的关系：\(level)。
        今天用户已经打了 \(PetStats.shared.today.chars) 个字。
        用简体中文口语回复，一到两句话，不超过 40 个字，可以带一个表情符号。不要说自己是 AI 或模型，不要列清单。
        """
        let transcript = (history.suffix(6).map { ($0.fromUser ? "用户：" : "你：") + $0.text } + ["用户：" + message, "你："])
            .joined(separator: "\n")
        TranslateClient.shared.chat(system: system, user: transcript, maxTokens: 80) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "^你：", with: "", options: .regularExpression)
                    completion(clean.isEmpty ? fallback(message) : Reply(text: String(clean.prefix(120)), trigger: mood(of: message), action: nil))
                case .failure:
                    completion(fallback(message))
                }
            }
        }
    }

    private static func has(_ text: String, _ keys: [String]) -> Bool {
        keys.contains { text.contains($0) }
    }

    /// 用户情绪 → 桌宠反应
    private static func mood(of text: String) -> String {
        if has(text, ["累", "烦", "难过", "伤心", "哭", "压力", "郁闷", "不开心", "崩溃", "加班"]) { return "chat_sad" }
        if has(text, ["开心", "哈哈", "好耶", "太棒", "高兴", "成功", "喜欢", "爱你"]) { return "chat_happy" }
        return "chat"
    }

    private static func rules(_ raw: String, petName: String) -> Reply? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // 指令：让它做动作
        if has(t, ["跳舞", "跳个舞", "跳一个"]) { return Reply(text: "看我的！🎵", trigger: nil, action: "dance") }
        if has(t, ["转圈", "转个圈"]) { return Reply(text: "转～圈～圈～", trigger: nil, action: "spin_turn") }
        if has(t, ["鞠躬", "谢谢你"]) { return Reply(text: "不客气！能帮上忙我很开心", trigger: nil, action: "bow") }
        if has(t, ["躲猫猫", "藏起来"]) { return Reply(text: "你看不见我～", trigger: nil, action: "peekaboo") }
        if has(t, ["击掌", "give me five"]) { return Reply(text: "来！点我的手～", trigger: "tap_hand", action: nil) }
        // 查询
        if has(t, ["几点", "时间"]) {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            return Reply(text: "现在 \(df.string(from: Date()))", trigger: "chat", action: nil)
        }
        if has(t, ["打了多少", "多少字", "今天打字", "统计"]) {
            let chars = PetStats.shared.today.chars
            return Reply(text: chars > 0 ? "今天已经打了 \(chars) 个字啦，辛苦了" : "今天还没怎么打字呢", trigger: "chat_happy", action: nil)
        }
        if has(t, ["好感", "喜欢我吗", "爱我吗"]) {
            return Reply(text: "好感度 \(PetEmotion.shared.hearts)", trigger: "chat_happy", action: nil)
        }
        if has(t, ["你是谁", "你叫什么", "名字"]) { return Reply(text: "我是\(petName)，一直陪着你打字的那个～", trigger: "chat_happy", action: nil) }
        if has(t, ["天气"]) { return Reply(text: "我不联网，看不到外面的天气呢，你那边怎么样？", trigger: "chat", action: nil) }
        if has(t, ["安静", "别说话", "闭嘴"]) {
            PetWindowController.quietMode = true
            return Reply(text: "好的，我安静陪着你 🤫", trigger: "chat", action: nil)
        }
        if has(t, ["晚安", "睡了", "去睡"]) { return Reply(text: "晚安，做个好梦 🌙", trigger: nil, action: "yawn") }
        if has(t, ["早安", "早上好"]) { return Reply(text: "早上好呀！今天也一起加油", trigger: nil, action: "wave") }
        if has(t, ["你好", "嗨", "hello", "hi"]) && t.count <= 6 { return Reply(text: "你好呀～找我聊天吗？", trigger: nil, action: "wave") }
        return nil
    }

    private static func fallback(_ text: String) -> Reply {
        let mood = mood(of: text)
        let lines: [String]
        switch mood {
        case "chat_sad": lines = ["抱抱你，先歇一会儿吧", "辛苦啦，我陪着你", "不开心的事说出来会好一点"]
        case "chat_happy": lines = ["真好！我也跟着开心", "嘿嘿，太好了", "好耶！"]
        default:
            lines = text.hasSuffix("?") || text.hasSuffix("？") || text.contains("吗")
                ? ["这个我也不太懂…你觉得呢？", "嗯…让我想想", "好问题！"]
                : ["嗯嗯，我在听", "然后呢？", "原来是这样～", "说得对！"]
        }
        return Reply(text: lines.randomElement() ?? "嗯嗯", trigger: mood, action: nil)
    }
}

// MARK: - 对话气泡

/// 不激活应用也能成为 key 窗口的面板（像 Spotlight）：聊天时不打断你当前的应用。
private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PetChatController {
    static let shared = PetChatController()

    private var panel: ChatPanel?
    private let transcript = NSTextView()
    private let composer = ChatComposerView()
    private let candidates = NSTextField(labelWithString: "")
    private let thinking = NSTextField(labelWithString: "")
    private var history: [(fromUser: Bool, text: String)] = []
    private var openedAutomatically = false
    private var sentSinceOpen = false

    var isOpen: Bool { panel?.isVisible == true }

    /// 打开对话（prefill = 自动进入时已经敲下的拼音字母，接着打不丢字）。
    func open(prefill: String = "", automatic: Bool = false) {
        let panel = ensurePanel()
        openedAutomatically = automatic
        sentSinceOpen = false
        composer.reset()
        prefill.forEach { composer.feed($0) }
        position(panel)
        if history.isEmpty {
            append(fromUser: false, text: automatic ? "我在听～直接打字就能和我聊天" : "想聊点什么？")
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(composer)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        PetWindowController.shared.chatOpened()
    }

    /// 展示一段结果（链接总结 / 译文 / 菜谱结果）：以桌宠的口吻放进对话气泡，可滚动、可复制。
    func present(title: String, body: String) {
        let panel = ensurePanel()
        openedAutomatically = false
        sentSinceOpen = true
        append(fromUser: false, text: "【\(title)】\n\(body)")
        if !panel.isVisible {
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(composer)
        }
        PetWindowController.shared.petSpeak(seconds: 2)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        // 自动弹出、一句没聊就关：说明是误触发，暂停自动进入一会儿
        if openedAutomatically && !sentSinceOpen { PetChatAutoTrigger.shared.snooze(minutes: 10) }
        panel.orderOut(nil)
    }

    private func ensurePanel() -> ChatPanel {
        if let panel { return panel }
        let size = NSSize(width: 300, height: 260)
        let panel = ChatPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "和\(PetWindowController.shared.petName)聊天")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(labelWithString: "回车发送 · Esc 关闭")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [title, NSView(), hint])
        header.orientation = .horizontal

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 2, height: 4)
        transcript.font = .systemFont(ofSize: 12.5)
        transcript.autoresizingMask = [.width]
        scroll.documentView = transcript

        thinking.font = .systemFont(ofSize: 11)
        thinking.textColor = .secondaryLabelColor
        candidates.font = .systemFont(ofSize: 12)
        candidates.textColor = .secondaryLabelColor
        candidates.lineBreakMode = .byTruncatingTail
        composer.onChange = { [weak self] in self?.refreshComposer() }
        composer.onSend = { [weak self] text in self?.send(text) }
        composer.onCancel = { [weak self] in self?.close() }

        let stack = NSStackView(views: [header, scroll, thinking, composer, candidates])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            composer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            candidates.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            composer.heightAnchor.constraint(equalToConstant: 30),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        panel.contentView = box
        self.panel = panel
        return panel
    }

    /// 放在桌宠旁边：上方放得下就放上方，否则放下方；水平夹在屏幕内。
    private func position(_ panel: NSPanel) {
        let pet = PetWindowController.shared.petFrame ?? NSRect(x: 200, y: 200, width: 1, height: 1)
        let screen = (NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main)?.visibleFrame ?? pet
        let size = panel.frame.size
        var x = pet.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        var y = pet.maxY + 8
        if y + size.height > screen.maxY { y = max(screen.minY + 8, pet.minY - size.height - 8) }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func refreshComposer() {
        let list = composer.candidateTexts.prefix(6).enumerated().map { "\($0.offset + 1).\($0.element)" }
        candidates.stringValue = list.joined(separator: "  ")
    }

    private func append(fromUser: Bool, text: String) {
        history.append((fromUser, text))
        if history.count > 30 { history.removeFirst(history.count - 30) }
        let who = fromUser ? "你" : PetWindowController.shared.petName
        let line = NSMutableAttributedString(string: "\(who)：", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: fromUser ? NSColor.secondaryLabelColor : NSColor.controlAccentColor,
        ])
        line.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor,
        ]))
        transcript.textStorage?.append(line)
        transcript.scrollToEndOfDocument(nil)
    }

    private func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        sentSinceOpen = true
        append(fromUser: true, text: message)
        PetWindowController.shared.chatHeard()
        thinking.stringValue = "\(PetWindowController.shared.petName)正在想…"
        let past = Array(history.dropLast())
        PetChatBrain.reply(to: message, history: past, petName: PetWindowController.shared.petName) { [weak self] reply in
            guard let self else { return }
            self.thinking.stringValue = ""
            self.append(fromUser: false, text: reply.text)
            PetWindowController.shared.chatReplied(reply)
        }
    }
}

// MARK: - 气泡里的拼音输入

/// 对话气泡的输入行：直接用松萝内核组字（输入法进程自己的窗口不走 IMK），
/// 字母进拼音、空格 / 数字选词、回车发送（组字中回车 = 原样上屏字母）、Esc 关闭。
final class ChatComposerView: NSView {
    var onChange: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let engine = LianaEngine(mode: UserDefaults.standard.string(forKey: "LianaMode") ?? "pinyin")
    private var text = ""
    private let label = NSTextField(labelWithString: "")
    private static let punctuation: [Character: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；", "~": "～", "(": "（", ")": "）",
    ]

    var candidateTexts: [String] { engine.composition.candidates.map(\.text) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    /// 不要系统输入法介入（按键由这里自己组字）
    override var inputContext: NSTextInputContext? { nil }

    func reset() {
        engine.clear()
        text = ""
        render()
    }

    func feed(_ ch: Character) {
        if !engine.feed(ch) { text.append(ch) }
        render()
    }

    override func keyDown(with event: NSEvent) {
        let composing = engine.hasComposition
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", let paste = NSPasteboard.general.string(forType: .string) {
                commitTop()
                text += paste.replacingOccurrences(of: "\n", with: " ")
                render()
            } else if event.charactersIgnoringModifiers == "w" {
                onCancel?()
            }
            return
        }
        switch event.keyCode {
        case 53:   // Esc
            if composing { engine.clear(); render() } else { onCancel?() }
            return
        case 36, 76:   // Return
            if composing {
                if let raw = engine.commitRaw() { text += raw }
                render()
            } else {
                let message = text
                text = ""
                render()
                onSend?(message)
            }
            return
        case 51:   // Delete
            if composing { engine.backspace() } else if !text.isEmpty { text.removeLast() }
            render()
            return
        case 49:   // Space
            if composing { commitTop() } else { text += " " }
            render()
            return
        default:
            break
        }
        guard let ch = event.characters?.first else { return }
        if composing, let digit = ch.wholeNumberValue, (1...9).contains(digit) {
            if let picked = engine.select(digit - 1) { text += picked }
            render()
            return
        }
        if ch.isLetter, ch.isASCII, ch.isLowercase {
            feed(ch)
            return
        }
        if composing { commitTop() }
        text += Self.punctuation[ch] ?? String(ch)
        render()
    }

    private func commitTop() {
        guard engine.hasComposition else { return }
        if let picked = engine.select(0) { text += picked } else if let raw = engine.commitRaw() { text += raw }
    }

    private func render() {
        let comp = engine.composition
        let preedit = comp.preedit.isEmpty ? comp.raw : comp.preedit
        let out = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        if !preedit.isEmpty {
            out.append(NSAttributedString(string: preedit, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.controlAccentColor,
            ]))
        }
        if text.isEmpty && preedit.isEmpty {
            out.append(NSAttributedString(string: "说点什么…（拼音直接打，回车发送）", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.placeholderTextColor,
            ]))
        }
        label.attributedStringValue = out
        onChange?()
    }
}

// MARK: - 自动进入对话模式

/// 不在任何输入框里却在敲字母 → 打开对话气泡（把刚敲的字母带进去）。
/// 需要辅助功能权限：只判断焦点是不是输入框，不记录按键。默认关闭。
final class PetChatAutoTrigger {
    static let shared = PetChatAutoTrigger()
    private static let key = "LianaPetChatAuto"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            if newValue { requestPermissionIfNeeded() }
            shared.refresh()
        }
    }

    static var permitted: Bool { AXIsProcessTrusted() }

    /// 弹系统授权框（辅助功能），用户在系统设置里勾选松萝后生效。
    static func requestPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private var monitor: Any?
    private var buffer: [(at: Date, ch: Character)] = []
    private var snoozeUntil = Date.distantPast
    private var permissionTimer: Timer?

    /// 文本输入类焦点：在这些里面打字就是在输入，不打扰
    private let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    /// 「输入字母即跳转 / 快捷键」的焦点：Finder 列表、网页阅读等，也不打扰
    private let typeToSelectRoles: Set<String> = ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid", "AXWebArea"]

    func refresh() {
        let shouldRun = Self.enabled && PetWindowController.isEnabled
        if shouldRun && Self.permitted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event)
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            buffer.removeAll()
            // 刚开启、还在等用户去系统设置授权：每 3 秒看一次，授权后自动生效
            if shouldRun, permissionTimer == nil {
                let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                    if Self.permitted { self?.refresh() }
                }
                RunLoop.main.add(timer, forMode: .common)
                permissionTimer = timer
            }
        }
    }

    func snooze(minutes: Double) {
        snoozeUntil = Date().addingTimeInterval(minutes * 60)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .function])
        guard flags.isEmpty, let ch = event.charactersIgnoringModifiers?.first,
              ch.isASCII, ch.isLetter, ch.isLowercase else {
            buffer.removeAll()
            return
        }
        let now = Date()
        buffer = buffer.filter { now.timeIntervalSince($0.at) < 1.5 } + [(now, ch)]
        guard buffer.count >= 3, now > snoozeUntil, !PetChatController.shared.isOpen else { return }
        let letters = String(buffer.map(\.ch))
        buffer.removeAll()
        guard !focusIsBusy(), !frontmostExcluded() else { return }
        DispatchQueue.main.async {
            PetChatController.shared.open(prefill: letters, automatic: true)
        }
    }

    /// 焦点在输入框、或在「打字即跳转」的列表 / 网页里 → 不是想聊天。
    private func focusIsBusy() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        let el = element as! AXUIElement
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        if textRoles.contains(role) || typeToSelectRoles.contains(role) { return true }
        // 网页里的可编辑区域（contenteditable）等
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXEditableAncestor" as CFString, &editable) == .success, editable != nil { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           role != "AXSlider", role != "AXScrollBar" { return true }
        return false
    }

    /// 游戏类应用不打扰（它们用字母键操作）
    private func frontmostExcluded() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        if let url = app.bundleURL, let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String,
           category.contains("games") { return true }
        return false
    }
}
