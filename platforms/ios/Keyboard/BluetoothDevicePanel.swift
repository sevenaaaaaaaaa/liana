import UIKit

final class BluetoothDevicePanel: UIView {
    private let bridge = BluetoothTextBridge()
    private let access: () -> Bool
    private let insert: (String) -> Void
    private let status = UILabel()
    private let preview = UILabel()
    private let results = UIStackView()
    private let insertButton = UIButton(type: .system)
    private let scanButton = UIButton(type: .system)
    private let reconnectButton = UIButton(type: .system)
    private let decisions = UIStackView()
    private var finalText = ""
    private var partialText = ""

    init(hasFullAccess: @escaping () -> Bool, insert: @escaping (String) -> Void) {
        access = hasFullAccess
        self.insert = insert
        super.init(frame: .zero)
        accessibilityIdentifier = "devices.panel"
        backgroundColor = LianaTheme.bg
        let scroll = UIScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24),
        ])
        stack.addArrangedSubview(label("外接语音／Vibe Code 设备", style: .headline))
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.accessibilityIdentifier = "devices.status"
        let controls = UIStackView()
        controls.distribution = .fillEqually
        configure(scanButton, title: "扫描 BLE", id: "devices.scan") { [weak self] in self?.connectAction { self?.bridge.scan() } }
        configure(reconnectButton, title: "连接上次", id: "devices.reconnect") { [weak self] in self?.connectAction { self?.bridge.connectLast() } }
        let disconnect = UIButton(type: .system)
        configure(disconnect, title: "断开", id: "devices.disconnect") { [weak self] in self?.stop() }
        [scanButton, reconnectButton, disconnect].forEach { controls.addArrangedSubview($0) }
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(status)
        preview.font = .preferredFont(forTextStyle: .body)
        preview.numberOfLines = 4
        preview.accessibilityIdentifier = "devices.preview"
        stack.addArrangedSubview(preview)
        decisions.distribution = .fillEqually
        configure(insertButton, title: "插入文字", id: "devices.insert") { [weak self] in
            guard let self, !self.finalText.isEmpty else { return }
            let text = self.finalText
            self.finalText = ""
            self.updatePreview()
            self.insert(text)
        }
        let clear = UIButton(type: .system)
        configure(clear, title: "清空预览", id: "devices.clear") { [weak self] in self?.clearPreview() }
        decisions.addArrangedSubview(insertButton)
        decisions.addArrangedSubview(clear)
        stack.addArrangedSubview(decisions)
        results.axis = .vertical
        results.spacing = 6
        stack.addArrangedSubview(results)
        let details = UIStackView()
        details.axis = .vertical
        details.spacing = 10
        details.isHidden = true
        let detailsButton = UIButton(type: .system)
        configure(detailsButton, title: "HID 配对说明与 BLE 协议", id: "devices.details") { [weak details] in details?.isHidden.toggle() }
        stack.addArrangedSubview(detailsButton)
        stack.addArrangedSubview(details)
        details.addArrangedSubview(label("HID：在 iOS「设置 → 蓝牙」中配对，设备会直接向当前 App 输入。iOS 负责连接，松萝无法在键盘内代替系统配对或拦截 HID 按键。", style: .caption1))
        details.addArrangedSubview(label("BLE：接收设备已识别的文字。此实验接口不录音、不解码音频；需要设备提供兼容的 Notify／Indicate 文字通道。关闭键盘会断开连接。", style: .caption1))
        let format = UISegmentedControl(items: ["UTF-8 行", "JSON Lines"])
        format.selectedSegmentIndex = UserDefaults.standard.integer(forKey: "ble.format") == 1 ? 1 : 0
        bridge.setFormat(format.selectedSegmentIndex == 0 ? .lines : .json)
        format.accessibilityLabel = "设备文字协议"
        format.accessibilityIdentifier = "devices.format"
        format.heightAnchor.constraint(equalToConstant: 44).isActive = true
        format.addAction(UIAction { [weak self, weak format] _ in
            guard let self, let format else { return }
            self.bridge.setFormat(format.selectedSegmentIndex == 0 ? .lines : .json)
            UserDefaults.standard.set(format.selectedSegmentIndex, forKey: "ble.format")
            self.clearPreview()
        }, for: .valueChanged)
        details.addArrangedSubview(format)
        details.addArrangedSubview(label("接收文字后先预览，点击才插入。蓝牙权限仅在连接时请求，不发送输入框内容。", style: .caption1))
        bridge.onChange = { [weak self] in self?.refresh() }
        bridge.onText = { [weak self] event in self?.receive(event) }
        updatePreview()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stop() { bridge.stop(); clearPreview() }

    private func configure(_ button: UIButton, title: String, id: String, action: @escaping () -> Void) {
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func connectAction(_ action: () -> Void) {
        guard access() else {
            status.text = "BLE 需要在「设置 → 通用 → 键盘 → 松萝键盘」允许完全访问，再允许蓝牙权限。普通拼音不需要这些权限。"
            return
        }
        clearPreview()
        action()
    }

    private func refresh() {
        status.text = bridge.status
        results.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if bridge.subscribed == nil, !bridge.characteristics.isEmpty {
            results.addArrangedSubview(label("选择文字通知通道（按设备文档确认）", style: .subheadline))
            for characteristic in bridge.characteristics {
                let button = UIButton(type: .system)
                let title = "服务 \(characteristic.service?.uuid.uuidString ?? "")\n通知 \(characteristic.uuid.uuidString)"
                configure(button, title: title, id: "devices.channel." + characteristic.uuid.uuidString) { [weak self] in self?.bridge.subscribe(characteristic) }
                button.titleLabel?.numberOfLines = 0
                button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
                results.addArrangedSubview(button)
            }
        } else if bridge.characteristics.isEmpty {
            for device in bridge.devices {
                let button = UIButton(type: .system)
                configure(button, title: "\(device.name) · \(device.rssi) dBm · \(device.peripheral.identifier.uuidString.prefix(8))", id: "devices.peer." + device.peripheral.identifier.uuidString) { [weak self] in
                    self?.clearPreview()
                    self?.bridge.connect(device.peripheral)
                }
                button.titleLabel?.numberOfLines = 2
                results.addArrangedSubview(button)
            }
        }
    }

    func receive(_ event: BLETextDecoder.Event) {
        switch event {
        case .partial(let text): partialText = text
        case .final(let text):
            guard finalText.utf8.count + text.utf8.count + 1 <= 32_768 else {
                bridge.stop()
                status.text = "预览已满，已断开；请插入或清空已有文字后再连接。"
                return
            }
            if !finalText.isEmpty { finalText += "\n" }
            finalText += text
            partialText = ""
        }
        updatePreview()
    }

    private func updatePreview() {
        preview.text = [finalText, partialText.isEmpty ? "" : "识别中：" + partialText].filter { !$0.isEmpty }.joined(separator: "\n")
        if preview.text?.isEmpty != false { preview.text = "等待设备文字…" }
        insertButton.isEnabled = !finalText.isEmpty
        preview.isHidden = finalText.isEmpty && partialText.isEmpty
        decisions.isHidden = finalText.isEmpty && partialText.isEmpty
    }

    private func clearPreview() { finalText = ""; partialText = ""; updatePreview() }
}
