import UIKit

/// 宿主负责原生启用引导与试打；输入引擎和学习数据留在键盘扩展自己的容器内。
final class ViewController: UIViewController {
    private let testInput = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        stack.addArrangedSubview(label("松萝输入法", style: .largeTitle, weight: .bold))
        stack.addArrangedSubview(label("让中文输入，回到你的设备上。", style: .title3))
        let privacy = label("离线拼音 · 本地学习 · 无需完全访问", style: .subheadline)
        privacy.textColor = .systemGreen
        stack.addArrangedSubview(privacy)
        stack.addArrangedSubview(label("首次使用，添加一次键盘", style: .headline))
        for text in [
            "1   打开设置 → 通用 → 键盘 → 键盘。",
            "2   添加新键盘，在第三方键盘中选择松萝输入法／松萝键盘。",
            "3   回到输入框，长按地球键选择松萝键盘。",
        ] { stack.addArrangedSubview(label(text, style: .body)) }
        var configuration = UIButton.Configuration.filled()
        configuration.title = "打开键盘设置"
        configuration.image = UIImage(systemName: "keyboard")
        configuration.imagePadding = 10
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        let settings = UIButton(configuration: configuration)
        settings.addTarget(self, action: #selector(openAppSettings), for: .touchUpInside)
        stack.addArrangedSubview(settings)
        var macConfig = UIButton.Configuration.tinted()
        macConfig.title = "连接 Mac 桌宠 · 发送文件"
        macConfig.image = UIImage(systemName: "desktopcomputer")
        macConfig.imagePadding = 10
        macConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        let mac = UIButton(configuration: macConfig)
        mac.accessibilityIdentifier = "mac.open"
        mac.addAction(UIAction { [weak self] _ in self?.showMacLink() }, for: .touchUpInside)
        stack.addArrangedSubview(mac)
        var toolsConfig = UIButton.Configuration.tinted()
        toolsConfig.title = "语音 · 词库 · GIF · 剪贴板"
        toolsConfig.image = UIImage(systemName: "square.grid.2x2")
        toolsConfig.imagePadding = 10
        let tools = UIButton(configuration: toolsConfig)
        tools.accessibilityIdentifier = "mobile.tools"
        tools.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        tools.addAction(UIAction { [weak self] _ in self?.present(UINavigationController(rootViewController: MobileToolsViewController()), animated: true) }, for: .touchUpInside)
        stack.addArrangedSubview(tools)
        stack.addArrangedSubview(label("先调到顺手，再开始输入", style: .headline))
        stack.addArrangedSubview(label("键盘顶部四向箭头：上下拖动改变高度，左右拖动移动入口。滑块图标可调宽度、左右位置、候选字号与底部留白，也可一键恢复默认。主题只提供黑色、白色，默认跟随系统。", style: .body))
        stack.addArrangedSubview(label("外接语音／Vibe Code 设备", style: .headline))
        stack.addArrangedSubview(label("HID 设备在 iOS 设置 → 蓝牙中配对，由系统直接输入。BLE 设备点键盘顶部波形图标连接：扫描、选择设备及文字通知通道，再预览插入。BLE 是实验接口，需要允许完全访问和蓝牙权限；普通拼音与布局调节不需要。", style: .body))
        stack.addArrangedSubview(label("BLE 接收设备已识别的 UTF-8 行或 JSON Lines 文字，不处理原始音频。iOS 第三方键盘不能直接使用麦克风，硬件需自行完成语音识别。", style: .footnote))
        stack.addArrangedSubview(label("添加后，在这里试打", style: .headline))
        stack.addArrangedSubview(label("例如输入 nihao，选择「你好」；再试试数字、大写和标点。", style: .subheadline))
        testInput.accessibilityIdentifier = "typing-test"
        testInput.accessibilityLabel = "松萝试打输入框"
        testInput.font = .preferredFont(forTextStyle: .body)
        testInput.adjustsFontForContentSizeCategory = true
        testInput.backgroundColor = .secondarySystemGroupedBackground
        testInput.layer.cornerRadius = 14
        testInput.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        testInput.autocorrectionType = .no
        testInput.smartQuotesType = .no
        testInput.heightAnchor.constraint(equalToConstant: 132).isActive = true
        stack.addArrangedSubview(testInput)
        let hint = label("输入和学习记录保存在键盘本机沙盒。密码框、电话键盘或不支持第三方键盘的应用会由系统接管。", style: .footnote)
        hint.textColor = .secondaryLabel
        stack.addArrangedSubview(hint)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let footer = label("Liana \(version) (\(build)) · iOS", style: .caption1)
        footer.textColor = .tertiaryLabel
        stack.addArrangedSubview(footer)
    }

    private func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        let base = UIFont.preferredFont(forTextStyle: style)
        label.font = weight.map { UIFont.systemFont(ofSize: base.pointSize, weight: $0) } ?? base
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    @objc private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func showMacLink(file: URL? = nil) {
        if let navigation = presentedViewController as? UINavigationController,
           let existing = navigation.viewControllers.first as? PetLinkViewController {
            if let file { existing.receiveFile(file) }
            return
        }
        let link = PetLinkViewController()
        if let file { link.receiveFile(file) }
        present(UINavigationController(rootViewController: link), animated: true)
    }
}
