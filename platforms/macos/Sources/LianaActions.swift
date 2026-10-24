import AppKit
import Vision

extension Notification.Name {
    /// 需要「当前输入会话」才能执行的动作（语音、同传、切模式）：只有活跃控制器响应。
    /// userInfo["action"]: "voice" / "interpret-en" / "interpret-ja" / "interpret-off" / "mode:<id>"
    static let lianaControllerAction = Notification.Name("LianaControllerAction")
    /// 繁体输出开关在设置中心被切换：所有会话重读。
    static let lianaTraditionalChanged = Notification.Name("LianaTraditionalChanged")
    /// 设置中心改了默认输入模式：活跃会话立即切换。
    static let lianaModeChanged = Notification.Name("LianaModeChanged")
}

/// 功能动作的统一入口：功能面板、设置中心、输入法菜单都走这里，
/// 保证同一个功能在三个地方行为一致。
enum LianaActions {
    /// 功能面板 / 设置中心使用的动作标识。
    enum ID: String, CaseIterable {
        case screenshotLearn = "screenshot"
        case voice = "voice"
        case interpretEn = "interpret-en"
        case interpretJa = "interpret-ja"
        case interpretOff = "interpret-off"
        case pet = "pet"
        case feed = "feed"
        case clipboard = "clipboard"
        case stats = "stats"
        case settings = "settings"
        case shelfCapture = "shelf-capture"
        case shelfOpen = "shelf-open"
    }

    static func perform(_ id: ID) {
        switch id {
        case .screenshotLearn:
            ScreenshotLearner.shared.start()
        case .shelfCapture:
            StagingShelf.captureScreenshot()
        case .shelfOpen:
            StagingShelf.open()
        case .voice, .interpretEn, .interpretJa, .interpretOff:
            NotificationCenter.default.post(
                name: .lianaControllerAction, object: nil, userInfo: ["action": id.rawValue]
            )
        case .pet:
            let on = !PetWindowController.isEnabled
            PetWindowController.setEnabled(on)
            GlassToast.shared.show(on ? "桌宠已出现" : "桌宠已收起", symbol: "pawprint.fill", duration: 2)
        case .feed:
            FeedWindowController.shared.show()
        case .clipboard:
            ClipboardWindowController.shared.show()
        case .stats:
            let text = PetStats.summaryText(for: PetStats.shared.yesterday, title: "昨日输入总结")
                ?? "还没有输入记录"
            GlassToast.shared.show(text.replacingOccurrences(of: "📊 ", with: ""), symbol: "chart.bar.fill", duration: 8)
        case .settings:
            SettingsCenter.shared.show()
        }
    }

    // MARK: - 桌宠形象（菜单与设置中心共用）

    static func importVRM() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 VRM 模型文件（VRoid Studio 可免费导出）"
        panel.allowedContentTypes = [.init(filenameExtension: "vrm") ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PetImporter.importVRM(from: url)
            PetWindowController.activePackId = "vrm-custom"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            GlassToast.shared.show("已导入 VRM：\(url.lastPathComponent)", symbol: "person.crop.circle.badge.checkmark")
        } catch {
            GlassToast.shared.show("导入失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 6)
        }
    }

