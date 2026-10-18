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

    /// 加图片。`role` 非空 = 拖到某个格子上：第一张放进这个格子（替换原图），其余按顺序补空格子。
    func add(_ urls: [URL], role: PuppetRole? = nil) {
        let images = urls.filter { ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif", "bmp"].contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty, !busy else { return }
        var target = role
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
                        let slot: PuppetRole?
                        if let t = target {
                            slot = t
                            target = nil
                            self.draft.images.removeAll { $0.role == t }   // 拖到已有图片的格子 = 替换
                        } else {
                            slot = self.nextRole(hint: name)
                        }
                        guard let role = slot else {
                            skipped += 1
                            continue
                        }
                        image.role = role
                        self.manuallyAligned.remove(image.id)
                        self.draft.images.append(image)
                        self.selected = image.id
                    }
                    self.realign()
                    let warn = self.draft.images.compactMap { self.mismatch(of: $0) }.first
                    self.status = skipped > 0
                        ? "已添加；\(skipped) 张没有空位（每种表情一张，可删掉旧的再加）"
                        : (warn != nil ? "已添加。有图片和「平时」差别较大，看格子上的 ⚠️ 提示" : "已添加并自动对齐。可以继续往格子里补图。")
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
        let wasIdle = draft.images.first { $0.id == id }?.role == .idle
        draft.images.removeAll { $0.id == id }
        if !draft.images.contains(where: { $0.role == .idle }), !draft.images.isEmpty {
            draft.images[0].role = .idle
        }
        if wasIdle { realign() }
        if selected == id { selected = draft.images.first?.id }
        refreshPreview(immediately: true)
    }

    func image(for role: PuppetRole) -> PuppetImage? {
        draft.images.first { $0.role == role }
    }

    // MARK: 对齐（表情图 ↔ 平时图）

    /// 手动调过对齐的图：自动对齐不再覆盖它
    var manuallyAligned: Set<UUID> = []

    /// 所有表情图重新对齐到「平时」图（换了平时图、加了新图时调用）。
    func realign() {
        guard let idle = image(for: .idle) else { return }
        for i in draft.images.indices where draft.images[i].role != .idle {
            if manuallyAligned.contains(draft.images[i].id) { continue }
            draft.images[i].align = PuppetImage.autoAlign(draft.images[i], to: idle)
        }
        if let i = draft.images.firstIndex(where: { $0.role == .idle }) { draft.images[i].align = .identity }
    }

    func mismatch(of image: PuppetImage) -> String? {
        guard image.role != .idle, let idle = self.image(for: .idle) else { return nil }
        return PuppetImage.mismatch(image, idle: idle)
    }

    func setAlign(_ align: PuppetAlign, final: Bool) {
        guard let index = selectedIndex, draft.images[index].role != .idle else { return }
        draft.images[index].align = align
        manuallyAligned.insert(draft.images[index].id)
        if final { refreshPreview(immediately: false) }
    }

    func autoAlignSelected() {
        guard let index = selectedIndex, let idle = image(for: .idle) else { return }
        manuallyAligned.remove(draft.images[index].id)
        draft.images[index].align = PuppetImage.autoAlign(draft.images[index], to: idle)
        refreshPreview(immediately: true)
    }

    // MARK: 提示词

    /// 角色描述（拼进每个格子的生成提示词）
    @Published var characterDesc = ""

    func prompt(for role: PuppetRole) -> String {
        let who = characterDesc.trimmingCharacters(in: .whitespaces).isEmpty
            ? "【在这里描述你的角色：性别/年龄感、发型发色、服装、配饰、画风】"
            : characterDesc.trimmingCharacters(in: .whitespaces)
        let ref = role == .idle ? "" : "以我上传的「平时」图为参考，保持同一个角色、同样的服装发型、同样的构图大小和站位。"
        return "桌宠立绘：\(who)。全身、正面、居中、单人、纯白或纯色背景、无文字无水印。\(ref)这一张：\(role.promptPhrase)。"
    }

    var fullPrompt: String {
        var lines = ["同一个角色的一组桌宠立绘，每张单独输出，构图、大小、站位、服装发型完全一致，只改变表情和手势：",
                     "角色：" + (characterDesc.isEmpty ? "【在这里描述你的角色】" : characterDesc),
                     "统一要求：全身、正面、居中、单人、纯白或纯色背景、无文字无水印。"]
        for (i, role) in PuppetRole.allCases.enumerated() {
            lines.append("\(i + 1). \(role.shortTitle)（文件名 \(role.rawValue)）：\(role.promptPhrase)")
        }
        return lines.joined(separator: "\n")
    }

    /// 改表情：目标表情已被占用就和它互换。
    func setRole(_ role: PuppetRole, for id: UUID) {
        guard let index = draft.images.firstIndex(where: { $0.id == id }) else { return }
        let old = draft.images[index].role
        if let other = draft.images.firstIndex(where: { $0.role == role && $0.id != id }) {
            draft.images[other].role = old
        }
        draft.images[index].role = role
        if role == .idle || old == .idle { realign() }
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

    /// 发布到松萝社区（nownexts.com，审核制）：导出到「下载」并打开发布页，由用户在网页上传。
    /// 松萝里不保存社区账号，上传、登录都在浏览器里完成。
    func publishToCommunity() {
        guard draft.shareable else {
            status = "发布到松萝社区需要原创或已获授权：确认后勾选「这些图片是我原创或已获授权」"
            return
        }
        guard let id = save() else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = draft.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = downloads.appendingPathComponent("\(safeName.isEmpty ? id : safeName).\(PuppetPackStore.fileExtension)")
        do {
            try PuppetPackStore.export(packId: id, to: file)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            NSWorkspace.shared.open(PetCommunity.publishPage)
            status = "已导出到「下载」：在打开的网页里上传（需认证开发者），审核通过后上架"
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

struct WorkshopView: View {
    @ObservedObject var model: WorkshopModel

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
                Button("发布到松萝社区…") { model.publishToCommunity() }
                    .disabled(model.draft.images.isEmpty || !model.draft.shareable)
                    .help("需勾选「这些图片是我原创或已获授权」；在 nownexts.com 上传并审核")
                Button("保存并使用") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.draft.images.contains { $0.role == .idle } || model.busy)
            }
            .padding(12)
        }
    }

    /// 按格子上传：每种表情一个格子，空格子显示示意图（姿势 + 表情 + 构图），照着找图或生成。
    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("图片与表情").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.draft.images.isEmpty {
                    Button("重新开始") { model.startOver() }.controlSize(.small)
                }
                Button("批量添加…") { pickImages(role: nil) }
                    .controlSize(.small)
                    .disabled(model.busy)
                    .help("一次选多张：文件名带 happy / sleep / blink 等会自动放进对应格子")
            }
            guideBox
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 12) {
                ForEach(PuppetRole.allCases) { role in
                    RoleSlot(model: model, role: role, pick: { pickImages(role: role) })
                }
            }
        }
    }

    /// 一套图要「像同一次拍的」：示意图里人物的位置和大小都一样，照片也要这样。
    private var guideBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 3) {
                    Text("让一套图「像同一次拍的」，切换表情才不会跳").font(.system(size: 12, weight: .semibold))
                    Text("① 同一个人 / 角色，同样的衣服发型　② 同样的距离和构图（都全身或都半身），人物在画面里的位置和大小一致　③ 正面、居中、背景简单　④ 只改变表情和手势。\n示意图里小人的位置和大小在每个格子都一样——照着它找图、拍照或生成。连拍、同一次 AI 生成的一组图效果最好。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                TextField("用 AI 生成时，先描述你的角色（发型、衣服、画风…）", text: $model.characterDesc)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("复制整套提示词") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.fullPrompt, forType: .string)
                    model.status = "整套提示词已复制：先生成「平时」，再拿它当参考图生成其他表情，一致性最好"
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.08)))
    }

    private func rigSection(_ index: Int) -> some View {
        let image = model.draft.images[index]
        return VStack(alignment: .leading, spacing: 8) {
            if image.role != .idle, let idle = model.image(for: .idle) {
                Text("和「平时」对齐：\(image.role.shortTitle)").font(.system(size: 13, weight: .semibold))
                Text("半透明的是「平时」图。拖滑杆让两张重合（尤其是脸），切换表情时就不会跳。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let warn = model.mismatch(of: image) {
                    Label(warn, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                AlignEditor(idle: idle, image: image, align: image.align,
                            onChange: { model.setAlign($0, final: $1) },
                            onAuto: { model.autoAlignSelected() })
                    .id("\(image.id)-\(image.align.scale)-\(model.manuallyAligned.contains(image.id))")
                Divider().padding(.vertical, 4)
            }
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
            Toggle("这些图片是我原创或已获授权", isOn: $model.draft.shareable)
            Text("自己用、导出发给朋友都不受限制。发布到松萝社区（nownexts.com）只收原创或已获授权的形象，并且需要审核。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickImages(role: PuppetRole?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = role == nil
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择 1 张或多张图片（全身、单人、背景简单效果最好）"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls, role: role)
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
    ("love", "连着摸头（心动）"), ("angry", "被连戳（生气）"), ("lonely", "被冷落"), ("welcome", "你回来时"),
    ("comfort", "删字很多时（安慰）"), ("dizzy", "被鼠标晃晕"), ("shy", "一直盯着它"), ("night", "深夜还在打字"),
]

private let lineTitles: [(key: String, title: String)] = [
    ("click", "被摸头"), ("double_click", "被戳"), ("idle", "闲聊"), ("sleep", "犯困"), ("wake", "睡醒"),
    ("morning", "早上问候"), ("afternoon", "下午问候"), ("evening", "晚上问候"), ("level", "打字很多时"),
    ("love", "心动"), ("angry", "生气"), ("lonely", "被冷落"), ("welcome", "欢迎回来"),
    ("comfort", "安慰你"), ("dizzy", "晕了"), ("shy", "害羞"), ("night", "深夜提醒"),
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

// MARK: - 表情格子 + 示意图 + 对齐

/// 拖进来的文件 → URL（按文件名排序，方便一组图按 1、2、3 顺序进格子）
private func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
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
        completion(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }
}

/// 一个表情格子：空的时候显示示意图和要点，有图时显示图片（和平时差别大时打 ⚠️）。
private struct RoleSlot: View {
    @ObservedObject var model: WorkshopModel
    let role: PuppetRole
    let pick: () -> Void
    @State private var targeted = false

    var body: some View {
        let image = model.image(for: role)
        let isSelected = image != nil && model.selected == image?.id
        let warn = image.flatMap { model.mismatch(of: $0) }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(role.shortTitle).font(.system(size: 12, weight: .semibold))
                Text(role.tier.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(tierColor.opacity(0.15)))
                    .foregroundStyle(tierColor)
                Spacer()
                if role == .blink || role == .talk, image == nil {
                    Text("可自动生成").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("没有这张图时，会按「平时」图的眼睛 / 嘴巴位置自动生成")
                }
            }
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image, let ns = NSImage(data: image.png) {
                        Image(nsImage: ns).resizable().aspectRatio(contentMode: .fit).padding(4)
                    } else {
                        RoleSketch(role: role).padding(6)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(
                    Group {
                        if image != nil { CheckerBackground() } else { Color.secondary.opacity(0.05) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            targeted || isSelected ? Color.accentColor : Color.secondary.opacity(image == nil ? 0.35 : 0.25),
                            style: StrokeStyle(lineWidth: targeted || isSelected ? 2 : 1, dash: image == nil ? [5] : [])
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture { if let image { model.selected = image.id } else { pick() } }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    loadDroppedURLs(providers) { model.add($0, role: role) }
                    return true
                }
                if let image {
                    HStack(spacing: 2) {
                        if let warn {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(warn)
                        }
                        Button { model.remove(image.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(5)
                }
            }
            Text(image == nil ? role.hint : role.usage)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 40, alignment: .top)
            HStack(spacing: 4) {
                Button(image == nil ? "选择…" : "替换…", action: pick)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.prompt(for: role), forType: .string)
                    model.status = "「\(role.shortTitle)」的提示词已复制" + (role == .idle ? "" : "（生成时把「平时」图一起作为参考图）")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制这张图的 AI 生成提示词")
            }
            .controlSize(.small)
        }
    }

    private var tierColor: Color {
        switch role.tier {
        case .required: return .red
        case .recommended: return .orange
        case .optional: return .secondary
        }
    }
}

/// 表情示意图：同一个位置和大小的小人，只换表情和手势（提示「一套图要构图一致」）。
struct RoleSketch: View {
    let role: PuppetRole

    var body: some View {
        Canvas { ctx, size in
            // 100 × 130 的设计稿等比放进格子
            let k = min(size.width / 100, size.height / 130)
            let ox = (size.width - 100 * k) / 2, oy = (size.height - 130 * k) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
            let ink = GraphicsContext.Shading.color(.primary.opacity(0.7))
            let soft = GraphicsContext.Shading.color(.secondary.opacity(0.35))
            let line = StrokeStyle(lineWidth: 2 * k, lineCap: .round, lineJoin: .round)
            func stroke(_ pts: [CGPoint], _ shading: GraphicsContext.Shading = ink) {
                var path = Path()
                path.addLines(pts)
                ctx.stroke(path, with: shading, style: line)
            }
            func arc(_ c: CGPoint, _ r: CGFloat, _ a0: Double, _ a1: Double) {
                var path = Path()
                path.addArc(center: c, radius: r * k, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
                ctx.stroke(path, with: ink, style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round))
            }
            func text(_ s: String, _ at: CGPoint, _ size: CGFloat, _ color: Color = .primary.opacity(0.7)) {
                ctx.draw(Text(s).font(.system(size: size * k)).foregroundColor(color), at: at)
            }

            // 构图参考：取景框 + 地面线（每个格子都一样）
            var frame = Path(roundedRect: CGRect(origin: p(10, 4), size: CGSize(width: 80 * k, height: 120 * k)), cornerRadius: 4 * k)
            ctx.stroke(frame, with: soft, style: StrokeStyle(lineWidth: 1 * k, dash: [3 * k, 3 * k]))
            frame = Path()
            stroke([p(18, 122), p(82, 122)], soft)

            // 姿态：头的位置 / 身体倾斜 / 手臂
            var head = CGPoint(x: 50, y: 34)
            var lean: CGFloat = 0
            switch role {
            case .sleep: head = CGPoint(x: 55, y: 37)
            case .typing, .sad: head = CGPoint(x: 50, y: 37)
            case .tired: head = CGPoint(x: 52, y: 39); lean = 4
            case .listen: head = CGPoint(x: 47, y: 36)
            default: break
            }
            let neck = p(50 + lean / 2, 54), hip = p(50, 92)
            // 身体
            var body = Path()
            body.addRoundedRect(in: CGRect(x: ox + (37 + lean / 2) * k, y: oy + 54 * k, width: 26 * k, height: 40 * k), cornerSize: CGSize(width: 9 * k, height: 9 * k))
            ctx.stroke(body, with: ink, style: line)
            _ = neck; _ = hip
            // 腿
            stroke([p(44, 94), p(43, 120)])
            stroke([p(56, 94), p(57, 120)])
            // 手臂（左肩 39,60 / 右肩 61,60）
            switch role {
            case .happy:
                stroke([p(39, 60), p(27, 48), p(24, 38)]); stroke([p(61, 60), p(73, 48), p(76, 38)])
            case .surprised:
                stroke([p(39, 60), p(24, 56), p(18, 46)]); stroke([p(61, 60), p(76, 56), p(82, 46)])
            case .typing:
                stroke([p(39, 62), p(36, 76), p(44, 80)]); stroke([p(61, 62), p(64, 76), p(56, 80)])
                var laptop = Path(roundedRect: CGRect(origin: p(32, 80), size: CGSize(width: 36 * k, height: 5 * k)), cornerRadius: 1.5 * k)
                ctx.fill(laptop, with: soft)
                laptop = Path()
            case .shy:
                stroke([p(39, 60), p(34, 50), p(40, 42)]); stroke([p(61, 60), p(66, 50), p(60, 42)])
            case .angry:
                stroke([p(39, 60), p(28, 70), p(38, 80)]); stroke([p(61, 60), p(72, 70), p(62, 80)])
            case .love:
                stroke([p(39, 60), p(42, 70), p(48, 66)]); stroke([p(61, 60), p(58, 70), p(52, 66)])
                text("♥", p(50, 64), 9, .pink)
            case .sleep:
                stroke([p(39, 60), p(36, 76), p(38, 88)]); stroke([p(61, 60), p(64, 50), p(60, 42)])
            case .covereyes:
                stroke([p(39, 60), p(33, 46), p(44, 34)]); stroke([p(61, 60), p(67, 46), p(56, 34)])
            case .listen:
                stroke([p(39, 60), p(32, 76), p(31, 88)]); stroke([p(61, 60), p(74, 46), p(70, 33)])
            case .tired:
                stroke([p(41, 60), p(36, 80), p(37, 92)]); stroke([p(63, 60), p(68, 80), p(67, 92)])
            default:
                stroke([p(39, 60), p(32, 76), p(31, 88)]); stroke([p(61, 60), p(68, 76), p(69, 88)])
            }
            // 头
            let hc = p(head.x, head.y)
            ctx.stroke(Path(ellipseIn: CGRect(x: hc.x - 18 * k, y: hc.y - 18 * k, width: 36 * k, height: 36 * k)), with: ink, style: line)
            let le = p(head.x - 7, head.y - 1), re = p(head.x + 7, head.y - 1), mouth = p(head.x, head.y + 8)
            // 眼睛
            func dot(_ c: CGPoint, _ r: CGFloat) {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: 2 * r * k)), with: ink)
            }
            switch role {
            case .blink, .sleep:
                arc(le, 3.2, 20, 160); arc(re, 3.2, 20, 160)
            case .covereyes:
                for c in [le, re] {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6 * k, y: c.y - 4.5 * k, width: 12 * k, height: 9 * k)), with: soft)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6 * k, y: c.y - 4.5 * k, width: 12 * k, height: 9 * k)), with: ink, style: StrokeStyle(lineWidth: 1.4 * k))
                }
            case .happy, .love:
                arc(CGPoint(x: le.x, y: le.y + 2 * k), 3.2, 200, 340); arc(CGPoint(x: re.x, y: re.y + 2 * k), 3.2, 200, 340)
                if role == .love { text("♥", CGPoint(x: le.x, y: le.y - 6 * k), 6, .pink); text("♥", CGPoint(x: re.x, y: re.y - 6 * k), 6, .pink) }
            case .surprised:
                ctx.stroke(Path(ellipseIn: CGRect(x: le.x - 3 * k, y: le.y - 3 * k, width: 6 * k, height: 6 * k)), with: ink, style: StrokeStyle(lineWidth: 1.5 * k))
                ctx.stroke(Path(ellipseIn: CGRect(x: re.x - 3 * k, y: re.y - 3 * k, width: 6 * k, height: 6 * k)), with: ink, style: StrokeStyle(lineWidth: 1.5 * k))
            case .tired:
                dot(CGPoint(x: le.x, y: le.y + 1 * k), 1.6); dot(CGPoint(x: re.x, y: re.y + 1 * k), 1.6)
                stroke([CGPoint(x: le.x - 3.5 * k, y: le.y), CGPoint(x: le.x + 3.5 * k, y: le.y)])
                stroke([CGPoint(x: re.x - 3.5 * k, y: re.y), CGPoint(x: re.x + 3.5 * k, y: re.y)])
            default:
                dot(le, 2); dot(re, 2)
            }
            // 眉毛
            switch role {
            case .angry:
                stroke([CGPoint(x: le.x - 4 * k, y: le.y - 6 * k), CGPoint(x: le.x + 3 * k, y: le.y - 4 * k)])
                stroke([CGPoint(x: re.x + 4 * k, y: re.y - 6 * k), CGPoint(x: re.x - 3 * k, y: re.y - 4 * k)])
            case .sad:
                stroke([CGPoint(x: le.x - 3 * k, y: le.y - 4 * k), CGPoint(x: le.x + 3 * k, y: le.y - 6.5 * k)])
                stroke([CGPoint(x: re.x + 3 * k, y: re.y - 4 * k), CGPoint(x: re.x - 3 * k, y: re.y - 6.5 * k)])
            default: break
            }
            // 嘴
            switch role {
            case .talk, .surprised:
                ctx.stroke(Path(ellipseIn: CGRect(x: mouth.x - 3 * k, y: mouth.y - 2.5 * k, width: 6 * k, height: 5 * k)), with: ink, style: StrokeStyle(lineWidth: 1.5 * k))
            case .happy, .love:
                var m = Path()
                m.move(to: CGPoint(x: mouth.x - 5 * k, y: mouth.y - 1.5 * k))
                m.addQuadCurve(to: CGPoint(x: mouth.x + 5 * k, y: mouth.y - 1.5 * k), control: CGPoint(x: mouth.x, y: mouth.y + 6 * k))
                m.closeSubpath()
                ctx.fill(m, with: soft); ctx.stroke(m, with: ink, style: StrokeStyle(lineWidth: 1.4 * k))
            case .sad:
                arc(CGPoint(x: mouth.x, y: mouth.y + 4 * k), 4, 210, 330)
            case .angry:
                stroke([CGPoint(x: mouth.x - 4 * k, y: mouth.y + 1 * k), CGPoint(x: mouth.x - 1.5 * k, y: mouth.y - 0.5 * k),
                        CGPoint(x: mouth.x + 1.5 * k, y: mouth.y + 1 * k), CGPoint(x: mouth.x + 4 * k, y: mouth.y - 0.5 * k)])
            case .typing, .sleep:
                stroke([CGPoint(x: mouth.x - 3 * k, y: mouth.y), CGPoint(x: mouth.x + 3 * k, y: mouth.y)])
            case .tired:
                ctx.stroke(Path(ellipseIn: CGRect(x: mouth.x - 2.5 * k, y: mouth.y - 3 * k, width: 5 * k, height: 7 * k)), with: ink, style: StrokeStyle(lineWidth: 1.4 * k))
            case .shy:
                stroke([CGPoint(x: mouth.x - 3 * k, y: mouth.y), CGPoint(x: mouth.x - 1 * k, y: mouth.y + 1.5 * k),
                        CGPoint(x: mouth.x + 1 * k, y: mouth.y), CGPoint(x: mouth.x + 3 * k, y: mouth.y + 1.5 * k)])
            default:
                arc(CGPoint(x: mouth.x, y: mouth.y - 3 * k), 4.5, 30, 150)
            }
            // 腮红
            if role == .shy || role == .love {
                for c in [CGPoint(x: le.x - 3 * k, y: le.y + 6 * k), CGPoint(x: re.x + 3 * k, y: re.y + 6 * k)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5 * k, y: c.y - 2 * k, width: 7 * k, height: 4 * k)), with: .color(.pink.opacity(0.55)))
                }
            }
            // 情绪符号
            switch role {
            case .sleep: text("z Z", p(78, 14), 9)
            case .covereyes: text("🙈", p(76, 14), 10)
            case .listen:
                arc(CGPoint(x: hc.x + 22 * k, y: hc.y - 4 * k), 4, -60, 60)
                arc(CGPoint(x: hc.x + 22 * k, y: hc.y - 4 * k), 8, -60, 60)
            case .surprised: text("!", p(76, 14), 13)
            case .angry: text("💢", p(74, 16), 10)
            case .sad, .tired: text("💧", p(73, 24), 8)
            case .love: text("♥", p(76, 14), 11, .pink)
            default: break
            }
        }
    }
}

