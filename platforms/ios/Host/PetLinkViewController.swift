import UIKit
import UniformTypeIdentifiers

final class PetLinkViewController: UIViewController, UIDocumentPickerDelegate {
    private var profile = PetLink.load(account: "mac")
    private let status = UILabel()
    private let macName = UILabel()
    private let sendButton = UIButton(type: .system)
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
        super.viewDidLoad()
        title = "Mac 桌宠收件箱"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        stack.addArrangedSubview(label("把文件交给 Mac 桌宠", style: .title2))
        stack.addArrangedSubview(label("首次连接：在 Mac 右键桌宠 → 连接 iPhone／接收文件，打开二维码。两端保持在同一局域网。", style: .body))
        macName.font = .preferredFont(forTextStyle: .headline); macName.numberOfLines = 0
        stack.addArrangedSubview(macName)
        let pair = UIStackView()
        pair.distribution = .fillEqually; pair.spacing = 12
        pair.addArrangedSubview(button("扫码配对", symbol: "qrcode.viewfinder", id: "mac.scan") { [weak self] in
            guard let self else { return }
            let scanner = PairingScannerViewController()
            scanner.onCode = { [weak self] in self?.pair($0) }
            self.present(UINavigationController(rootViewController: scanner), animated: true)
        })
        pair.addArrangedSubview(button("粘贴配对码", symbol: "doc.on.clipboard", id: "mac.paste") { [weak self] in
            guard let code = UIPasteboard.general.string else { self?.status.text = "剪贴板没有配对码，请先在 Mac 复制。"; return }
            self?.pair(code.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        stack.addArrangedSubview(pair)
        stack.addArrangedSubview(button("连接已配对 Mac", symbol: "desktopcomputer", id: "mac.connect") { [weak self] in self?.connect() })
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .body)
        status.accessibilityIdentifier = "mac.status"
        status.text = "扫描一次并在 Mac 允许配对，之后可直接连接。"
        stack.addArrangedSubview(status)
        sendButton.setTitle("选择文件发送", for: .normal)
        sendButton.accessibilityIdentifier = "mac.send"
        sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        sendButton.addAction(UIAction { [weak self] _ in self?.chooseFile() }, for: .touchUpInside)
        stack.addArrangedSubview(sendButton)
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(label("文件经本地加密连接发送，Mac 校验并保存后才显示送达。桌宠会提示收到文件，保存在 Mac「下载 → 松萝收件箱」。单文件不超过 200MB，发送期间保持 App 前台。", style: .footnote))
        stack.addArrangedSubview(button("取消传输／断开", symbol: "xmark.circle", id: "mac.cancel") { [weak self] in self?.sender.disconnect() })
        stack.addArrangedSubview(button("忘记此 Mac", symbol: "trash", id: "mac.forget") { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "忘记配对的 Mac？", message: "需要重新扫描才能连接。Mac 收件箱中的文件保留。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "忘记", style: .destructive) { [weak self] _ in
                self?.sender.disconnect(); PetLink.forget(account: "mac"); self?.profile = nil; self?.updateSendButton()
            })
            self.present(alert, animated: true)
        })
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        updateSendButton()
        if profile != nil { connect() }
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
        var config = UIButton.Configuration.tinted(); config.title = title; config.image = UIImage(systemName: symbol); config.imagePadding = 8
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    private func updateSendButton() {
        macName.text = profile.map { "已配对：" + $0.name } ?? "尚未配对 Mac"
        sendButton.isEnabled = connected && !sending
        sendButton.setTitle(pendingFile.map { "发送「" + $0.lastPathComponent + "」" } ?? "选择文件发送", for: .normal)
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