    static func importLive2D() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "选择 Live2D 模型文件夹（含 *.model3.json）或 .zip"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PetImporter.importLive2D(from: url)
            PetWindowController.activePackId = "live2d-custom"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            if PetRuntimeStore.live2DCoreAvailable() {
                GlassToast.shared.show("已导入并切换 Live2D：\(url.lastPathComponent)", symbol: "person.crop.circle.badge.checkmark")
            } else {
                GlassToast.shared.show(
                    "已导入 Live2D，还缺 Cubism Core：在设置中心 › 桌宠 里获取并放入 Core 目录，重启输入法生效",
                    symbol: "exclamationmark.triangle.fill",
                    duration: 9
                )
            }
        } catch {
            GlassToast.shared.show("导入失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 6)
        }
    }

    /// 目录条目：已装则切换，未装则下载（sha256 校验）后切换。
    static func installOrSwitchPet(id: String, onDone: (() -> Void)? = nil) {
        guard let entry = PetCatalogStore.entries().first(where: { $0.id == id }) else { return }
        if PetWindowController.availablePets().contains(where: { $0.id == id }) {
            PetWindowController.activePackId = id
            if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
            onDone?()
            return
        }
        GlassToast.shared.show("正在下载 \(entry.name)（\(entry.sizeText)）…", symbol: "arrow.down.circle.fill", duration: 4)
        PetModelInstaller.install(entry, onProgress: { _ in }) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    PetWindowController.activePackId = id
                    if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
                    GlassToast.shared.show("\(entry.name) 已下载并切换", symbol: "checkmark.circle.fill")
                case .failure(let error):
                    GlassToast.shared.show("下载失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 6)
                }
                onDone?()
            }
        }
    }

    static func openLive2DCorePage() {
        if let url = URL(string: "https://www.live2d.com/en/sdk/download/web/") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openDataFolder() {
        let path = NSHomeDirectory() + "/Library/Application Support/Liana"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 备份（设置中心用：独立会话读写落盘数据）

    private static func backupEngine() -> LianaEngine {
        let engine = LianaEngine(mode: "pinyin")
        let tsv = EncryptedStore.shared.userModelTsv
        if !tsv.isEmpty {
            _ = engine.importUserModel(tsv)
        }
        return engine
    }

    static func exportEncryptedBackup() {
        BackupManager.exportEncrypted(engine: backupEngine())
    }

    static func exportPlainBackup() {
        BackupManager.exportPlain(engine: backupEngine())
    }

    static func restoreBackup() {
        BackupManager.restore(engine: backupEngine(), store: EncryptedStore.shared)
    }
}

// MARK: - 截图快速学习

/// 一步到位：框选屏幕 → 端上 OCR（Apple Vision）→ 统计提炼术语 → 直接喂入营养库。
/// 全程零网络；学到的词立即能打出来，不满意可在「喂它一段」里逐个忘掉。
final class ScreenshotLearner {
    static let shared = ScreenshotLearner()

    private var running = false
    private var lastText = ""

    func start() {
        guard !running else { return }
        running = true
        let path = NSTemporaryDirectory() + "liana-learn-\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i 交互框选（空格切窗口），-x 不播放快门声，结果写临时文件，不污染剪切板
        process.arguments = ["-i", "-x", path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.didCapture(path: path)
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            GlassToast.shared.show("无法启动截图：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 5)
        }
    }

    private func didCapture(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            running = false
            // 用户按 Esc 取消，或未授予「屏幕录制」权限
            if !CGPreflightScreenCaptureAccess() {
                GlassToast.shared.show(
                    "需要「屏幕录制」权限才能截图学习：系统设置 › 隐私与安全性 › 屏幕录制 › 打开「松萝」",
                    symbol: "lock.shield.fill",
                    duration: 8
                )
                LianaActions.openPrivacyPane("Privacy_ScreenCapture")
            }
            return
        }
        try? FileManager.default.removeItem(at: url)
        GlassToast.shared.show("正在识别截图里的文字…", symbol: "text.viewfinder", duration: 10)
        let request = VNRecognizeTextRequest { [weak self] req, error in
            // 出错时由下面 perform 的 catch 统一提示，这里不重复弹
            guard error == nil else { return }
            let lines = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
            DispatchQueue.main.async {
                self?.learn(from: lines.joined(separator: "\n"))
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                DispatchQueue.main.async {
                    self?.running = false
                    GlassToast.shared.show("识别失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 5)
                }
            }
        }
    }

    private func learn(from text: String) {
        running = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            GlassToast.shared.show("截图里没认出文字", symbol: "text.viewfinder", duration: 3)
            return
        }
        lastText = trimmed
        let terms = LianaEngine.feedExtract(trimmed)
        guard !terms.isEmpty else {
            GlassToast.shared.show(
                "认出 \(trimmed.count) 个字，但没有反复出现的新词——截一段更长的内容试试",
                symbol: "text.viewfinder",
                duration: 5
            )
            return
        }
        let engine = LianaEngine(mode: "pinyin")
        var learned: [String] = []
        for item in terms.prefix(40) where engine.nutritionAdd(term: item.term, source: "截图学习", strength: UInt32(max(1, item.count))) {
            learned.append(item.term)
        }
        guard !learned.isEmpty else {
            GlassToast.shared.show("这些词都已经学过了", symbol: "checkmark.circle.fill", duration: 3)
            return
        }
        EncryptedStore.shared.mergeNutrition(tsv: engine.nutritionExport())
        NotificationCenter.default.post(name: .nutritionChanged, object: nil)
        let preview = learned.prefix(5).joined(separator: "、")
        let more = learned.count > 5 ? " 等" : ""
        GlassToast.shared.show(
            "学会 \(learned.count) 个词：\(preview)\(more)——现在就能打出来",
            symbol: "brain.head.profile",
            duration: 6
        )
    }

    /// 把上一次截图识别出的原文交给「喂它一段」逐个审阅。
    func reviewLast() {
        guard !lastText.isEmpty else {
            FeedWindowController.shared.show()
            return
        }
        FeedWindowController.shared.show(text: lastText, source: "截图学习")
    }
}
