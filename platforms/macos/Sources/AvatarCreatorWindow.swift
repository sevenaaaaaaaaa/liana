import AppKit

/// 「图片 → 3D 形象」：**纯原生窗口，不内嵌网页**。
///
/// 3D 生成这一步本身在云端（第三方服务）完成，松萝不做、也不假装能做。
/// 但「在应用里嵌一个浏览器去访问第三方站点」是另一回事：那会把登录态、
/// Cookie、追踪脚本一起带进输入法进程。这里改为——原生说明 → 用你的浏览器打开
/// → 生成后把 .vrm 拖回这个窗口（或点导入）。应用内零远程内容。
final class AvatarCreatorWindowController: NSWindowController {
    static let shared = AvatarCreatorWindowController()

    private static let creatorURL = URL(string: "https://vtubeme.com/create/picture")!
    private let statusLabel = NSTextField(labelWithString: "还没有导入。生成完成后把 .vrm 文件拖到这里。")
    private let dropZone = VRMDropView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "用一张照片做 3D 形象"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "cube.transparent",
            accessibilityDescription: "3D 形象"
        ) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "照片 → 3D 形象")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: """
        3D 建模这一步需要第三方云服务（例如 VTubeMe）。松萝不会把网页嵌进输入法：\
        点下面的按钮，用你自己的浏览器打开它，生成并下载 .vrm，再把文件拖回来。
        这样登录态、Cookie 与追踪脚本都留在浏览器里，不进输入法进程。
        """)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        let open = NSButton(title: "在浏览器打开 VTubeMe", target: self, action: #selector(openInBrowser))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"

        let importButton = NSButton(title: "导入 VRM…", target: self, action: #selector(importVRM))
        importButton.bezelStyle = .rounded

        dropZone.onDrop = { [weak self] url in self?.applyVRM(at: url) }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let buttons = NSStackView(views: [open, importButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, body, dropZone, buttons, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: icon)
        stack.setCustomSpacing(16, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropZone.heightAnchor.constraint(equalToConstant: 150),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(Self.creatorURL)
        statusLabel.stringValue = "已用浏览器打开。生成完成后下载 .vrm，拖回这个窗口即可。"
    }

    @objc private func importVRM() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择刚下载的 VRM 文件（.vrm）"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.init(filenameExtension: "vrm") ?? .data]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyVRM(at: url)
    }

    private func applyVRM(at url: URL) {
        do {
            try PetImporter.importVRM(from: url, packId: "vrm-cloud", name: "云端生成 VRM")
            PetWindowController.activePackId = "vrm-cloud"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            statusLabel.stringValue = "已导入并切换：\(url.lastPathComponent)"
            PetWindowController.shared.showToast("已导入并切换：\(url.lastPathComponent)", duration: 4)
        } catch {
            statusLabel.stringValue = "导入失败：\(error.localizedDescription)"
            PetWindowController.shared.showToast("导入失败：\(error.localizedDescription)", duration: 6)
        }
    }
}

/// 拖拽接收区：虚线框 + 高亮，只接 .vrm 文件。
private final class VRMDropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 12,
            yRadius: 12
        )
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor.clear).setFill()
        path.fill()
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highlighted ? 2 : 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()

        let text = "把 .vrm 文件拖到这里"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private func vrmURL(_ sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else { return nil }
        return urls.first { $0.pathExtension.lowercased() == "vrm" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard vrmURL(sender) != nil else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let url = vrmURL(sender) else { return false }
        onDrop?(url)
        return true
    }
}
