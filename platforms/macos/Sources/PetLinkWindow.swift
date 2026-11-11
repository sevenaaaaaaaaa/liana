import AppKit
import CoreImage

final class PetLinkWindow: NSWindowController {
    static let shared = PetLinkWindow()
    private var receiver: PetLinkReceiver?
    private var profile: PetLink.Profile?
    private let status = NSTextField(wrappingLabelWithString: "接收已关闭")
    private let qr = NSImageView()
    private let clipboardToggle = NSButton(checkboxWithTitle: "允许已配对设备发送／读取文字剪贴板", target: nil, action: nil)
    private let toggle = NSButton(title: "开始接收", target: nil, action: nil)
    private let copy = NSButton(title: "复制配对码", target: nil, action: nil)
    private let rotate = NSButton(title: "撤销全部配对并换码", target: nil, action: nil)
    private static var directory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("松萝收件箱", isDirectory: true)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "连接 iPhone · 桌宠收件箱"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 14; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
        ])
        let title = NSTextField(labelWithString: "把文件交给桌宠")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        stack.addArrangedSubview(title)
        let hint = NSTextField(wrappingLabelWithString: "iPhone 打开松萝 → 连接 Mac 桌宠 → 扫描此码。首次连接在这台 Mac 允许配对，之后可直接发送文件。两端需要在同一局域网。")
        hint.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 260).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 260).isActive = true
        stack.addArrangedSubview(qr)
        status.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions = NSStackView(views: [toggle, copy, rotate])
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        clipboardToggle.state = UserDefaults.standard.bool(forKey: "PetLink.clipboard") ? .on : .off
        clipboardToggle.target = self; clipboardToggle.action = #selector(toggleClipboard)
        stack.addArrangedSubview(clipboardToggle)
        toggle.target = self; toggle.action = #selector(toggleReceiving)
        copy.target = self; copy.action = #selector(copyCode)
        rotate.target = self; rotate.action = #selector(rotateCode)
        let folder = NSButton(title: "打开松萝收件箱", target: self, action: #selector(openFolder))
        stack.addArrangedSubview(folder)
        let note = NSTextField(wrappingLabelWithString: "仅接收已配对设备主动选择的文件；剪贴板默认关闭，勾选后允许配对设备按需发送／读取文字（最多 4KB）。单文件上限 200MB。配对码含密钥，请只交给自己的设备。文件会一直保留，不自动打开。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        copy.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func restoreIfEnabled() { if UserDefaults.standard.bool(forKey: "PetLink.enabled") { start() } }
    func show() {
        if receiver == nil { start() }
        window?.center(); showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func start() {
        guard receiver == nil else { return }
        do {
            let profile = try PetLink.load(account: "receiver") ?? PetLink.Profile.create(name: Host.current().localizedName ?? "我的 Mac")
            try PetLink.store(profile, account: "receiver")
            self.profile = profile
            let receiver = PetLinkReceiver(profile: profile, directory: Self.directory)
            self.receiver = receiver
            receiver.clipboardRead = { [weak self, weak receiver] in
                guard let self, let receiver, self.receiver === receiver, self.clipboardToggle.state == .on else { throw PetLink.Failure.message("请在 Mac 桌宠收件箱勾选允许剪贴板同步。") }
                return NSPasteboard.general.string(forType: .string) ?? ""
            }
            receiver.clipboardWrite = { [weak self, weak receiver] text in
                guard let self, let receiver, self.receiver === receiver, self.clipboardToggle.state == .on else { throw PetLink.Failure.message("请在 Mac 桌宠收件箱勾选允许剪贴板同步。") }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            receiver.onStatus = { [weak self] in self?.status.stringValue = $0 }
            receiver.authorize = { [weak self, weak receiver] _, name, finish in
                guard let receiver, self?.receiver === receiver else { finish(false); return }
                let alert = NSAlert()
                alert.messageText = "允许「\(name)」给桌宠发送文件？"
                alert.informativeText = "只有扫描或导入此 Mac 配对码的设备可以连接。允许后，该设备可发送文件；你另外勾选剪贴板许可后，也可按需发送／读取文字剪贴板。"
                alert.addButton(withTitle: "允许配对"); alert.addButton(withTitle: "拒绝")
                NSApp.activate(ignoringOtherApps: true)
                finish(alert.runModal() == .alertFirstButtonReturn)
            }
            receiver.onReceived = { url, name in
                let line = "收到来自 \(name) 的「\(url.lastPathComponent)」"
                if PetWindowController.isEnabled {
                    PetWindowController.shared.notify("notify_ok")
                    PetWindowController.shared.showToast(line, duration: 6)
                } else { GlassToast.shared.show(line, symbol: "tray.and.arrow.down.fill", duration: 6) }
            }
            receiver.start()
            UserDefaults.standard.set(true, forKey: "PetLink.enabled")
            toggle.title = "停止接收"; copy.isEnabled = true
            renderQR(profile.pairingCode)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func toggleClipboard() { UserDefaults.standard.set(clipboardToggle.state == .on, forKey: "PetLink.clipboard") }
    @objc private func toggleReceiving() {
        if let receiver {
            receiver.stop(); self.receiver = nil
            UserDefaults.standard.set(false, forKey: "PetLink.enabled")
            toggle.title = "开始接收"; qr.image = nil; copy.isEnabled = false
            status.stringValue = "已停止接收，配对记录保留。"
        } else { start() }
    }
    @objc private func copyCode() {
        guard receiver != nil, let profile else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(profile.pairingCode, forType: .string)
        status.stringValue = "配对码已复制，请在 iPhone 松萝里选择粘贴配对码。"
    }
    @objc private func rotateCode() {
        let alert = NSAlert()
        alert.messageText = "撤销全部配对？"
        alert.informativeText = "已有设备将不能重连，需要重新扫描新二维码。收件箱中的文件保留。"
        alert.addButton(withTitle: "撤销并换码"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let profile { UserDefaults.standard.removeObject(forKey: "PetLink.trusted." + profile.id.uuidString) }
        receiver?.stop(); receiver = nil
        do {
            let profile = try PetLink.Profile.create(name: Host.current().localizedName ?? "我的 Mac")
            try PetLink.store(profile, account: "receiver")
            start()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.directory)
    }
    private func renderQR(_ code: String) {
        qr.image = Self.pairingImage(code)
    }
    static func pairingImage(_ code: String) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(code.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let extent = output.extent.insetBy(dx: -32, dy: -32)
        let padded = output.composited(over: CIImage(color: .white).cropped(to: extent))
        guard let image = CIContext().createCGImage(padded, from: extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: extent.width, height: extent.height))
    }
}
