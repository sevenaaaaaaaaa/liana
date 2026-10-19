import AppKit
import InputMethodKit

/// 输入控制器：把按键翻译为内核调用，并负责预编辑串与候选窗。
/// 不做任何网络访问；预编辑内容只在内存中，提交后立即释放。
@objc(LianaInputController)
final class LianaInputController: IMKInputController {
    private let engine = LianaEngine(
        mode: UserDefaults.standard.string(forKey: "LianaMode") ?? LianaMode.pinyin.rawValue
    )
    private let window = CandidateWindowController()
    private let store = EncryptedStore.shared
    private let clipboard = ClipboardMonitor.shared
    private let voice = VoiceInputController.shared
    private var voicePartial = ""
    /// 边说边落字：语音占用预编辑时为 true（update() 不得清、候选窗不得关）。
    private var voiceMarked = false
    /// 同声传译目标（"en"/"ja"）；nil = 普通语音。武装后跨语句保持，直到关闭/纯语音启动。
    private var translateTarget: String?
    /// 长句 AI 重排：停顿后才发起；同一串输入只排一次
    private var rerankWork: DispatchWorkItem?
    private var rerankedRaw = ""
    /// 识别 final 已到、原文待确认上屏（同传译文异步生成中/已生成）。
    private var voiceSettledSource: String?
    private var translatedText: String?
    private var translateFailed = false
    private var translateFailedOnce = false
    private var translateGeneration = 0
    private var translateWork: DispatchWorkItem?
    /// 已定句段的译文缓存：长句流式时只重译尾段。
    private var segmentCache: [String: String] = [:]
    /// 普通语音 final 后的标点二次确认原文；nil = 无待确认（同传不走此状态）。
    private var voicePunctPending: String?
    /// 标点候选标签：下标 0 = 原样（不加标点），1... = 实际标点。
    private static let voicePunctLabels = ["原样", "。", "，", "！", "？"]
    private weak var currentClient: IMKTextInput?
    private var page = 0
    private var shiftArmed = false
    private var shiftUsed = false
    private var openDoubleQuote = true
    private var openSingleQuote = true
    /// 连按两下 `a` 的手势：上一次按 a 的时间（系统 uptime）。
    private var lastAAt: TimeInterval = 0
    /// 网址模式：所有按键直通系统，Esc 退出。
    private var urlMode = false
    /// 表情模式（斗图）之前的中文模式，Esc 时恢复。
    private var modeBeforeEmoji: String?
    private var lastChineseMode: LianaMode = {
        UserDefaults.standard.string(forKey: "LianaLastChineseMode")
            .flatMap(LianaMode.init(rawValue:))
            .flatMap { $0.isChinese ? $0 : nil } ?? .pinyin
    }()
    /// 当前活跃会话：桌宠点按/菜单动作只作用在它身上（IMK 每个客户端一个控制器实例）。
    private static weak var activeController: LianaInputController?
    /// 统计与发呆跟踪：上一次按键事件的时间戳。
    private var lastEventAt: TimeInterval?
    private var digestChecked = false

