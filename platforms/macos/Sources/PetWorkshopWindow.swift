import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 形象工坊：用一张或几张图片做纸偶桌宠（本机抠图 → 调骨架点 → 分配表情 → 试动作 → 保存 / 导出 .lianapet）。
final class PetWorkshopWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PetWorkshopWindowController()
    private let model = WorkshopModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "形象工坊"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WorkshopView(model: model))
    }

    required init?(coder: NSCoder) { nil }

    /// 打开工坊；`editing` 为已安装的纸偶形象包 id 时载入它继续编辑。
    func show(editing packId: String? = nil) {
        if let packId, let draft = PuppetPackStore.load(packId: packId) {
            model.load(draft)
        } else if model.draft.images.isEmpty {
            model.load(PuppetDraft())
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 开发用：直接载入图片（`--pet-workshop <图片…>`）。
    func debugAdd(_ urls: [URL]) {
        model.add(urls)
    }

    /// 直接导入 .lianapet（设置中心入口），成功后在工坊里打开。
    func importPack() {
        show()
        model.importPack()
    }
}

// MARK: - 模型

final class WorkshopModel: ObservableObject {
    @Published var draft = PuppetDraft()
    @Published var selected: UUID?
    @Published var busy = false
    @Published var status = "拖入 1 张或多张图片开始。全身、单人、背景简单的图效果最好。"
    @Published var previewToken = UUID()
    weak var previewView: PuppetPetView?
    private var previewWork: DispatchWorkItem?

    /// 预置动作（试动作按钮）：读随包的 actions.json
    let actions: [(id: String, name: String)] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("PetRuntime/puppet/actions.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = json["actions"] as? [String: [String: Any]] else { return [] }
        return actions
            .filter { $0.value["loop"] as? Bool != true }
            .map { (id: $0.key, name: $0.value["name"] as? String ?? $0.key) }
            .sorted { $0.name < $1.name }
    }()

    var selectedIndex: Int? {
        draft.images.firstIndex { $0.id == selected }
    }

    func load(_ draft: PuppetDraft) {
        self.draft = draft
        selected = draft.images.first { $0.role == .idle }?.id ?? draft.images.first?.id
        status = draft.packId == nil
            ? "拖入 1 张或多张图片开始。全身、单人、背景简单的图效果最好。"
            : "正在编辑「\(draft.name)」"
        refreshPreview(immediately: true)
    }

    // MARK: 图片

    func add(_ urls: [URL]) {
        let images = urls.filter { ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif", "bmp"].contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty, !busy else { return }
        busy = true
        status = "正在本机抠图与定位（\(images.count) 张）…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PuppetBuilder.process(images) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let processed):
                    var skipped = 0
                    for (name, var image) in processed {
                        guard let role = self.nextRole(hint: name) else {
                            skipped += 1
                            continue
                        }
                        image.role = role
                        self.draft.images.append(image)
                        self.selected = image.id
                    }
                    self.status = skipped > 0
                        ? "已添加；\(skipped) 张没有空位（每种表情一张，可删掉旧的再加）"
                        : "已添加。拖动右侧的点对准脖子和头顶，再给每张图选好表情。"
                    self.refreshPreview(immediately: true)
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func nextRole(hint: String) -> PuppetRole? {
        let used = Set(draft.images.map(\.role))
        if !used.contains(.idle) { return .idle }
        if let guess = PuppetRole.guess(from: hint), !used.contains(guess) { return guess }
        return PuppetRole.allCases.first { !used.contains($0) }
    }

    func remove(_ id: UUID) {
        draft.images.removeAll { $0.id == id }
        if !draft.images.contains(where: { $0.role == .idle }), !draft.images.isEmpty {
            draft.images[0].role = .idle
        }
        if selected == id { selected = draft.images.first?.id }
        refreshPreview(immediately: true)
    }

    /// 改表情：目标表情已被占用就和它互换。
    func setRole(_ role: PuppetRole, for id: UUID) {
        guard let index = draft.images.firstIndex(where: { $0.id == id }) else { return }
        let old = draft.images[index].role
        if let other = draft.images.firstIndex(where: { $0.role == role && $0.id != id }) {
            draft.images[other].role = old
        }
        draft.images[index].role = role
        refreshPreview(immediately: true)
    }

    func updateRig(_ rig: PuppetRig, final: Bool) {
        guard let index = selectedIndex else { return }
        draft.images[index].rig = rig
        if final { refreshPreview(immediately: false) }
    }

    // MARK: 预览

    func refreshPreview(immediately: Bool) {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.draft.images.contains(where: { $0.role == .idle }) else { return }
            let dir = PetRuntimeStore.puppetPreviewDir
            try? FileManager.default.removeItem(at: dir)
            try? PuppetPackStore.write(self.draft, to: dir, id: "puppet-preview")
            self.previewToken = UUID()
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0.05 : 0.3), execute: work)
    }

    func play(_ actionId: String) {
        previewView?.play(actionId)
    }

    // MARK: 保存 / 导入导出

    @discardableResult
    func save() -> String? {
        do {
            let id = try PuppetPackStore.save(draft)
            draft.packId = id
            PetWindowController.activePackId = id
            if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
            status = "已保存并换上「\(draft.name)」"
            return id
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    func exportPack() {
        guard draft.shareable else {
            status = "导出前请先确认图片是原创或已获授权，并勾选「可以分享」"
            return
        }
        guard let id = save() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(draft.name).\(PuppetPackStore.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: PuppetPackStore.fileExtension) ?? .zip]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PuppetPackStore.export(packId: id, to: url)
            status = "已导出：\(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = error.localizedDescription
        }
    }

    func importPack() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: PuppetPackStore.fileExtension) ?? .zip, .zip]
        panel.message = "选择 .lianapet 形象包"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try PuppetPackStore.importPack(from: url)
            PetWindowController.activePackId = id
            if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
            if let draft = PuppetPackStore.load(packId: id) { load(draft) }
            status = "已导入并换上：\(draft.name)"
        } catch {
            status = "导入失败：\(error.localizedDescription)"
        }
    }

    func startOver() {
        load(PuppetDraft())
    }
}

