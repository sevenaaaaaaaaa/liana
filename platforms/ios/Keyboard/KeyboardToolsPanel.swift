import UIKit
import ImageIO

final class KeyboardToolsPanel: UIView {
    var onInsert: ((String) -> Void)?
    var onReceive: (() -> Void)?
    var onSystemLexicon: (() -> Void)?
    var onMethod: ((MobileInputMethod) -> Void)?
    var onClipboardSend: (() -> Void)?
    var onClipboardReceive: (() -> Void)?
    var onClose: (() -> Void)?
    private let stack = UIStackView()
    private let message = UILabel()
    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground; layer.cornerRadius = 12
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),scroll.topAnchor.constraint(equalTo: topAnchor),scroll.bottomAnchor.constraint(equalTo: bottomAnchor),stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)])
        let top = UIStackView(); top.distribution = .fillEqually
        top.addArrangedSubview(button("接收 App 内容", id: "tools.receive") { [weak self] in self?.onReceive?() })
        top.addArrangedSubview(button("关闭", id: "tools.close") { [weak self] in self?.onClose?() }); stack.addArrangedSubview(top)
        message.font = .systemFont(ofSize: 12); message.numberOfLines = 0; message.textColor = .secondaryLabel
        message.text = "主 App 可录音转文字、导入词库与 GIF；复制后点「接收 App 内容」。长按中/EN 切换方案。"
        stack.addArrangedSubview(message)
        // Inline choices remain inside the extension's bounds on every iOS host.
        let schemes = MobileInputMethod.allCases
        for index in stride(from: 0, to: schemes.count, by: 2) {
            let row = UIStackView(); row.distribution = .fillEqually
            for mode in schemes[index..<min(index+2,schemes.count)] {
                row.addArrangedSubview(button(mode.title, id: "method." + mode.rawValue) { [weak self] in self?.onMethod?(mode) })
            }
            if row.arrangedSubviews.count == 1 { row.addArrangedSubview(UIView()) }
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(button("导入系统补充词库（联系人／文本替换）", id: "tools.system") { [weak self] in self?.onSystemLexicon?() })
        let clip = UIStackView(); clip.distribution = .fillEqually
        clip.addArrangedSubview(button("发送剪贴板到 Mac", id: "tools.clip.send") { [weak self] in self?.onClipboardSend?() })
        clip.addArrangedSubview(button("接收 Mac 剪贴板", id: "tools.clip.receive") { [weak self] in self?.onClipboardReceive?() }); stack.addArrangedSubview(clip)
        let faces = ["(๑•̀ㅂ•́)و✧","(｡･ω･｡)","(≧▽≦)","(つД`)ノ","¯\\_(ツ)_/¯","(╯°□°）╯︵ ┻━┻","(´･_･`)","(づ｡◕‿‿◕｡)づ"]
        for i in stride(from: 0, to: faces.count, by: 2) {
            let row = UIStackView(); row.distribution = .fillEqually
            for text in faces[i..<min(i+2, faces.count)] { row.addArrangedSubview(button(text, id: "face.\(i)") { [weak self] in self?.onInsert?(text) }) }; stack.addArrangedSubview(row)
        }
        reloadGIFs()
    }
    required init?(coder: NSCoder) { fatalError() }
    func status(_ text: String) { message.text = text }
    private func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.titleLabel?.font = .systemFont(ofSize: 14); b.accessibilityIdentifier = id
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside); return b
    }
    static let gifFolder = MobileLexicon.directory.appendingPathComponent("GIF", isDirectory: true)
    static func saveGIF(_ data: Data) throws {
        guard data.count <= 4_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { throw MobileImportError.message("请选择不超过 4MB 的有效 GIF 文件。") }
        try FileManager.default.createDirectory(at: gifFolder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: gifFolder, includingPropertiesForKeys: nil)) ?? []
        guard files.count < 12 else { throw MobileImportError.message("最多保存 12 个 GIF，请先清空后再导入。") }
        try data.write(to: gifFolder.appendingPathComponent(UUID().uuidString + ".gif"), options: .atomic)
    }
    private func reloadGIFs() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.gifFolder, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        for url in files.prefix(12) {
            let b = button("GIF · 复制后在聊天框粘贴", id: "gif.copy") { [weak self] in
                guard let data = try? Data(contentsOf: url) else { return }
                UIPasteboard.general.setData(data, forPasteboardType: "com.compuserve.gif"); self?.status("GIF 已复制，请在支持图片粘贴的聊天框粘贴。")
            }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:64] as CFDictionary) { b.setImage(UIImage(cgImage:image),for:.normal); b.imageView?.contentMode = .scaleAspectFit }
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(button("清空本地 GIF", id:"gif.clear") { [weak self] in try? FileManager.default.removeItem(at: Self.gifFolder); self?.status("已清空，关闭面板后重新打开。") })
    }
}
