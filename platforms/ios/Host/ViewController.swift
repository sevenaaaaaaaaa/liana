import UIKit

/// 宿主 App：安装引导页。真正的键盘在扩展里（系统设置启用后全局可用）。
final class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        let title = UILabel()
        title.text = "松萝输入法"
        title.font = .systemFont(ofSize: 34, weight: .bold)

        let body = UILabel()
        body.numberOfLines = 0
        body.textAlignment = .center
        body.text = """
        键盘不会自动出现，需要手动添加一次：

        1. 打开「设置 → 通用 → 键盘 → 键盘」
        2. 点「添加新键盘…」→ 中文（简体）→ 松萝键盘
        3. 回到任意输入框，长按左下角 🌐 选「松萝键盘」

        提示：添加后如果键盘立刻消失，说明系统把它当成了异常扩展，
        重开一次 App 再试；在设置里给「松萝键盘」打开「允许完全访问」
        才能使用词库同步（纯本地输入不需要）。
        """

        // 一键跳到本 App 的设置页：用户在系统设置里翻不到键盘项时至少有个入口
        let openSettings = UIButton(type: .system)
        openSettings.setTitle("打开系统设置", for: .normal)
        openSettings.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        openSettings.addTarget(self, action: #selector(openAppSettings), for: .touchUpInside)

        let engine = UILabel()
        engine.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        engine.textColor = .secondaryLabel
        engine.text = "Rust 内核 · 本地引擎 · 无服务器"

        [title, body, openSettings, engine].forEach { stack.addArrangedSubview($0) }
    }

    @objc private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}