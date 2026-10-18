import AppKit

/// 剪切板监控：默认关闭；开启后轮询系统剪切板变化并写入加密历史。
///
/// 隐私规则（ADR-0005）：跳过密码管理器等 Concealed/Transient 内容，
/// 跳过连续重复；不记录来源 App。
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()
    static let enabledKey = "LianaClipboardEnabled"

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSeenText: String?

    private let bannedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
    ]

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            lastChangeCount = NSPasteboard.general.changeCount
            start()
        } else {
            stop()
        }
        NotificationCenter.default.post(name: .lianaClipboardChanged, object: nil)
    }

    /// 启动时按用户设置恢复。
    func startIfEnabled() {
        guard isEnabled else {
            NSLog("Liana: 剪切板记录未开启（默认关闭）")
            return
        }
        lastChangeCount = NSPasteboard.general.changeCount
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        stop()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 自己写入剪切板后调用，避免把「回填历史」再记一遍。
    func ignore(_ text: String) {
        lastSeenText = text
        lastChangeCount = NSPasteboard.general.changeCount
        ClipboardActionWatcher.shared.ignoreCurrent()
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !hasBannedType(pasteboard) else { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text != lastSeenText else { return }
        lastSeenText = text
        if EncryptedStore.shared.recordClipboard(text) {
            NotificationCenter.default.post(name: .lianaClipboardChanged, object: nil)
        }
    }

    private func hasBannedType(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { bannedTypes.contains($0.rawValue) }
    }
}

extension Notification.Name {
    static let lianaClipboardChanged = Notification.Name("LianaClipboardChanged")
}
