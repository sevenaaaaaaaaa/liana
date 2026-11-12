import UIKit
import ImageIO

final class KeyboardToolsPanel: UIView {
    var onInsert: ((String) -> Void)?
    var onReceive: (() -> Void)?
    var onSystemLexicon: (() -> Void)?
    var onPhrases: (() -> Void)?
    var onCursor: ((Int) -> Void)?
    var onMethod: ((MobileInputMethod) -> Void)?
    var onClipboardSend: (() -> Void)?
    var onClipboardReceive: (() -> Void)?
    var onDevices: (() -> Void)?
    var onLayout: (() -> Void)?
    var onClose: (() -> Void)?
    private let content = LianaUI.vertical(spacing: 6)
    private let message = LianaUI.label("", size: 12, muted: true)
    private let tabs = LianaUI.segment(["输入", "表情", "同步", "词库"])
    private let method: MobileInputMethod

    var section: Int { tabs.selectedSegmentIndex }
    /// 内容或计数变化后重建分类内容（不清空面板）。
    func refresh() { render() }

    func select(section: Int) {
        let index = min(tabs.numberOfSegments - 1, max(0, section))
        guard index != tabs.selectedSegmentIndex else { return }
        tabs.selectedSegmentIndex = index
        render()
        LianaMotion.reveal(content)
    }