    /// 统计存储。
    private let stats = PetStats.shared

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        if !store.userModelTsv.isEmpty {
            _ = engine.importUserModel(store.userModelTsv)
        }
        if !store.evolutionTsv.isEmpty {
            _ = engine.importEvolution(store.evolutionTsv)
        }
        if !store.nutritionTsv.isEmpty {
            _ = engine.nutritionImport(store.nutritionTsv)
        }
        engine.setTraditional(UserDefaults.standard.bool(forKey: Self.traditionalKey))
        observePetActions()
    }

    /// 桌宠与菜单的跨实例动作走通知；只有活跃会话响应。
    private func observePetActions() {
        NotificationCenter.default.addObserver(
            forName: .petToggleLanguage, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, Self.activeController === self else { return }
            self.toggleLanguage()
            self.refreshPetModeLabel()
        }
        NotificationCenter.default.addObserver(
            forName: .petTogglePunctuation, object: nil, queue: .main
        ) { [weak self] _ in
            guard Self.activeController === self else { return }
            let key = "LianaForceHalfPunctuation"
            let on = !UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(on, forKey: key)
            PetWindowController.shared.showToast(on ? "已强制半角标点（全局）" : "标点恢复按应用自动", duration: 4)
        }
        NotificationCenter.default.addObserver(
            forName: .petShowStats, object: nil, queue: .main
        ) { [weak self] _ in
            guard Self.activeController === self else { return }
            PetWindowController.shared.showStatsCard(yesterday: true)
        }
        // 喂食窗改了营养库：整体重导入（营养库按会话持有，账本才是进程单例）
        NotificationCenter.default.addObserver(
            forName: .nutritionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.nutritionForgetAll()
            _ = self.engine.nutritionImport(self.store.nutritionTsv)
        }
        // 功能面板 / 设置中心：会话级动作只交给活跃会话
        NotificationCenter.default.addObserver(
            forName: .lianaControllerAction, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, Self.activeController === self,
                  let action = note.userInfo?["action"] as? String else { return }
            self.performControllerAction(action)
        }
        // 设置中心切了繁体输出：所有会话同步
        NotificationCenter.default.addObserver(
            forName: .lianaTraditionalChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.engine.setTraditional(UserDefaults.standard.bool(forKey: Self.traditionalKey))
        }
        // 设置中心改了默认模式：所有会话同步（下次激活即是新模式）
        NotificationCenter.default.addObserver(
            forName: .lianaModeChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["mode"] as? String else { return }
            self.applyMode(id, announce: false, learn: false)
        }
        // 权限中心切了知你学习开关：活跃会话即时重同步
        NotificationCenter.default.addObserver(
            forName: .evolutionToggled, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncEvolutionContext()
        }
    }

    private func refreshPetModeLabel() {
        let chinese = (LianaMode(rawValue: engine.mode) ?? .pinyin).isChinese
        PetWindowController.shared.setModeLabel(chinese: chinese)
    }

    /// 主键盘数字 1–9 的 keyCode（功能面板直达用）。
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    /// 繁体输出开关（跨会话记住）。
    static let traditionalKey = "LianaTraditional"

    required init?(coder: NSCoder) { nil }

    // MARK: - 模式菜单

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "松萝")
        let header = NSMenuItem(title: "输入模式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let current = engine.mode
        for mode in LianaMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode.rawValue == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 常用功能直接露在第一层；其余配置统一收进「松萝设置…」
        let panelItem = NSMenuItem(title: "功能面板…", action: #selector(openQuickPanel(_:)), keyEquivalent: "`")
        panelItem.keyEquivalentModifierMask = [.control]
        panelItem.target = self
        menu.addItem(panelItem)

        let shot = NSMenuItem(title: "截图快速学习", action: #selector(startScreenshotLearn(_:)), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        let voiceItem = NSMenuItem(
            title: voice.isListening ? "停止语音输入" : "语音输入",
            action: #selector(toggleVoice(_:)),
            keyEquivalent: ""
        )
        voiceItem.target = self
        voiceItem.state = voice.isListening ? .on : .off
        menu.addItem(voiceItem)

        let interp = NSMenuItem(title: "同声传译", action: nil, keyEquivalent: "")
        interp.submenu = interpretSubmenu()
        menu.addItem(interp)

        menu.addItem(.separator())
        let pet = NSMenuItem(title: "桌宠", action: #selector(togglePetMode(_:)), keyEquivalent: "")
        pet.target = self
        pet.state = PetWindowController.isEnabled ? .on : .off
        menu.addItem(pet)
        let trad = NSMenuItem(title: "繁体输出", action: #selector(toggleTraditional(_:)), keyEquivalent: "")
        trad.target = self
        trad.state = engine.isTraditional ? .on : .off
        menu.addItem(trad)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "松萝设置…", action: #selector(openSettingsCenter(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: "检查更新…", action: #selector(openUpdates(_:)), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        return menu
    }

    private func backupSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "备份与恢复")
        for (title, action) in [
            ("导出加密备份…", #selector(exportEncryptedBackup(_:))),
            ("导出明文备份…", #selector(exportPlainBackup(_:))),
            ("从备份恢复…", #selector(restoreBackup(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        let note = NSMenuItem(title: "（只含用户词与短语，不含剪切板）", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(.separator())
        submenu.addItem(note)
        return submenu
    }

    private func clipboardSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "剪切板历史")
        if clipboard.isEnabled {
            if store.clipboard.isEmpty {
                let empty = NSMenuItem(title: "（暂无记录）", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            } else {
                for item in store.clipboard.prefix(8) {
                    let firstLine = item.text.split(separator: "\n").first.map(String.init) ?? item.text
                    let title = firstLine.count > 26 ? String(firstLine.prefix(26)) + "…" : firstLine
                    let entry = NSMenuItem(title: title, action: #selector(insertClipboardItem(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = item.text
                    submenu.addItem(entry)
                }
            }
            submenu.addItem(.separator())
            let off = NSMenuItem(title: "关闭剪切板记录", action: #selector(disableClipboardRecording(_:)), keyEquivalent: "")
            off.target = self
            submenu.addItem(off)
        } else {
            let on = NSMenuItem(title: "开启剪切板记录…", action: #selector(openClipboardWindow(_:)), keyEquivalent: "")
            on.target = self
            submenu.addItem(on)
        }
        let open = NSMenuItem(title: "打开剪切板历史…", action: #selector(openClipboardWindow(_:)), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        return submenu
    }

    @objc private func insertClipboardItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        if let client = currentClient {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            clipboard.ignore(text)
        }
    }

    @objc private func openClipboardWindow(_ sender: Any) {
        ClipboardWindowController.shared.show()
    }

    @objc private func disableClipboardRecording(_ sender: Any) {
        clipboard.setEnabled(false)
        let alert = NSAlert()
        alert.messageText = "已关闭剪切板记录"
        alert.informativeText = "已有历史保留在本地加密文件中，可在「剪切板历史…」中查看或清空。"
        alert.runModal()
    }

    @objc private func openQuickPanel(_ sender: Any) {
        showQuickPanel()
    }

    @objc private func startScreenshotLearn(_ sender: Any) {
        LianaActions.perform(.screenshotLearn)
    }

    @objc private func openSettingsCenter(_ sender: Any) {
        SettingsCenter.shared.show()
    }

    @objc private func openUpdates(_ sender: Any) {
        SettingsCenter.shared.show(section: .about)
    }

    /// 功能面板贴着光标弹出，带上本会话的语音 / 同传 / 模式状态。
    private func showQuickPanel(toggle: Bool = false) {
        let caret = activeClient().flatMap { caretRect($0) }
        let listening = voice.isListening || voiceSettledSource != nil
        if toggle {
            QuickPanelController.shared.toggle(near: caret, mode: engine.mode, listening: listening, interpret: translateTarget)
        } else {
            QuickPanelController.shared.show(near: caret, mode: engine.mode, listening: listening, interpret: translateTarget)
        }
    }

    /// 功能面板 / 设置中心发来的会话级动作（只有活跃会话执行）。
    private func performControllerAction(_ action: String) {
        switch action {
        case "voice":
            toggleVoice(NSMenuItem())
        case "interpret-en", "interpret-ja", "interpret-off":
            let item = NSMenuItem()
            item.representedObject = String(action.dropFirst("interpret-".count))
            selectInterpret(item)
        default:
            if action.hasPrefix("mode:") {
                applyMode(String(action.dropFirst("mode:".count)), announce: true)
            }
        }
    }

    /// 切换输入模式（菜单 / 功能面板 / 设置中心共用）。
    private func applyMode(_ id: String, announce: Bool, learn: Bool = true) {
        guard let mode = LianaMode(rawValue: id) else { return }
        modeBeforeEmoji = nil
        engine.setMode(id)
        if mode.isChinese { lastChineseMode = mode }
        persist(mode: mode)
        if learn {
            recordModeSignal(strong: true)
        }
        if Self.activeController === self {
            refreshPetModeLabel()
        }
        if announce {
            GlassToast.shared.show("已切换到 \(mode.title)", symbol: "keyboard", duration: 1.6)
        }
    }

    @objc private func toggleTraditional(_ sender: NSMenuItem) {
        let on = !engine.isTraditional
        engine.setTraditional(on)
        UserDefaults.standard.set(on, forKey: Self.traditionalKey)
        sender.state = on ? .on : .off
        if let client = currentClient {
            update(client)
        }
    }

    @objc private func exportEncryptedBackup(_ sender: Any) {
        syncUserModel()
        BackupManager.exportEncrypted(engine: engine)
    }

    @objc private func exportPlainBackup(_ sender: Any) {
        syncUserModel()
        BackupManager.exportPlain(engine: engine)
    }

    @objc private func restoreBackup(_ sender: Any) {
        BackupManager.restore(engine: engine, store: store)
    }

    /// 导出前把两边对齐：先把本会话的学习结果并进落盘数据，再整份读回会话，
    /// 免得导出的备份缺了别的窗口刚学到的词。
    private func syncUserModel() {
        persistUserModel()
        if !store.userModelTsv.isEmpty {
            _ = engine.importUserModel(store.userModelTsv)
        }
    }

    @objc private func togglePetMode(_ sender: NSMenuItem) {
        PetWindowController.setEnabled(!PetWindowController.isEnabled)
        sender.state = PetWindowController.isEnabled ? .on : .off
    }

    @objc private func toggleAppModeMemory(_ sender: NSMenuItem) {
        AppModeMemory.shared.isEnabled.toggle() // 关闭时顺带清空学习结果
        sender.state = AppModeMemory.shared.isEnabled ? .on : .off
    }

    @objc private func forgetAppModeMemory(_ sender: NSMenuItem) {
        AppModeMemory.shared.forget(appId: currentAppId)
    }

    /// 皮肤子菜单：跟随系统 + 社区皮肤包。
    private func skinSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "皮肤")
        let active = ThemeStore.activeId
        let system = NSMenuItem(title: "跟随系统", action: #selector(selectSkin(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = active.isEmpty ? .on : .off
        submenu.addItem(system)
        for pack in ThemeStore.availableSkins() {
            let item = NSMenuItem(
                title: "\(pack.name)（v\(pack.version)）",
                action: #selector(selectSkin(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pack.id
            item.state = pack.id == active ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ThemeStore.activeId = id
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }

    /// 桌宠形象子菜单：只保留形象包（内置 emoji 已下线）。
    private func petSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "桌宠形象")
        let active = PetWindowController.activePackId

        let framingMenu = NSMenu(title: "画幅")
        for (title, value) in [("全身（显身材）", "full"), ("半身（看表情）", "bust")] {
            let item = NSMenuItem(title: title, action: #selector(selectPetFraming(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = PetWindowController.framingOverride == value ? .on : .off
            framingMenu.addItem(item)
        }
        let zoomMenu = NSMenu(title: "缩放")
        for value in [0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5] {
            let item = NSMenuItem(title: String(format: "%.0f%%", value * 100), action: #selector(selectPetZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(PetWindowController.zoomOverride - value) < 0.01 ? .on : .off
            zoomMenu.addItem(item)
        }
        let framingItem = NSMenuItem(title: "画幅", action: nil, keyEquivalent: "")
        framingItem.submenu = framingMenu
        submenu.addItem(framingItem)
        let zoomItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        zoomItem.submenu = zoomMenu
        submenu.addItem(zoomItem)

        let catalogItem = NSMenuItem(title: "形象目录…", action: #selector(openPetCatalog(_:)), keyEquivalent: "")
        catalogItem.target = self
        submenu.addItem(catalogItem)

        let importItem = NSMenuItem(title: "导入 VRM 模型…", action: #selector(importVRM(_:)), keyEquivalent: "")
        importItem.target = self
        submenu.addItem(importItem)

        let cloudItem = NSMenuItem(title: "图片生成 VRM（云端 VTubeMe）…", action: #selector(openAvatarCreator(_:)), keyEquivalent: "")
        cloudItem.target = self
        submenu.addItem(cloudItem)

        let live2dItem = NSMenuItem(title: "导入 Live2D 模型（文件夹/ZIP）…", action: #selector(importLive2D(_:)), keyEquivalent: "")
        live2dItem.target = self
        submenu.addItem(live2dItem)
        let live2dCoreItem = NSMenuItem(title: "获取 Live2D Cubism Core…（官网）", action: #selector(openLive2DCorePage(_:)), keyEquivalent: "")
        live2dCoreItem.target = self
        submenu.addItem(live2dCoreItem)
        let live2dDirItem = NSMenuItem(title: "打开 Core 放置目录…", action: #selector(openLive2DCoreFolder(_:)), keyEquivalent: "")
        live2dDirItem.target = self
        submenu.addItem(live2dDirItem)

        submenu.addItem(.separator())
        let packHeader = NSMenuItem(title: "形象包（未装的点一下即下载）", action: nil, keyEquivalent: "")
        packHeader.isEnabled = false
        submenu.addItem(packHeader)
        // 已安装：直接切换
        let installed = PetWindowController.availablePets()
        let installedIds = Set(installed.map { $0.id })
        for pack in installed {
            let item = NSMenuItem(
                title: "\(pack.name)（v\(pack.version)）",
                action: #selector(selectPetPack(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pack.id
            item.toolTip = pack.description
            item.state = pack.id == active ? .on : .off
            submenu.addItem(item)
        }
        // 目录中未安装：点击下载（sha256 校验）并切换
        for entry in PetCatalogStore.entries() where !installedIds.contains(entry.id) {
            let item = NSMenuItem(
                title: "\(entry.name)（未装 · \(entry.sizeText)）",
                action: #selector(downloadCatalogPack(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            item.toolTip = "\(entry.license) · \(entry.author ?? "")；点击下载并切换"
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectPetPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSLog("松萝桌宠: 菜单选择形象包 → \(id)")
        PetWindowController.activePackId = id
        if !PetWindowController.isEnabled {
            PetWindowController.setEnabled(true)
        }
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
        PetWindowController.shared.showToast("已切换桌宠形象：\(sender.title)", duration: 2.5)
    }

    @objc private func selectPetFraming(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        PetWindowController.framingOverride = value
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == value ? .on : .off
        }
    }

    @objc private func selectPetZoom(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        PetWindowController.zoomOverride = value
        for item in sender.menu?.items ?? [] {
            item.state = abs(((item.representedObject as? Double) ?? -1) - value) < 0.01 ? .on : .off
        }
    }

    // MARK: - 同声传译

    private func interpretSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "同声传译")
        for (title, target) in [("译成英文", "en"), ("译成日文", "ja")] {
            let item = NSMenuItem(title: title, action: #selector(selectInterpret(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            item.state = translateTarget == target ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let off = NSMenuItem(title: "关闭同传", action: #selector(selectInterpret(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = "off"
        submenu.addItem(off)
        return submenu
    }

    @objc private func selectInterpret(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "off" {
            translateTarget = nil
            TranslateClient.shared.stop()
            cancelVoiceUtterance()
            PetWindowController.shared.showToast("同声传译已关闭", duration: 2)
            return
        }
        guard TranslateClient.findRuntime() != nil else {
            PetWindowController.shared.showToast(
                "未检测到 llama.cpp：终端执行 brew install llama.cpp 后重试", duration: 8
            )
            return
        }
        guard TranslateClient.translateModelPath() != nil else {
            PetWindowController.shared.showToast(
                "缺翻译模型：正在打开「AI 增强」，下载 Gemma 3 270M（约 278MB）", duration: 8
            )
            SettingsCenter.shared.show(section: .ai)
            return
        }
        cancelVoiceUtterance()
        translateTarget = raw
        translateFailed = false
        translateFailedOnce = false
        segmentCache.removeAll()
        PetWindowController.shared.showToast(
            raw == "ja" ? "同声传译 → 日文（端上）" : "同声传译 → 英文（端上）", duration: 2
        )
        if !voice.isListening {
            startVoice()
        }
        TranslateClient.shared.warmup()
    }

    /// 语音输入菜单：停止=取消本次语句（同传武装保留）；启动=纯语音（解除武装）。
    @objc private func toggleVoice(_ sender: NSMenuItem) {
        if voice.isListening || voiceSettledSource != nil {
            cancelVoiceUtterance()
            return
        }
        if translateTarget != nil {
            translateTarget = nil
            TranslateClient.shared.stop()
        }
        startVoice()
    }

    private func startVoice() {
        voicePunctPending = nil
        voice.onPartial = { [weak self] text in
            guard let self, self.voice.isListening else { return }
            PetWindowController.shared.voiceHeard()
            self.voicePartial = text
            guard let client = self.activeClient() else { return }
            if self.engine.hasComposition {
                // 打字优先：不抢拼音的预编辑，只在旁边提示
                self.window.presentHint("🎤 " + text, near: self.caretRect(client))
                return
            }
            // 边说边落字：实时写进预编辑（强调色下划线）
            let attributed = NSAttributedString(string: text, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.controlAccentColor,
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            ])
            client.setMarkedText(
                attributed,
                selectionRange: NSRange(location: attributed.length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            self.voiceMarked = true
            self.presentVoiceCandidates(source: text, client: client)
            self.scheduleTranslation()
        }
        voice.onFinal = { [weak self] text in
            guard let self, self.voice.isListening else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = value.isEmpty ? self.voicePartial : value
            guard !source.isEmpty else {
                if self.voice.isListening { self.voice.stop() }
                self.voicePartial = ""
                return
            }
            if self.translateTarget != nil {
                // 同传：原文留在预编辑待确认，译文异步生成（VoiceInput 随后停麦）
                self.voicePartial = source
                self.voiceSettledSource = source
                self.translatedText = nil
                self.translateFailed = false
                guard let client = self.activeClient() else {
                    self.cancelVoiceUtterance()
                    return
                }
                self.presentVoiceCandidates(source: source, client: client)
                self.scheduleTranslation(immediate: true)
                return
            }
            guard !self.engine.hasComposition, let client = self.activeClient() else {
                if self.voice.isListening { self.voice.stop() }
                self.voicePartial = ""
                return
            }
            // 标点二次确认：候选 [原样, 。, ，, ！, ?]，空格/回车=原样，数字选标点
            self.voicePunctPending = source
            self.voiceSettledSource = source
            self.voicePartial = source
            self.presentVoiceCandidates(source: source, client: client)
        }
        voice.onStatus = { message in
            PetWindowController.shared.showToast(message, duration: 4)
        }
        voice.start()
    }

    private func activeClient() -> IMKTextInput? {
        currentClient ?? (client as? IMKTextInput)
    }

    /// 停听 + 清本次语句状态（不打断同传武装与热引擎）。
    private func stopListeningAndVoiceState() {
        if voice.isListening { voice.stop() }
        voicePartial = ""
        voiceSettledSource = nil
        voicePunctPending = nil
        translatedText = nil
        translateFailed = false
        translateGeneration += 1          // 丢弃在途翻译回包
        translateWork?.cancel()
        translateWork = nil
        segmentCache.removeAll()
    }

    /// 取消本次语句：停听、丢译文、清预编辑、关候选窗（同传武装保留）。
    private func cancelVoiceUtterance() {
        stopListeningAndVoiceState()
        if voiceMarked, let client = activeClient() {
            clearMarkedText(client)
            voiceMarked = false
        }
        window.hide()
    }

    /// 候选呈现：同传 = [译文, 原文]；普通语音 = [原文]。空译文时标「翻译中…」。
    private func presentVoiceCandidates(source: String, client: IMKTextInput) {
        var candidates: [Candidate] = []
        if voicePunctPending != nil {
            candidates = Self.voicePunctLabels.map {
                Candidate(text: $0, consumed: 0, kind: "voice", comment: nil)
            }
        } else if translateTarget != nil, let translated = translatedText, !translated.isEmpty {
            candidates.append(Candidate(
                text: translated, consumed: 0, kind: "voice",
                comment: translateTarget == "ja" ? "日译" : "英译"
            ))
            candidates.append(Candidate(text: source, consumed: 0, kind: "voice", comment: "原文"))
        } else {
            let comment: String
            if translateTarget != nil {
                comment = translateFailed ? "翻译不可用" : "翻译中…"
            } else {
                comment = "语音"
            }
            candidates.append(Candidate(text: source, consumed: 0, kind: "voice", comment: comment))
        }
        page = 0
        window.present(candidates: candidates, page: 0, near: caretRect(client)) { [weak self, weak client] index in
            guard let self, let client else { return }
            _ = self.commitVoiceSelection(index: index, client: client)
        }
    }

    // MARK: - 流式翻译（尾段重译 + 已定段缓存）

    private func scheduleTranslation(immediate: Bool = false) {
        guard translateTarget != nil else { return }
        translateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runTranslation() }
        translateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0.05 : 0.5), execute: work)
    }

    private func runTranslation() {
        guard let target = translateTarget else { return }
        let source = voiceSettledSource ?? voicePartial
        guard !source.isEmpty else { return }
        translateGeneration += 1
        let generation = translateGeneration

        let pivot = source.lastIndex(where: { "。！？；，、\n".contains($0) })
        let head = pivot.map { String(source[source.startIndex...$0]) } ?? ""
        let tail = pivot.map { String(source[source.index(after: $0)...]) } ?? source

        func finish(_ merged: String?) {
            guard translateGeneration == generation else { return }
            translatedText = merged.flatMap { $0.isEmpty ? nil : $0 }
            if let client = activeClient(), !engine.hasComposition,
               voice.isListening || voiceSettledSource != nil {
                presentVoiceCandidates(source: source, client: client)
            }
        }

        func translateTail(headTranslation: String?) {
            let piece = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else {
                finish(headTranslation)
                return
            }
            TranslateClient.shared.translate(piece, target: target) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.translateGeneration == generation else { return }
                    switch result {
                    case .success(let translated):
                        self.translateFailed = false
                        let merged: String
                        if let headTranslation, !headTranslation.isEmpty {
                            merged = headTranslation + " " + translated
                        } else {
                            merged = translated
                        }
                        finish(merged)
                    case .failure(let error):
                        self.handleTranslateFailure(error)
                        finish(headTranslation)
                    }
                }
            }
        }

        let headTrimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if headTrimmed.isEmpty {
            translateTail(headTranslation: nil)
        } else if let cached = segmentCache[headTrimmed] {
            translateTail(headTranslation: cached)
        } else {
            TranslateClient.shared.translate(headTrimmed, target: target) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.translateGeneration == generation else { return }
                    switch result {
                    case .success(let translated):
                        self.translateFailed = false
                        self.segmentCache[headTrimmed] = translated
                        translateTail(headTranslation: translated)
                    case .failure(let error):
                        self.handleTranslateFailure(error)
                        translateTail(headTranslation: nil)
                    }
                }
            }
        }
    }

    private func handleTranslateFailure(_ error: Error) {
        translateFailed = true
        guard !translateFailedOnce else { return }
        translateFailedOnce = true
        PetWindowController.shared.showToast("同传引擎：\(error.localizedDescription)", duration: 6)
    }

    /// 统一的语音上屏：空格 / 数字 / 回车 / 点击候选 / 识别结束 / 打字接管都走这里。
    private func commitVoice(_ text: String, client: IMKTextInput) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListeningAndVoiceState()
        if !value.isEmpty {
            // insertText 会替换当前 marked 区域（边说边落字的内容）
            client.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            voiceMarked = false
            engine.recordCommit(value)
            persistUserModel()
            stats.recordCommit(chars: value.count, keys: 0)
            recordModeSignal(strong: false)
            PetWindowController.shared.react(.commit)
        } else if voiceMarked {
            clearMarkedText(client)
            voiceMarked = false
        }
        window.hide()
    }

    /// 按候选下标上屏：0 = 译文（就绪时），其余 = 原文；无译文时全部 = 原文。
    /// 返回 false 表示没有可上屏内容（按键应直通）。
    @discardableResult
    private func commitVoiceSelection(index: Int, client: IMKTextInput) -> Bool {
        let source = voiceSettledSource ?? voicePartial
        guard !source.isEmpty else { return false }
        if voicePunctPending != nil {
            // 0 = 原样；1... = 追加对应标点
            let labels = Self.voicePunctLabels
            let value: String
            if index > 0, labels.indices.contains(index) {
                value = source + labels[index]
            } else {
                value = source
            }
            commitVoice(value, client: client)
        } else if translateTarget != nil, let translated = translatedText, !translated.isEmpty {
            commitVoice(index == 0 ? translated : source, client: client)
        } else {
            commitVoice(source, client: client)
        }
        return true
    }

    /// 语音/同传让位给打字：先落下顶部候选再停（说→打无缝衔接）。
    private func absorbVoice(client: IMKTextInput) {
        guard commitVoiceSelection(index: 0, client: client) else {
            cancelVoiceUtterance()
            return
        }
    }

    @objc private func openPetCatalog(_ sender: Any) {
        PetCatalogWindowController.shared.show()
    }

    /// 「更多 VRM 形象」子菜单：已装的直接切换，未装的点击下载后切换。
    private func moreVRMSubmenu() -> NSMenu {
        let menu = NSMenu(title: "更多 VRM 形象")
        let installed = Set(PetWindowController.availablePets().map { $0.id })
        let entries = PetCatalogStore.entries()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "（目录为空）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for entry in entries {
            let isInstalled = installed.contains(entry.id)
            let title = isInstalled
                ? "\(entry.name)（已装，点击切换）"
                : "\(entry.name)  ·  \(entry.sizeText)"
            let item = NSMenuItem(title: title, action: #selector(downloadCatalogPack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.toolTip = "\(entry.license) · \(entry.author ?? "")"
            item.state = entry.id == PetWindowController.activePackId ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "打开形象目录…", action: #selector(openPetCatalog(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        return menu
    }

    /// 目录条目：已装则切换，未装则下载（sha256 校验）后切换。
    @objc private func downloadCatalogPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = PetCatalogStore.entries().first(where: { $0.id == id }) else { return }
        if PetWindowController.availablePets().contains(where: { $0.id == id }) {
            PetWindowController.activePackId = id
            if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
            PetWindowController.shared.showToast("已切换：\(entry.name)", duration: 2.5)
            return
        }
        PetWindowController.shared.showToast("下载 \(entry.name)（\(entry.sizeText)）…", duration: 4)
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

    /// 一键下载官方样例 VRM（用户点击才联网，sha256 校验后才安装）。
    @objc private func downloadSeedSan(_ sender: Any) {
        PetWindowController.shared.showToast("开始下载 Seed-san（约 10MB，VRM 官方样例）…", duration: 5)
        PetModelInstaller.install(
            PetModelCatalog.seedSan,
            onProgress: { _ in },
            completion: { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        PetWindowController.shared.showToast(
                            "Seed-san 已下载（sha256 校验通过）；在「桌宠形象」里可选",
                            duration: 5
                        )
                    case .failure(let error):
                        PetWindowController.shared.showToast("下载失败：\(error.localizedDescription)", duration: 6)
                    }
                }
            }
        )
    }

    /// 导入用户自己的 VRM 模型（VRoid Studio 可免费导出），生成 vrm-custom 形象包。
    @objc private func importVRM(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 VRM 模型文件（VRoid Studio 可免费导出）"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.init(filenameExtension: "vrm") ?? .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PetImporter.importVRM(from: url)
            PetWindowController.activePackId = "vrm-custom"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            PetWindowController.shared.showToast("已导入 VRM：\(url.lastPathComponent)", duration: 4)
        } catch {
            PetWindowController.shared.showToast("导入失败：\(error.localizedDescription)", duration: 6)
        }
    }

    /// 打开云端「图片 → VRM」生成窗口（B1：VTubeMe）。
    @objc private func openAvatarCreator(_ sender: Any) {
        AvatarCreatorWindowController.shared.show()
    }

    /// 导入 Live2D 模型（文件夹或 .zip）：装成 live2d-custom 形象包并切换。
    @objc private func importLive2D(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "选择 Live2D 模型文件夹（含 *.model3.json）或 .zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PetImporter.importLive2D(from: url)
            PetWindowController.activePackId = "live2d-custom"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            if PetRuntimeStore.live2DCoreAvailable() {
                PetWindowController.shared.showToast("已导入并切换 Live2D：\(url.lastPathComponent)", duration: 4)
            } else {
                PetWindowController.shared.showToast(
                    "已导入 Live2D；还缺 Cubism Core：请用「获取 Live2D Cubism Core…」下载后放进「Core 放置目录」，重启输入法生效",
                    duration: 9
                )
            }
        } catch {
            PetWindowController.shared.showToast("导入失败：\(error.localizedDescription)", duration: 6)
        }
    }

    @objc private func openLive2DCorePage(_ sender: Any) {
        if let url = URL(string: "https://www.live2d.com/en/sdk/download/web/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLive2DCoreFolder(_ sender: Any) {
        NSWorkspace.shared.open(PetRuntimeStore.userLive2DCoreDir)
    }

    @objc private func openPermissionCenter(_ sender: Any) {
        PermissionCenterWindowController.shared.show()
    }

    /// 当前前台应用画像（代码/浏览器/聊天），决定标点与手势能力；
    /// 「强制半角标点」打开时全局覆盖（快捷配置入口：桌宠右键 / 本菜单）。
    private var profile: AppProfile {
        let bundleId = currentClient?.bundleIdentifier() ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var p = AppProfile.make(bundleId: bundleId)
        if UserDefaults.standard.bool(forKey: "LianaForceHalfPunctuation") {
            p.asciiPunctuation = true
        }
        return p
    }

    @objc private func toggleHalfPunctuation(_ sender: NSMenuItem) {
        let key = "LianaForceHalfPunctuation"
        let on = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(on, forKey: key)
        sender.state = on ? .on : .off
    }

    @objc private func showYesterdayStats(_ sender: Any) {
        PetWindowController.shared.showStatsCard(yesterday: true)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let mode = LianaMode(rawValue: id)
        else { return }
        _ = mode
        applyMode(id, announce: false)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }

    @objc private func openDictionaryFolder(_ sender: Any) {
        let path = NSHomeDirectory() + "/Library/Application Support/Liana"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func persist(mode: LianaMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "LianaMode")
        UserDefaults.standard.set(lastChineseMode.rawValue, forKey: "LianaLastChineseMode")
    }

    private func toggleLanguage() {
        let current = LianaMode(rawValue: engine.mode) ?? .pinyin
        let next: LianaMode
        if current.isChinese {
            lastChineseMode = current
            next = .en
        } else {
            next = lastChineseMode
        }
        engine.setMode(next.rawValue)
        persist(mode: next)
        recordModeSignal(strong: true)
        window.hide()
        // 明确反馈：避免「以为还能打中文、其实已切英文」的困惑
        PetWindowController.shared.showToast(
            next == .en
                ? "已切到 English（再单按左 Shift 或点桌宠切回中文）"
                : "已切回中文输入",
            duration: 3
        )
    }

    /// 当前前台应用 bundle id（用于每应用中英记忆）。
    private var currentAppId: String? {
        currentClient?.bundleIdentifier() ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 把当前模式作为学习信号记录：手动切换是强信号，上屏是弱信号。
    /// 表情等特殊模式不在 LianaMode 里，不计票。
    private func recordModeSignal(strong: Bool) {
        guard let mode = LianaMode(rawValue: engine.mode) else { return }
        AppModeMemory.shared.observe(appId: currentAppId, chinese: mode.isChinese, strong: strong)
    }

    /// 切到某个应用时，按学到的偏好恢复中/英。
    /// 样本足够（强票或明显优势）才动手；单次意外切换会被下一次切回抵消，不会纠缠。
    private func restoreModeForApp() {
        guard AppModeMemory.shared.isEnabled, modeBeforeEmoji == nil, !urlMode else { return }
        guard let current = LianaMode(rawValue: engine.mode), current != .ja else { return }
        guard let preferChinese = AppModeMemory.shared.preferredChinese(appId: currentAppId) else { return }
        if preferChinese, !current.isChinese {
            engine.setMode(lastChineseMode.rawValue)
            persist(mode: lastChineseMode)
            showModeHint("已切回\(lastChineseMode.title)（记住的偏好）")
        } else if !preferChinese, current.isChinese {
            engine.setMode(LianaMode.en.rawValue)
            persist(mode: .en)
            showModeHint("已切到 English（记住的偏好）")
        }
    }

    private func showModeHint(_ text: String) {
        window.presentHint(text, near: currentClient.flatMap { caretRect($0) })
    }

    // MARK: - 事件处理

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        false
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }

        // 网址模式：按键全部直通系统（浏览器自己处理），Esc / 回车退出。
        if urlMode, event.type == .keyDown, !event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 53:
                exitURLMode()
                return true
            case 36, 76:
                exitURLMode()
                return false
            default:
                return false
            }
        }

        if event.type == .flagsChanged {
            return handleFlagsChanged(event)
        }
        guard event.type == .keyDown else { return false }
        if shiftArmed { shiftUsed = true }

        // 统计：发呆结束（≥5s）或活跃打字（<10s）；只记秒数与次数。
        let nowTick = Date().timeIntervalSince1970
        if let last = lastEventAt {
            let gap = nowTick - last
            if gap >= 5 {
                stats.recordStare(seconds: gap)
            } else if gap < 10 {
                stats.recordActive(seconds: gap)
            }
        }
        lastEventAt = nowTick

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 桌宠对打字方式的反应：只传按键类别与 keyCode，不传内容
        if let reaction = PetKeyObserver.shared.key(code: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers) {
            PetWindowController.shared.keyReaction(reaction)
        }

        // ⌃`：功能面板（与 Rime 的方案菜单同一个手感位）；再按一次关闭。
        // keyCode 50 = ANSI 键盘的 `，10 = ISO 键盘上 ` 所在的键。
        if event.keyCode == 50 || event.keyCode == 10,
           flags.contains(.control), !flags.contains(.command), !flags.contains(.option) {
            showQuickPanel(toggle: true)
            return true
        }

        // 功能面板开着：数字直达、Esc 关闭，其余按键关掉面板后照常输入
        if QuickPanelController.shared.isVisible {
            if event.keyCode == 53 {
                QuickPanelController.shared.hide()
                return true
            }
            if flags.isDisjoint(with: [.command, .control, .option, .shift]),
               let digit = Self.digitKeyCodes[event.keyCode],
               !engine.hasComposition, QuickPanelController.shared.trigger(key: digit) {
                return true
            }
            QuickPanelController.shared.hide()
        }

        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }

        let keyCode = event.keyCode
        if keyCode == 51 {
            stats.recordDelete()  // 删除键：含组合态外的原编辑
            PetWindowController.shared.noteDelete()
        }
        if keyCode == 36 || keyCode == 76 {
            stats.recordEnter()  // 回车键：同上
        }

        switch keyCode {
        case 53: // Esc
            if voice.isListening || voiceSettledSource != nil {
                cancelVoiceUtterance()
                return true
            }
            if engine.mode == "emoji" {
                exitEmojiMode(client: client)
                return true
            }
            guard engine.hasComposition else { return false }
            engine.clear()
            window.hide()
            update(client)
            return true
        case 36, 76: // Return
            if (voice.isListening || voiceSettledSource != nil), !engine.hasComposition,
               commitVoiceSelection(index: 0, client: client) {
                return true
            }
            guard engine.hasComposition else { return false }
            let keys = engine.composition.raw.count
            if let raw = engine.commitRaw() {
                stats.recordCommit(chars: raw.count, keys: keys)
                commit(raw, client: client)
            }
            return true
        case 51: // Delete
            if !engine.hasComposition {
                // 落到应用的删除：多半在删刚上屏的词——交给内核按窗口判定强负信号
                engine.noteEvolutionDelete()
                persistEvolution()
            }
            guard engine.hasComposition else { return false }
            _ = engine.backspace()
            update(client)
            return true        case 49: // Space
            if (voice.isListening || voiceSettledSource != nil), !engine.hasComposition,
               commitVoiceSelection(index: 0, client: client) {
                return true
            }
            guard engine.hasComposition || engine.mode == "emoji" else { return false }
            // 英文串（网址/邮箱/英文词）：空格原样上屏并带出空格，不进候选
            if engine.hasComposition, engine.composition.englishLike == true {
                let keys = engine.composition.raw.count
                if let raw = engine.commitRaw() {
                    stats.recordCommit(chars: raw.count, keys: keys)
                    commit(raw + " ", client: client)
                }
                return true
            }
            select(index: page * CandidateWindowController.pageSize, client: client)
            return true
        default:
            break
        }

        if engine.hasComposition || engine.mode == "emoji" {
            let pageCount = max(1, Int(ceil(Double(currentCandidateCount()) / Double(CandidateWindowController.pageSize))))
            switch keyCode {
            case 123, 116: // ← / PageUp
                page = max(0, page - 1)
                update(client)
                return true
            case 124, 121: // → / PageDown
                page = min(pageCount - 1, page + 1)
                update(client)
                return true
            case 27: // -
                page = max(0, page - 1)
                update(client)
                return true
            case 24: // =
                page = min(pageCount - 1, page + 1)
                update(client)
                return true
            default:
                break
            }
            if let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
                // 英文串里数字是内容（v1.2），不再当候选编号
                if engine.composition.englishLike != true {
                    select(index: page * CandidateWindowController.pageSize + n - 1, client: client)
                    return true
                }
            }
        }

        // 语音/同传候选：数字键直接上屏对应候选（1=译文，2=原文）
        if (voice.isListening || voiceSettledSource != nil), !engine.hasComposition,
           let voiceChars = event.charactersIgnoringModifiers, let num = Int(voiceChars),
           (1...9).contains(num),
           commitVoiceSelection(index: num - 1, client: client) {
            return true
        }

        guard let chars = event.charactersIgnoringModifiers else { return false }

        // 真实按键字符：按住 Shift 时用 event.characters（大写字母 / Shift 后的符号），
        // 否则沿用 charactersIgnoringModifiers。修复「按住 Shift 打不出大写英文」。
        let shiftHeld = flags.contains(.shift)
        let inputChars: String = shiftHeld ? (event.characters ?? chars) : chars

        // 语音进行中遇到普通按键：先落下顶部候选，再继续处理本键（说→打无缝衔接）
        if voice.isListening || voiceSettledSource != nil {
            absorbVoice(client: client)
        }

        // 连按两下 a：浏览器 → 网址模式；聊天工具 → 表情模式（斗图）。
        if chars == "a", !event.isARepeat, !shiftHeld {
            let now = ProcessInfo.processInfo.systemUptime
            if engine.composition.raw == "a", now - lastAAt < 0.3 {
                lastAAt = 0
                engine.clear()
                if profile.urlGesture {
                    enterURLMode(client: client)
                    return true
                }
                if profile.memeGesture {
                    enterEmojiMode(client: client)
                    return true
                }
                // 当前应用没有手势动作：还原为正常的 aa 输入
                _ = engine.feed("a")
                _ = engine.feed("a")
                page = 0
                update(client)
                return true
            }
            lastAAt = now
        }

        // 按住 Shift + 字母：英文意图，直接上屏大写字母（先落掉进行中的组合）。
        if shiftHeld, inputChars.count == 1, let c = inputChars.first, c.isASCII, c.isLetter {
            if engine.hasComposition, let raw = engine.commitRaw() {
                stats.recordCommit(chars: raw.count, keys: raw.count)
                client.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            client.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            PetWindowController.shared.react(.commit)
            page = 0
            update(client)
            return true
        }

        // 中文模式下的标点映射（未组合时）：`,。？！；：、（）【】《》“”‘’…
        // 代码编辑器/终端保持半角（按应用画像自动判断，无需用户配置）。
        let mode = LianaMode(rawValue: engine.mode) ?? .pinyin
        if !engine.hasComposition, mode.usesChinesePunctuation, !profile.asciiPunctuation,
           let punct = chinesePunctuation(inputChars) {
            client.insertText(punct, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.hide()
            return true
        }

        var accepted = false
        var fed = 0
        for ch in inputChars {
            if engine.feed(ch) {
                accepted = true
                fed += 1
            } else {
                break
            }
        }
        if accepted {
            stats.recordKeys(fed)
            page = 0
            update(client)
            return true
        }
        // 组合中的不可组合字符：先落组合再落字符，绝不穿透打乱预编辑。
        if engine.hasComposition, let ch = inputChars.first {
            let keys = engine.composition.raw.count
            var committed: String?
            if mode.usesChinesePunctuation, !profile.asciiPunctuation,
               let punct = chinesePunctuation(String(ch)) {
                // 中文流：首选上屏 + 全角标点
                committed = engine.select(0) ?? engine.commitRaw()
                if let text = committed {
                    stats.recordCommit(chars: text.count, keys: keys)
                    client.insertText(text + punct, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            } else {
                // 其余符号（@ # ^ 等）：原样上屏
                committed = engine.select(0) ?? engine.commitRaw()
                if let text = committed {
                    stats.recordCommit(chars: text.count, keys: keys)
                    client.insertText(text + inputChars, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
            if committed != nil {
                recordModeSignal(strong: false)
                persistUserModel()
                PetWindowController.shared.react(.commit)
                page = 0
                update(client)
            }
            return true
        }
        return accepted
    }

    override func commitComposition(_ sender: Any!) {
        if voice.isListening || voiceSettledSource != nil, let voiceClient = sender as? IMKTextInput {
            absorbVoice(client: voiceClient)
        }
        if let client = sender as? IMKTextInput {
            let keys = engine.composition.raw.count
            if let raw = engine.commitRaw() {
                stats.recordCommit(chars: raw.count, keys: keys)
                client.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0))
                recordModeSignal(strong: false)
                persistUserModel()
            }
        }
        window.hide()
    }

    override func deactivateServer(_ sender: Any!) {
        stopListeningAndVoiceState()
        voiceMarked = false
        window.hide()
        engine.clear()
        urlMode = false
        // 会话结束：截断发呆计时，避免跨应用间隙被误计
        if let last = lastEventAt {
            let gap = Date().timeIntervalSince1970 - last
            if gap >= 5 {
                stats.recordStare(seconds: gap)
            }
        }
        lastEventAt = nil
        if Self.activeController === self {
            Self.activeController = nil
        }
        if let previous = modeBeforeEmoji {
            engine.setMode(previous)
            modeBeforeEmoji = nil
        }
        PetWindowController.shared.react(.idle)
        if let client = sender as? IMKTextInput {
            clearMarkedText(client)
        }
        persistEvolution(force: true)
        window.hide()
        store.flush()
        super.deactivateServer(sender)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        currentClient = sender as? IMKTextInput
        Self.activeController = self
        page = 0
        syncEvolutionContext()
        restoreModeForApp()
        refreshPetModeLabel()
        maybeEveningDigest()
        maybeHintQuickPanel()
    }

    /// 还没用过功能面板的人：每个进程生命周期提示一次快捷键（用过一次就不再提示）。
    private static var quickPanelHinted = false
    private func maybeHintQuickPanel() {
        guard !Self.quickPanelHinted, !UserDefaults.standard.bool(forKey: "LianaQuickPanelSeen") else { return }
        Self.quickPanelHinted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            GlassToast.shared.show(
                "松萝小提示：打字时按 ⌃`（Control + 反引号）打开功能面板——截图学习、语音、同传、桌宠都在里面",
                symbol: "command",
                duration: 7
            )
        }
    }

    /// 傍晚总结：18 点后当天第一次激活时弹一次今日小结气泡。
    /// 不用系统通知权限——进程活着才会弹，属于「打字时顺带看到」。
    private func maybeEveningDigest() {
        guard !digestChecked else { return }
        digestChecked = true
        guard PetStats.shared.isEnabled else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 18 else { return }
        let today = PetStats.dayKey()
        guard UserDefaults.standard.string(forKey: "LianaDigestShown") != today else { return }
        UserDefaults.standard.set(today, forKey: "LianaDigestShown")
        PetWindowController.shared.showStatsCard(yesterday: false)
    }

    // MARK: - 内部

    /// ASCII 标点 → 中文全角标点；返回 nil 表示不拦截。
    /// 引号成对翻转，`^` 输出省略号，`\` 输出顿号。
    private func chinesePunctuation(_ s: String) -> String? {
        switch s {
        case ",": return "，"
        case ".": return "。"
        case "?": return "？"
        case "!": return "！"
        case ":": return "："
        case ";": return "；"
        case "(": return "（"
        case ")": return "）"
        case "[": return "【"
        case "]": return "】"
        case "{": return "「"
        case "}": return "」"
        case "<": return "《"
        case ">": return "》"
        case "\\": return "、"
        case "|": return "｜"
        case "~": return "～"
        case "^": return "……"
        case "$": return "¥"
        case "`": return "·"
        case "\"":
            defer { openDoubleQuote.toggle() }
            return openDoubleQuote ? "“" : "”"
        case "'":
            defer { openSingleQuote.toggle() }
            return openSingleQuote ? "‘" : "’"
        default:
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard event.keyCode == 56 || event.keyCode == 60 else { return false }
        if event.modifierFlags.contains(.shift) {
            shiftArmed = true
            shiftUsed = false
        } else if shiftArmed {
            let shouldToggle = !shiftUsed && !engine.hasComposition
            shiftArmed = false
            if shouldToggle { toggleLanguage() }
        }
        return false
    }

    private func currentCandidateCount() -> Int {
        engine.composition.candidates.count
    }

    private func select(index: Int, client: IMKTextInput) {
        let keys = engine.composition.raw.count
        guard let text = engine.select(index) else {
            NSSound.beep()
            if let reaction = PetKeyObserver.shared.noteSelectFailed() { PetWindowController.shared.keyReaction(reaction) }
            return
        }
        noteEvolutionSelection(index: index)
        stats.recordCommit(chars: text.count, keys: keys)
        commit(text, client: client)
    }

    private func commit(_ text: String, client: IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        recordModeSignal(strong: false)
        persistUserModel()
        PetWindowController.shared.react(.commit)
        PetKeyObserver.shared.noteCommit()
        page = 0
        update(client)
    }

    /// 把会话内学到的用户词（含上下词二元组）合并进加密存储。
    private func persistUserModel() {
        store.mergeUserModel(tsv: engine.exportUserModel())
    }

    // MARK: - 知你教学层（ADR-0008 E1）

    /// 知你账本落盘节流：账本是全量 TSV，没必要跟着每次选词导出；
    /// 平峰 60 秒一次，会话结束/切换应用前强制一次。
    private var lastEvolutionPersistAt: TimeInterval = 0

    private func persistEvolution(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastEvolutionPersistAt >= 60 else { return }
        lastEvolutionPersistAt = now
        store.mergeEvolution(tsv: engine.exportEvolution())
    }

    /// 会话激活：把前台应用、时段与学习开关同步给内核（重排的决策上下文）。
    private func syncEvolutionContext() {
        let hour = UInt32(Calendar.current.component(.hour, from: Date()))
        engine.setEvolutionContext(app: currentAppId, hour: hour, enabled: EvolutionLearning.isEnabled)
    }

    /// 选词上屏的教学信号：数字键选了第 2+ 候选算「排序还不够准」（+0.6），
    /// 首选正常记账（+1.0）；若刚发生选后删除，这里自动升级为重选强正（+1.5）。
    /// 同时把 E3 评估（实际/反事实首选命中、重选）记入当天统计。
    private func noteEvolutionSelection(index: Int) {
        engine.noteEvolutionSelection(altRank: index > 0)
        if let eval = engine.takeEvolutionEval() {
            stats.recordSelection(eval)
        }
        persistEvolution()
    }

    @objc private func toggleEvolutionLearning(_ sender: NSMenuItem) {
        let on = !EvolutionLearning.isEnabled
        EvolutionLearning.setEnabled(on)
        sender.state = on ? .on : .off
        syncEvolutionContext()
        PetWindowController.shared.showToast(
            on ? "知你学习已开启：选词与纠错都会成为排序参考" : "知你学习已暂停（账本保留，可随时继续）",
            duration: 4
        )
    }

    /// 一键忘记：清空共享账本与落盘数据（忘了就是真忘了）。
    @objc private func forgetEvolutionLedger(_ sender: Any) {
        engine.forgetEvolution()
        store.setEvolution("")
        PetWindowController.shared.showToast("知你学习账本已清空", duration: 3)
    }

    @objc private func openFeedWindow(_ sender: Any) {
        FeedWindowController.shared.show()
    }

    // MARK: - 网址模式 / 表情模式

    private func enterURLMode(client: IMKTextInput) {
        urlMode = true
        window.presentHint("网址模式 · 输入完成后按 Esc 退出", near: caretRect(client))
        PetWindowController.shared.react(.idle)
    }

    private func exitURLMode() {
        urlMode = false
        window.hide()
    }

    private func enterEmojiMode(client: IMKTextInput) {
        let current = engine.mode
        if current != "emoji" {
            modeBeforeEmoji = current
            engine.setMode("emoji")
        }
        page = 0
        update(client)
    }

    private func exitEmojiMode(client: IMKTextInput) {
        if let previous = modeBeforeEmoji {
            engine.setMode(previous)
            modeBeforeEmoji = nil
        }
        page = 0
        update(client)
        window.hide()
    }

    private func update(_ client: IMKTextInput) {
        let comp = engine.composition
        guard !comp.raw.isEmpty || !comp.candidates.isEmpty else {
            // 语音「边说边落字」或同传待确认时，预编辑与候选窗归语音所有，不许清
            if !voiceMarked { clearMarkedText(client) }
            if !voice.isListening && voiceSettledSource == nil { window.hide() }
            PetWindowController.shared.react(.idle)
            return
        }
        PetWindowController.shared.react(comp.raw.isEmpty ? .idle : .composing)
        let display = comp.preedit.isEmpty ? comp.raw : comp.preedit
        if display.isEmpty {
            // 表情模式的精选列表：不产生预编辑串，只展示候选窗
            clearMarkedText(client)
        } else {
            // 预编辑：当前正在拼的音节用强调色 + 加粗，其余常规下划线
            let pieces = display.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let marked = NSMutableAttributedString()
            for (index, piece) in pieces.enumerated() {
                let active = index == pieces.count - 1 && pieces.count > 1
                let attributes: [NSAttributedString.Key: Any] = [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .foregroundColor: active ? NSColor.controlAccentColor : NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 15, weight: active ? .semibold : .regular),
                ]
                marked.append(NSAttributedString(string: piece, attributes: attributes))
                if index < pieces.count - 1 {
                    marked.append(NSAttributedString(string: " "))
                }
            }
            client.setMarkedText(
                marked,
                selectionRange: NSRange(location: marked.length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        let caret = caretRect(client)
        if let caret {
            // 输入法在哪块屏幕工作，桌宠就在哪块屏幕互动
            PetWindowController.shared.moveToScreen(
                containing: NSPoint(x: caret.midX, y: caret.midY)
            )
        }
        window.present(candidates: comp.candidates, page: page, near: caret) { [weak self, weak client] index in
            guard let self, let client else { return }
            self.select(index: index, client: client)
        }
        page = window.page
        scheduleRerank(comp, client: client)
    }

    /// 长句 AI 重排（见 SentenceRerank）：首选是长整句、有几条整句可比时，停顿 0.25 秒后让本机模型挑一次；
    /// 结果回来时输入没变才生效。
    private func scheduleRerank(_ comp: Composition, client: IMKTextInput) {
        rerankWork?.cancel()
        guard translateTarget == nil, page == 0, comp.raw != rerankedRaw,
              let first = comp.candidates.first, first.kind == "sentence",
              first.text.count >= SentenceRerank.minChars else { return }
        let sentences = comp.candidates.prefix(5).enumerated()
            .filter { $0.element.kind == "sentence" && $0.element.consumed == first.consumed }
        guard sentences.count >= 2, SentenceRerank.available else { return }
        let raw = comp.raw
        let work = DispatchWorkItem { [weak self, weak client] in
            guard let self, self.engine.composition.raw == raw else { return }
            SentenceRerank.pick(sentences.map(\.element.text)) { [weak self, weak client] best in
                guard let self, let client, let best, self.engine.composition.raw == raw else { return }
                self.rerankedRaw = raw
                if best > 0, self.engine.promote(sentences[best].offset) {
                    self.update(client)
                }
            }
        }
        rerankWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func clearMarkedText(_ client: IMKTextInput) {
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func caretRect(_ client: IMKTextInput) -> NSRect? {
        // attributes 返回的是光标所在行的矩形（屏幕坐标，AppKit 原点），是 IME 最稳的定位方式；
        // firstRect 在部分应用里对 NSNotFound 范围返回无效值，放在其后兜底。
        var rect: NSRect = .zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite {
            return rect
        }
        var actual = NSRange()
        let first = client.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        if first.height > 0, first.origin.x.isFinite, first.origin.y.isFinite {
            return first
        }
        // 两者都失败时退回鼠标位置，至少让候选窗出现在用户视线附近
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 20, width: 2, height: 20)
    }
}