// MARK: - 视图

private let promptTemplate = """
同一个角色的一组桌宠立绘，共 6 张，每张单独输出：
角色：【在这里描述你的角色：性别/年龄感、发型发色、服装、配饰、画风（如 Q 版、日系赛璐璐、3D 卡通）】
统一要求：全身、正面站立、居中、单人、纯白或纯色背景、无文字无水印、同样的构图和大小、服装发型完全一致。
1. 平时：自然站立，微笑
2. 开心：眯眼大笑
3. 打字：低头专注，双手在身前
4. 睡觉：闭眼打瞌睡，头微微歪
5. 惊讶：睁大眼睛，嘴巴张开
6. 闭眼：和第 1 张完全一样，只是眼睛闭上（用来眨眼）
"""

struct WorkshopView: View {
    @ObservedObject var model: WorkshopModel
    @State private var dropTargeted = false
    @State private var showPrompt = false

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
                .frame(width: 300)
            Divider()
            editorColumn
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    // 左：实时预览 + 试动作
    private var previewColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.08))
                if model.draft.images.contains(where: { $0.role == .idle }) {
                    PuppetPreview(model: model)
                        .id(model.previewToken)
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("预览会出现在这里")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 320)
            Text("试试动作")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                    ForEach(model.actions, id: \.id) { action in
                        Button(action.name) { model.play(action.id) }
                            .controlSize(.small)
                            .lianaGlassButton()
                    }
                }
            }
            .disabled(model.draft.images.isEmpty)
        }
        .padding(16)
        .padding(.top, 20)
    }

    // 右：名字 / 图片与表情 / 骨架点 / 分享声明 / 操作
    private var editorColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("名字", text: $model.draft.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Picker("朝向", selection: $model.draft.faces) {
                            Text("正面").tag("front")
                            Text("朝左").tag("left")
                            Text("朝右").tag("right")
                        }
                        .frame(width: 160)
                        .help("侧身形象溜达时会按方向镜像")
                        Spacer()
                    }
                    imagesSection
                    if let index = model.selectedIndex {
                        rigSection(index)
                    }
                    shareSection
                    promptSection
                }
                .padding(20)
                .padding(.top, 16)
            }
            Divider()
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("导入 .lianapet…") { model.importPack() }
                Button("导出…") { model.exportPack() }
                    .disabled(model.draft.images.isEmpty)
                Button("保存并使用") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.draft.images.contains { $0.role == .idle } || model.busy)
            }
            .padding(12)
        }
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("图片与表情").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.draft.images.isEmpty {
                    Button("重新开始") { model.startOver() }.controlSize(.small)
                }
                Button("添加图片…") { pickImages() }
                    .controlSize(.small)
                    .disabled(model.busy)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.draft.images) { image in
                        imageCard(image)
                    }
                    dropCard
                }
                .padding(2)
            }
        }
    }

    private func imageCard(_ image: PuppetImage) -> some View {
        let isSelected = model.selected == image.id
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSImage(data: image.png) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 92, height: 110)
                    .background(CheckerBackground().clipShape(RoundedRectangle(cornerRadius: 10)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                    )
                    .onTapGesture { model.selected = image.id }
                Button {
                    model.remove(image.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
            Picker("", selection: Binding(
                get: { image.role },
                set: { model.setRole($0, for: image.id) }
            )) {
                ForEach(PuppetRole.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)
        }
    }

    private var dropCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
            Text("拖入图片")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .frame(width: 92, height: 110)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture { pickImages() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers)
            return true
        }
    }

    private func rigSection(_ index: Int) -> some View {
        let image = model.draft.images[index]
        return VStack(alignment: .leading, spacing: 8) {
            Text("骨架点").font(.system(size: 13, weight: .semibold))
            Text("红点放在脖子上（头绕它转动），蓝框盖住整个头，拖右上角的角调大小。识别不到脸的卡通形象需要手动对一下。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RigEditor(
                image: NSImage(data: image.png) ?? NSImage(),
                aspect: image.aspect,
                rig: image.rig
            ) { rig, final in
                model.updateRig(rig, final: final)
            }
            .id(image.id)
            .frame(height: 260)
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("这些图片是我原创或已获授权，可以分享", isOn: $model.draft.shareable)
            Text("用他人照片（包括明星、网红）做的形象请只自己用：导出分享可能侵犯肖像权和著作权。未勾选时不能导出 .lianapet。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptSection: some View {
        DisclosureGroup("用 AI 生成一组图片（提示词模板）", isExpanded: $showPrompt) {
            VStack(alignment: .leading, spacing: 8) {
                Text(promptTemplate)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                HStack {
                    Text("在任意 AI 绘图工具里生成后，把整组图拖进来；文件名带 happy / sleep / blink 等会自动对上表情。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(promptTemplate, forType: .string)
                        model.status = "提示词已复制"
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择 1 张或多张图片（全身、单人、背景简单效果最好）"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls)
    }

    private func loadURLs(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.add(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
    }
}

/// 预览：形象工坊专用的纸偶视图（不转发台词/特效到桌面桌宠）。
private struct PuppetPreview: NSViewRepresentable {
    let model: WorkshopModel

    func makeNSView(context: Context) -> PuppetPetView {
        let view = PuppetPetView(frame: .zero, packPath: "packs/_preview/", preview: true)
        model.previewView = view
        return view
    }

    func updateNSView(_ nsView: PuppetPetView, context: Context) {}
}

/// 骨架点编辑：红点 = 脖子转轴，蓝框 = 头部范围（右上角拖动调大小，水平方向以脖子为中心）。
private struct RigEditor: View {
    let image: NSImage
    let aspect: CGFloat
    @State var rig: PuppetRig
    let onChange: (PuppetRig, Bool) -> Void

    init(image: NSImage, aspect: CGFloat, rig: PuppetRig, onChange: @escaping (PuppetRig, Bool) -> Void) {
        self.image = image
        self.aspect = aspect
        _rig = State(initialValue: rig)
        self.onChange = onChange
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = min(geo.size.width, h * aspect)
            let fitH = w / aspect
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: w, height: fitH)
                    .background(CheckerBackground())
                // 头部框
                let head = rig.head
                Rectangle()
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .background(Color.blue.opacity(0.08))
                    .frame(width: head.width * w, height: head.height * fitH)
                    .offset(x: head.minX * w, y: (1 - head.maxY) * fitH)
                    .allowsHitTesting(false)
                handle(color: .blue, size: 14)
                    .offset(x: head.maxX * w - 7, y: (1 - head.maxY) * fitH - 7)
                    .gesture(drag(w: w, h: fitH) { p in resizeHead(to: p) })
                handle(color: .red, size: 16)
                    .offset(x: rig.neck.x * w - 8, y: (1 - rig.neck.y) * fitH - 8)
                    .gesture(drag(w: w, h: fitH) { p in moveNeck(to: p) })
            }
            .frame(width: w, height: fitH)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "rig")
        }
    }

    private func handle(color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: size, height: size)
            .shadow(radius: 2)
    }

    /// 拖动：视图坐标 → 归一化坐标（y 自下而上），松手时通知保存并刷新预览。
    private func drag(w: CGFloat, h: CGFloat, apply: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("rig"))
            .onChanged { value in
                let p = CGPoint(
                    x: min(1, max(0, value.location.x / max(1, w))),
                    y: min(1, max(0, 1 - value.location.y / max(1, h)))
                )
                apply(p)
                onChange(rig, false)
            }
            .onEnded { _ in onChange(rig, true) }
    }

    private func moveNeck(to p: CGPoint) {
        // 头部框跟着脖子平移（保持大小与相对位置）
        let dx = p.x - rig.neck.x, dy = p.y - rig.neck.y
        rig.neck = p
        rig.head = rig.head.offsetBy(dx: dx, dy: dy)
    }

    private func resizeHead(to p: CGPoint) {
        let half = max(0.05, abs(p.x - rig.neck.x))
        let bottom = max(0, rig.neck.y - 0.02)
        let top = max(bottom + 0.05, p.y)
        rig.head = CGRect(x: rig.neck.x - half, y: bottom, width: half * 2, height: top - bottom)
    }
}

/// 透明背景的棋盘格底纹。
private struct CheckerBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) where (row + col) % 2 == 0 {
                    context.fill(
                        Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(Color.secondary.opacity(0.12))
                    )
                }
            }
        }
    }
}