    init(method: MobileInputMethod = .pinyin, section: Int = 0) {
        self.method = method
        super.init(frame: .zero)
        backgroundColor = LianaPalette.keyboard
        let back = LianaPressButton(frame: .zero)
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.accessibilityIdentifier = "tools.close"; back.accessibilityLabel = "返回键盘"
        back.widthAnchor.constraint(equalToConstant: 44).isActive = true
        back.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        tabs.selectedSegmentIndex = min(3, max(0, section)); tabs.accessibilityIdentifier = "tools.section"; tabs.accessibilityLabel = "输入工具分类"
        tabs.addAction(UIAction { [weak self] _ in self?.render(); if let self { LianaMotion.reveal(self.content) } }, for: .valueChanged)
        let header = UIStackView(arrangedSubviews: [back, tabs]); header.spacing = 4
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let scroll = UIScrollView(); scroll.contentInsetAdjustmentBehavior = .never; scroll.showsVerticalScrollIndicator = false
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16)])
        message.isHidden = true; message.numberOfLines = 3; message.accessibilityIdentifier = "tools.status"
        let footer = UIStackView(arrangedSubviews: [message]); footer.isLayoutMarginsRelativeArrangement = true; footer.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let root = LianaUI.vertical([header, scroll, footer], spacing: 4); root.translatesAutoresizingMaskIntoConstraints = false; addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: leadingAnchor),root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),root.topAnchor.constraint(equalTo: topAnchor),root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)])
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func status(_ text: String) { message.text = text; message.isHidden = false; UIAccessibility.post(notification: .announcement, argument: text) }
    private func button(_ title: String, icon: String? = nil, id: String, action: @escaping () -> Void) -> LianaPressButton {
        let button = LianaPressButton(frame: .zero); button.surface = .utility; button.rounded = 9
        button.setTitle(title, for: .normal); button.titleLabel?.font = LianaPalette.font(13, weight: .medium, maximum: 19)
        button.titleLabel?.numberOfLines = 2
        button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 5, bottom: 7, right: 5)
        if let icon { button.setImage(UIImage(systemName: icon), for: .normal); button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .medium), forImageIn: .normal); button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -3, bottom: 0, right: 3) }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button
    }
    private func row(_ views: [UIView]) -> UIStackView { let row = UIStackView(arrangedSubviews: views); row.distribution = .fillEqually; row.spacing = 6; return row }
    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        message.isHidden = true
        switch tabs.selectedSegmentIndex {
        case 0:
            let order: [MobileInputMethod] = [.pinyin,.t9,.handwriting,.flypy,.mspy,.zrm,.wubi]
            var items: [UIView] = order.map { mode in
                let key = button(mode.title, id: "method." + mode.rawValue) { [weak self] in self?.onMethod?(mode) }
                key.isSelected = mode == method; key.accessibilityTraits.formUnion(mode == method ? .selected : [])
                return key
            }
            items.append(button("接收内容", icon: "tray.and.arrow.down", id: "tools.receive") { [weak self] in self?.onReceive?() })
            items.append(button("布局手感", icon: "slider.horizontal.3", id: "tools.layout") { [weak self] in self?.onLayout?() })
            items.append(button("左移光标", icon: "arrow.left", id: "tools.cursor.left") { [weak self] in self?.onCursor?(-1) })
            items.append(button("右移光标", icon: "arrow.right", id: "tools.cursor.right") { [weak self] in self?.onCursor?(1) })
            content.spacing = 4
            for i in stride(from: 0, to: items.count, by: 3) { content.addArrangedSubview(row(Array(items[i..<min(i+3,items.count)]))) }
        case 1:
            content.spacing = 6
            let faces = ["(๑•̀ㅂ•́)و✧","(｡･ω･｡)","(≧▽≦)","(つД`)ノ","¯\\_(ツ)_/¯","(╯°□°）╯︵ ┻━┻","(´･_･`)","(づ｡◕‿‿◕｡)づ"]
            for i in stride(from: 0, to: faces.count, by: 2) {
                let cells = (i..<min(i+2,faces.count)).map { index in button(faces[index], id: "face.\(index)") { [weak self] in self?.onInsert?(faces[index]) } }
                content.addArrangedSubview(row(cells))
            }
            content.addArrangedSubview(button("接收 App 中的 GIF", icon: "tray.and.arrow.down", id: "tools.receive") { [weak self] in self?.onReceive?() })
            reloadGIFs()
        case 2:
            content.spacing = 8
            content.addArrangedSubview(row([
                button("发到 Mac", icon: "arrow.up.right", id: "tools.clip.send") { [weak self] in self?.onClipboardSend?() },
                button("从 Mac 接收", icon: "arrow.down.left", id: "tools.clip.receive") { [weak self] in self?.onClipboardReceive?() },
            ]))
            content.addArrangedSubview(row([
                button("接收配对", icon: "link", id: "tools.receive") { [weak self] in self?.onReceive?() },
                button("外接设备", icon: "waveform", id: "tools.devices") { [weak self] in self?.onDevices?() },
            ]))
            content.addArrangedSubview(LianaUI.label("同一局域网内，按需同步文字。首次先在 App 配对 Mac。", size: 12, muted: true))
        default:
            content.spacing = 8
            let phrases = MobilePhrases.load()
            content.addArrangedSubview(row([
                button("常用短语 \(phrases.count) 条", icon: "text.bubble", id: "tools.phrases") { [weak self] in self?.onPhrases?() },
                button("接收短语", icon: "tray.and.arrow.down", id: "tools.phrases.receive") { [weak self] in self?.onReceive?() },
            ]))
            content.addArrangedSubview(LianaUI.label("短语由主 App「词库」页编辑后复制，键盘点「接收短语」覆盖；默认内置 12 条。", size: 12, muted: true))
            content.addArrangedSubview(button("接收已导入的词库", icon: "tray.and.arrow.down", id: "tools.receive") { [weak self] in self?.onReceive?() })
            content.addArrangedSubview(button("添加系统补充词库", icon: "text.badge.plus", id: "tools.system") { [weak self] in self?.onSystemLexicon?() })
            content.addArrangedSubview(LianaUI.label("本地与 GitHub 词库在 App 导入；系统补充包括姓名、文本替换等。", size: 12, muted: true))
        }
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
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.gifFolder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty {
            content.addArrangedSubview(LianaUI.label("GIF 可在 App 中导入，接收后会出现在这里。", size: 12, muted: true)); return
        }
        for offset in stride(from: 0, to: min(files.count,12), by: 2) {
            let cells = files[offset..<min(offset+2,files.count)].map { url -> UIView in
                let key = button("复制 GIF", id: "gif.copy") { [weak self] in
                    guard let data = try? Data(contentsOf: url) else { return }
                    UIPasteboard.general.setData(data, forPasteboardType: "com.compuserve.gif"); self?.status("GIF 已复制，在支持图片的聊天框粘贴即可。")
                }
                if let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:48] as CFDictionary) { key.setImage(UIImage(cgImage:image),for:.normal) }
                return key
            }
            content.addArrangedSubview(row(cells))
        }
        content.addArrangedSubview(button("清空 GIF", icon: "trash", id:"gif.clear") { [weak self] in try? FileManager.default.removeItem(at:Self.gifFolder); self?.render(); self?.status("本地 GIF 已清空。") })
    }
}
