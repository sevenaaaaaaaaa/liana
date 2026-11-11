import UIKit
import UniformTypeIdentifiers

final class PetLinkViewController: UIViewController, UIDocumentPickerDelegate {
    private var profile = PetLink.load(account: "mac")
    private let status = UILabel()
    private let macName = UILabel()
    private let sendButton = LianaPressButton(frame: .zero)
    private var connectionButton: UIButton?
    private var cancelButton: UIButton?
    private var forgetButton: UIButton?
    private let progress = UIProgressView(progressViewStyle: .default)
    private var pendingFile: URL?
    private var connected = false
    private var sending = false
    private lazy var sender: PetLinkSender = {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "PetLink.deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: "PetLink.deviceID")
        let sender = PetLinkSender(deviceID: id, deviceName: UIDevice.current.name)
        sender.onStatus = { [weak self] in self?.status.text = $0 }
        sender.onReady = { [weak self] in self?.connected = true; self?.updateSendButton() }
        sender.onDisconnected = { [weak self] in self?.connected = false; self?.sending = false; self?.updateSendButton() }
        sender.onFailure = { [weak self] in self?.sending = false; self?.updateSendButton() }
        sender.onSaved = { [weak self] _ in self?.sending = false; self?.pendingFile = nil; self?.progress.progress = 1; self?.updateSendButton() }
        sender.onProgress = { [weak self] in self?.progress.progress = Float($0) }
        return sender
    }()

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Mac 桌宠"; LianaUI.navigation(self)
        navigationItem.rightBarButtonItem = LianaUI.closeItem(id: "mac.done") { [weak self] in self?.done() }
        let stack = LianaUI.scrollStack(in: self, spacing: 20)
        stack.addArrangedSubview(LianaUI.label("把文件交给 Mac 桌宠", size: 25, weight: .semibold))
        stack.addArrangedSubview(LianaUI.label("同一局域网，配对后轻松连接。", size: 14, muted: true))
        macName.font = LianaPalette.font(19, weight: .semibold); macName.textColor = LianaPalette.ink; macName.numberOfLines = 0; macName.adjustsFontForContentSizeCategory = true
        let pair = UIStackView(); pair.distribution = .fillEqually; pair.spacing = 10
        let scan = button("扫码配对", symbol: "qrcode.viewfinder", id: "mac.scan") { [weak self] in
            guard let self else { return }
            let scanner = PairingScannerViewController(); scanner.onCode = { [weak self] in self?.pair($0) }
            self.present(UINavigationController(rootViewController: scanner), animated: true)
        }
        (scan as? LianaPressButton)?.surface = .primary; pair.addArrangedSubview(scan)
        pair.addArrangedSubview(button("粘贴配对码", symbol: "doc.on.clipboard", id: "mac.paste") { [weak self] in
            guard let code = UIPasteboard.general.string else { self?.status.text = "请先在 Mac 复制配对码，再回来粘贴。"; return }
            self?.pair(code.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let connect = button("连接已配对 Mac", symbol: "link", id: "mac.connect") { [weak self] in
            guard let self else { return }; if self.connected { self.sender.disconnect() } else { self.connect() }
        }; connectionButton = connect
        stack.addArrangedSubview(LianaUI.card([macName, LianaUI.label("在 Mac 右键桌宠 → 连接 iPhone，打开配对二维码。", size: 13, muted: true), pair, connect]))
        status.numberOfLines = 0; status.font = LianaPalette.font(14); status.textColor = LianaPalette.muted; status.adjustsFontForContentSizeCategory = true
        status.accessibilityIdentifier = "mac.status"; status.text = "扫描一次并在 Mac 允许配对，之后可直接连接。"
        stack.addArrangedSubview(LianaUI.card([status]))
        sendButton.surface = .primary; sendButton.rounded = 14
        sendButton.setImage(UIImage(systemName: "doc.badge.arrow.up"), for: .normal)
        sendButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -5, bottom: 0, right: 5)
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 15, left: 16, bottom: 15, right: 16)
        sendButton.accessibilityIdentifier = "mac.send"; sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        sendButton.addAction(UIAction { [weak self] _ in self?.chooseFile() }, for: .touchUpInside)
        progress.progressTintColor = LianaPalette.ink; progress.trackTintColor = LianaPalette.soft
        let cancel = button("取消当前传输", symbol: "xmark", id: "mac.cancel") { [weak self] in self?.sender.disconnect() }; cancelButton = cancel
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("文件，送到桌面。", size: 19, weight: .semibold), sendButton, progress, cancel, LianaUI.label("Mac 保存完成后，桌宠会提醒你。单个文件最大 200MB，发送时保持 App 打开。", size: 13, muted: true)]))
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("收件位置", size: 12, weight: .medium, muted: true), LianaUI.label("下载 → 松萝收件箱", size: 17, weight: .semibold)]))
        let forget = LianaUI.button("忘记此 Mac", role: .plain, id: "mac.forget") { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "忘记配对的 Mac？", message: "需要重新扫描才能连接。Mac 收件箱中的文件保留。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "忘记", style: .destructive) { [weak self] _ in
                self?.sender.disconnect(); PetLink.forget(account: "mac"); self?.profile = nil; self?.updateSendButton()
            }); self.present(alert, animated: true)
        }; forgetButton = forget; stack.addArrangedSubview(forget)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        updateSendButton(); if profile != nil { self.connect() }
    }
    deinit { NotificationCenter.default.removeObserver(self); sender.disconnect() }
    func receiveFile(_ url: URL) {
        guard !sending else { status.text = "当前文件正在发送，请完成后再打开另一个文件。"; return }
        pendingFile = url
        if isViewLoaded { updateSendButton() }
    }
    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        return label
    }
    private func button(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> UIButton {
        LianaUI.button(title, icon: symbol, role: .utility, id: id, action: action)
    }
    private func updateSendButton() {
        macName.text = profile.map { "已配对：" + $0.name } ?? "尚未配对 Mac"
        sendButton.isEnabled = connected && !sending
        let title = connected ? (pendingFile.map { "发送「" + $0.lastPathComponent + "」" } ?? "选择文件发送") : "先连接 Mac，再选择文件"
        sendButton.setTitle(title, for: .normal)
        connectionButton?.setTitle(connected ? "已连接 · 点击断开" : "连接已配对 Mac", for: .normal)
        connectionButton?.isEnabled = profile != nil
        connectionButton?.isHidden = profile == nil
        forgetButton?.isEnabled = profile != nil
        forgetButton?.isHidden = profile == nil
        cancelButton?.isHidden = !sending
        progress.isHidden = !sending && progress.progress == 0
        sendButton.titleLabel?.numberOfLines = 2
    }
    private func pair(_ code: String) {
        do {
            let profile = try PetLink.Profile.parse(code)
            try PetLink.store(profile, account: "mac")
            self.profile = profile
            connect(); updateSendButton()
        } catch { status.text = error.localizedDescription }
    }
    private func connect() {
        guard let profile else { status.text = "请先扫描 Mac 二维码，或粘贴 Mac 复制的配对码。"; return }
        sender.connect(profile: profile)
    }
    private func chooseFile() {
        if let pendingFile { send(pendingFile); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let url = urls.first { send(url) } }
    private func send(_ url: URL) { pendingFile = url; sending = true; progress.progress = 0; updateSendButton(); sender.send(url) }
    @objc private func background() { sender.disconnect() }
    @objc private func done() { sender.disconnect(); dismiss(animated: true) }
}