/// 对齐编辑：半透明「平时」图 + 当前表情图叠在一起，滑杆调缩放 / 位置。
private struct AlignEditor: View {
    let idle: PuppetImage
    let image: PuppetImage
    @State var align: PuppetAlign
    let onChange: (PuppetAlign, Bool) -> Void
    let onAuto: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GeometryReader { geo in
                // 与渲染器同一套坐标：平时图高 h、底边对齐脚底线、水平居中
                let h = geo.size.height * 0.86
                let ground = geo.size.height * 0.96
                ZStack(alignment: .topLeading) {
                    if let ns = NSImage(data: idle.png) {
                        Image(nsImage: ns).resizable()
                            .frame(width: h * idle.aspect, height: h)
                            .position(x: geo.size.width / 2, y: ground - h / 2)
                            .opacity(0.35)
                    }
                    if let ns = NSImage(data: image.png) {
                        let ih = h * align.scale
                        Image(nsImage: ns).resizable()
                            .frame(width: ih * image.aspect, height: ih)
                            .position(x: geo.size.width / 2 + align.dx * h, y: ground - ih / 2 - align.dy * h)
                            .opacity(0.75)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .frame(width: 190, height: 230)
            .background(CheckerBackground().clipShape(RoundedRectangle(cornerRadius: 10)))
            VStack(alignment: .leading, spacing: 8) {
                slider("大小", value: $align.scale, range: 0.4...2.5)
                slider("左右", value: $align.dx, range: -0.6...0.6)
                slider("上下", value: $align.dy, range: -0.6...0.6)
                HStack {
                    Button("自动对齐", action: onAuto)
                    Button("不对齐") {
                        align = .identity
                        onChange(align, true)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 30, alignment: .leading)
            Slider(value: value, in: range) { editing in
                onChange(align, !editing)
            }
            .onChange(of: value.wrappedValue) { _ in onChange(align, false) }
        }
    }
}

/// 开发用：把 12 张表情示意图渲染成一张 PNG（`--pet-sketches`）。
@MainActor
func renderRoleSketches(to path: String) {
    let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(130)), count: 6), spacing: 8) {
        ForEach(PuppetRole.allCases) { role in
            VStack(spacing: 2) {
                RoleSketch(role: role).frame(width: 120, height: 150)
                Text(role.shortTitle).font(.system(size: 12))
            }
        }
    }
    .padding(12)
    .background(Color.white)
    .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: grid)
    renderer.scale = 2
    if let image = renderer.cgImage,
       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
