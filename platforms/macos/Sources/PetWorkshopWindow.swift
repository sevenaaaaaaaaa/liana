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
    func debugAdd(_ urls: [URL], actionsTab: Bool = false) {
        model.add(urls)
        if actionsTab {
            model.tab = 1
            model.copyPreset("happy_bounce")
        }
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

    /// 随包的预置动作库（actions.json）：动作与默认触发
    private static let library: [String: Any] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("PetRuntime/puppet/actions.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }()

    let presetActions: [String: [String: Any]] = (library["actions"] as? [String: [String: Any]] ?? [:])
        .filter { $0.value["loop"] as? Bool != true }

    let presetTriggers: [String: [String]] = (library["triggers"] as? [String: Any] ?? [:]).compactMapValues {
        ($0 as? [String]) ?? (($0 as? String).map { [$0] })
    }

    /// 预置动作（试动作按钮），按名字排序
    var actions: [(id: String, name: String)] {
        presetActions
            .map { (id: $0.key, name: $0.value["name"] as? String ?? $0.key) }
            .sorted { $0.name < $1.name }
    }

    /// 动作 id → 显示名（自定义优先）
    func actionName(_ id: String) -> String {
        draft.actions.first { $0.id == id }?.name ?? presetActions[id]?["name"] as? String ?? id
    }

    // MARK: 自定义动作

    @Published var selectedAction: String?
    @Published var tab = 0
    private var actionPreviewWork: DispatchWorkItem?

    var selectedActionIndex: Int? {
        draft.actions.firstIndex { $0.id == selectedAction }
    }

    private func nextActionId() -> String {
        var n = 1
        while draft.actions.contains(where: { $0.id == "my-\(n)" }) { n += 1 }
        return "my-\(n)"
    }

    func newAction() {
        let id = nextActionId()
        var action = PuppetActionDraft(id: id, name: "我的动作 \(id.dropFirst(3))")
        action.keyframes = [
            PuppetKeyframe(t: 0),
            PuppetKeyframe(t: 0.3, values: ["root.ty": 0.06, "root.sy": 0.05]),
            PuppetKeyframe(t: 0.6),
        ]
        draft.actions.append(action)
        selectedAction = id
        actionEdited()
    }

    /// 以预置动作为起点复制一份（只支持关键帧动作）。
    func copyPreset(_ presetId: String) {
        guard let json = presetActions[presetId],
              var action = PuppetActionDraft(id: nextActionId(), json: json) else {
            status = "这个预置动作含波形，不能在编辑器里改"
            return
        }
        action.name = "\(action.name)（改）"
        draft.actions.append(action)
        selectedAction = action.id
        actionEdited()
    }

    var copyablePresets: [(id: String, name: String)] {
        actions.filter { PuppetActionDraft(id: $0.id, json: presetActions[$0.id] ?? [:]) != nil }
    }

    func deleteAction(_ id: String) {
        draft.actions.removeAll { $0.id == id }
        for key in draft.triggers.keys {
            draft.triggers[key]?.removeAll { $0 == id }
            if draft.triggers[key]?.isEmpty == true { draft.triggers.removeValue(forKey: key) }
        }
        selectedAction = draft.actions.first?.id
    }

    /// 编辑后 0.35 秒在预览里播一遍（拖滑杆时不会连播）。
    func actionEdited() {
        actionPreviewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.previewSelectedAction() }
        actionPreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func previewSelectedAction() {
        guard let index = selectedActionIndex else { return }
        previewView?.playInline(draft.actions[index].json)
    }

    func playCustom(_ id: String) {
        guard let action = draft.actions.first(where: { $0.id == id }) else { return }
        previewView?.playInline(action.json)
    }

    // MARK: 触发与台词

    /// 某个触发器当前生效的动作（自定义覆盖 > 预置）
    func triggerActions(_ key: String) -> [String] {
        draft.triggers[key] ?? presetTriggers[key] ?? []
    }

    func toggleTrigger(_ key: String, action id: String) {
        var list = triggerActions(key)
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        draft.triggers[key] = list
    }

    func resetTrigger(_ key: String) {
        draft.triggers.removeValue(forKey: key)
    }

    func linesText(_ key: String) -> String {
        (draft.lines[key] ?? []).joined(separator: " / ")
    }

    func setLines(_ key: String, _ text: String) {
        let list = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if list.isEmpty { draft.lines.removeValue(forKey: key) } else { draft.lines[key] = list }
    }

    var selectedIndex: Int? {
        draft.images.firstIndex { $0.id == selected }
    }

    func load(_ draft: PuppetDraft) {
        self.draft = draft
        selected = draft.images.first { $0.role == .idle }?.id ?? draft.images.first?.id
        selectedAction = draft.actions.first?.id
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
                    ForEach(model.draft.actions) { action in
                        Button(action.name) { model.playCustom(action.id) }
                            .controlSize(.small)
                            .lianaGlassButton()
                            .tint(.orange)
                    }
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
            Picker("", selection: $model.tab) {
                Text("形象").tag(0)
                Text("动作与互动").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.top, 34)
            .padding(.bottom, 4)
            if model.tab == 1 {
                ActionsTab(model: model)
            } else {
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
            }
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
            .frame(height: 290)
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
        VStack(spacing: 6) {
            canvas
            HStack(spacing: 8) {
                if rig.eyes.isEmpty && rig.mouth == nil {
                    Button("标出眼睛和嘴巴") {
                        rig.addDefaultFeatures()
                        onChange(rig, true)
                    }
                    .help("用来自动生成眨眼和说话口型；照片一般会自动识别")
                } else {
                    Text("绿框 = 眼睛，橙框 = 嘴巴：拖中心移动，拖右上角调大小")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("清除") {
                        rig.eyes = []
                        rig.mouth = nil
                        onChange(rig, true)
                    }
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var canvas: some View {
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
                ForEach(rig.eyes.indices, id: \.self) { i in
                    featureBox(rig.eyes[i], color: .green, w: w, h: fitH,
                               move: { p in rig.eyes[i] = centered(rig.eyes[i], at: p) },
                               resize: { p in rig.eyes[i] = resized(rig.eyes[i], to: p) })
                }
                if let mouth = rig.mouth {
                    featureBox(mouth, color: .orange, w: w, h: fitH,
                               move: { p in rig.mouth = centered(mouth, at: p) },
                               resize: { p in rig.mouth = resized(mouth, to: p) })
                }
                handle(color: .red, size: 16)
                    .offset(x: rig.neck.x * w - 8, y: (1 - rig.neck.y) * fitH - 8)
                    .gesture(drag(w: w, h: fitH) { p in moveNeck(to: p) })
            }
            .frame(width: w, height: fitH)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "rig")
        }
    }

    /// 眼睛 / 嘴巴框：中心点拖动移动，右上角拖动调大小。
    @ViewBuilder
    private func featureBox(_ r: CGRect, color: Color, w: CGFloat, h: CGFloat,
                            move: @escaping (CGPoint) -> Void, resize: @escaping (CGPoint) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(color, lineWidth: 1.5)
            .background(color.opacity(0.12))
            .frame(width: r.width * w, height: r.height * h)
            .offset(x: r.minX * w, y: (1 - r.maxY) * h)
            .allowsHitTesting(false)
        handle(color: color, size: 10)
            .offset(x: r.midX * w - 5, y: (1 - r.midY) * h - 5)
            .gesture(drag(w: w, h: h, apply: move))
        handle(color: color, size: 9)
            .offset(x: r.maxX * w - 4.5, y: (1 - r.maxY) * h - 4.5)
            .gesture(drag(w: w, h: h, apply: resize))
    }

    private func centered(_ r: CGRect, at p: CGPoint) -> CGRect {
        CGRect(x: p.x - r.width / 2, y: p.y - r.height / 2, width: r.width, height: r.height)
    }

    private func resized(_ r: CGRect, to p: CGPoint) -> CGRect {
        CGRect(x: r.minX, y: r.minY, width: max(0.01, p.x - r.minX), height: max(0.008, p.y - r.minY))
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
        rig.eyes = rig.eyes.map { $0.offsetBy(dx: dx, dy: dy) }
        rig.mouth = rig.mouth?.offsetBy(dx: dx, dy: dy)
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

// MARK: - 动作与互动

private let triggerTitles: [(key: String, title: String)] = [
    ("click", "点一下"), ("double_click", "双击"), ("hover", "鼠标悬停"), ("commit", "打字上屏"),
    ("idle", "闲着时（随机）"), ("greet", "打招呼"), ("milestone", "字数里程碑"), ("wake", "睡醒"),
    ("drop", "被放下"), ("break", "休息提醒"), ("roam", "溜达"),
]

private let lineTitles: [(key: String, title: String)] = [
    ("click", "被摸头"), ("double_click", "被戳"), ("idle", "闲聊"), ("sleep", "犯困"), ("wake", "睡醒"),
    ("morning", "早上问候"), ("afternoon", "下午问候"), ("evening", "晚上问候"), ("level", "打字很多时"),
]

/// 动作编辑器（关键帧 + 滑杆，改完自动在左边预览）+ 触发器与台词。
private struct ActionsTab: View {
    @ObservedObject var model: WorkshopModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                actionsBar
                if let index = model.selectedActionIndex {
                    ActionEditor(model: model, index: index)
                        .id(model.draft.actions[index].id)
                } else {
                    Text("新建一个动作，或从预置动作复制一份来改。改动会在左边预览里自动播放。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Divider()
                triggersSection
                Divider()
                linesSection
            }
            .padding(20)
        }
    }

    private var actionsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("我的动作").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu("从预置复制") {
                    ForEach(model.copyablePresets, id: \.id) { preset in
                        Button(preset.name) { model.copyPreset(preset.id) }
                    }
                }
                .fixedSize()
                .controlSize(.small)
                Button("新建动作") { model.newAction() }
                    .controlSize(.small)
            }
            if !model.draft.actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.draft.actions) { action in
                            let on = model.selectedAction == action.id
                            Button(action.name) { model.selectedAction = action.id }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .tint(on ? .accentColor : nil)
                        }
                    }
                }
            }
            if !model.draft.extraActions.isEmpty {
                Text("另有 \(model.draft.extraActions.count) 个带波形的动作（来自形象包），保存时原样保留。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("什么时候做什么动作").font(.system(size: 13, weight: .semibold))
            Text("每种时机可以选多个动作，触发时随机挑一个。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(triggerTitles, id: \.key) { trigger in
                HStack(alignment: .firstTextBaseline) {
                    Text(trigger.title)
                        .frame(width: 104, alignment: .leading)
                    let chosen = model.triggerActions(trigger.key)
                    Text(chosen.isEmpty ? "（无）" : chosen.map(model.actionName).joined(separator: "、"))
                        .font(.system(size: 12))
                        .foregroundStyle(model.draft.triggers[trigger.key] == nil ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer()
                    Menu("选择") {
                        ForEach(model.draft.actions) { action in
                            Toggle(action.name, isOn: Binding(
                                get: { model.triggerActions(trigger.key).contains(action.id) },
                                set: { _ in model.toggleTrigger(trigger.key, action: action.id) }
                            ))
                        }
                        if !model.draft.actions.isEmpty { Divider() }
                        ForEach(model.actions, id: \.id) { action in
                            Toggle(action.name, isOn: Binding(
                                get: { model.triggerActions(trigger.key).contains(action.id) },
                                set: { _ in model.toggleTrigger(trigger.key, action: action.id) }
                            ))
                        }
                        if model.draft.triggers[trigger.key] != nil {
                            Divider()
                            Button("恢复默认") { model.resetTrigger(trigger.key) }
                        }
                    }
                    .fixedSize()
                    .controlSize(.small)
                }
            }
        }
    }

    private var linesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("台词").font(.system(size: 13, weight: .semibold))
            Text("多句用 / 分隔，随机说一句；留空用默认台词。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(lineTitles, id: \.key) { line in
                HStack {
                    Text(line.title).frame(width: 104, alignment: .leading)
                    TextField("默认", text: Binding(
                        get: { model.linesText(line.key) },
                        set: { model.setLines(line.key, $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}

/// 单个动作：名字 / 表情 / 特效 / 台词 + 关键帧（每帧一组姿势滑杆）。
private struct ActionEditor: View {
    @ObservedObject var model: WorkshopModel
    let index: Int

    private var action: Binding<PuppetActionDraft> {
        Binding(
            get: { model.draft.actions.indices.contains(index) ? model.draft.actions[index] : PuppetActionDraft(id: "", name: "") },
            set: {
                guard model.draft.actions.indices.contains(index) else { return }
                model.draft.actions[index] = $0
                model.actionEdited()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("动作名", text: action.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Picker("表情", selection: action.image) {
                    Text("不换").tag("")
                    ForEach(PuppetRole.allCases) { role in
                        Text(role.title).tag(role.rawValue)
                    }
                }
                .frame(width: 170)
                Picker("特效", selection: action.effect) {
                    Text("无").tag("")
                    Text("爱心").tag("hearts")
                    Text("光点").tag("sparks")
                }
                .frame(width: 120)
                Spacer()
            }
            HStack {
                TextField("台词（可选，多句用 / 分隔）", text: action.say)
                    .textFieldStyle(.roundedBorder)
                Toggle("结束回到原位", isOn: action.returnToRest)
                    .toggleStyle(.checkbox)
            }
            ForEach(Array(action.wrappedValue.keyframes.enumerated()), id: \.element.id) { k, frame in
                keyframeBox(k, frame)
            }
            HStack {
                Button("＋ 关键帧") { addKeyframe() }
                Button("▶︎ 播放") { model.previewSelectedAction() }
                Spacer()
                Button("删除这个动作", role: .destructive) {
                    model.deleteAction(action.wrappedValue.id)
                }
            }
            .controlSize(.small)
        }
    }

    private func keyframeBox(_ k: Int, _ frame: PuppetKeyframe) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("第 \(k + 1) 帧").font(.system(size: 12, weight: .semibold))
                    Slider(value: keyframeTime(frame.id), in: 0...4, step: 0.05)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.2f 秒", frame.t))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if action.wrappedValue.keyframes.count > 1 {
                        Button {
                            action.wrappedValue.keyframes.removeAll { $0.id == frame.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 2) {
                    ForEach(PuppetChannel.all, id: \.key) { channel in
                        HStack(spacing: 6) {
                            Text(channel.title)
                                .font(.system(size: 11))
                                .frame(width: 92, alignment: .leading)
                            Slider(value: channelValue(frame.id, channel), in: channel.range)
                                .controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    private func keyframeTime(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { action.wrappedValue.keyframes.first { $0.id == id }?.t ?? 0 },
            set: { value in
                if let i = action.wrappedValue.keyframes.firstIndex(where: { $0.id == id }) {
                    action.wrappedValue.keyframes[i].t = value
                }
            }
        )
    }

    private func channelValue(_ id: UUID, _ channel: PuppetChannel) -> Binding<Double> {
        Binding(
            get: { action.wrappedValue.keyframes.first { $0.id == id }?.values[channel.key] ?? 0 },
            set: { value in
                if let i = action.wrappedValue.keyframes.firstIndex(where: { $0.id == id }) {
                    // 靠近 0 时吸附到 0，方便回到原位
                    action.wrappedValue.keyframes[i].values[channel.key] =
                        abs(value) < (channel.range.upperBound - channel.range.lowerBound) * 0.02 ? 0 : value
                }
            }
        )
    }

    private func addKeyframe() {
        var frames = action.wrappedValue.keyframes
        let last = frames.max { $0.t < $1.t }
        var next = PuppetKeyframe(t: min(4, (last?.t ?? 0) + 0.3))
        next.values = last?.values ?? [:]
        frames.append(next)
        action.wrappedValue.keyframes = frames
    }
}
