import AppKit
import SwiftUI

struct PetStudioView: View {
    @ObservedObject var model: WorkshopModel
    @State private var config = PetStudioConfig.load()
    @State private var key = ""
    @State private var prompt = "点击时开心地弹跳两下；写代码时轻轻点头；动作自然，不要抖动。"
    @State private var result = ""
    @State private var running = false
    @State private var message = ""
    @State private var source: URL?
    @State private var job: URL?
    @State private var consent = false
    @State private var edge = 0.25
    @State private var whiteMatte = false
    @State private var previewBackground = 0
    @State private var props = PetWindowController.scenePropsEnabled
    @State private var originalImages: [UUID: Data] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("本地定制工作台").font(.title3.weight(.semibold))
                Text("一张透明图就能呼吸、歪头、弹跳和跟随视线。复杂的换装、转身与场景姿势再按需制作素材。")
                    .font(.callout).foregroundStyle(.secondary)
                motionSection
                edgeSection
                providerSection
                toolSection
                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(20)
        }
        .onAppear { key = PetStudioSecret.get(config.provider) }
    }

    private var motionSection: some View {
        GroupBox("一张图，快速调动作") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ForEach(["安静陪伴", "自然灵动", "活泼弹跳"], id: \.self) { name in
                        Button(name) {
                            model.draft.motion.intensity = name == "安静陪伴" ? 0.4 : (name == "自然灵动" ? 1 : 1.6)
                            model.draft.motion.speed = name == "活泼弹跳" ? 1.3 : 0.85
                            model.refreshPreview(immediately: false)
                        }.controlSize(.small)
                    }
                }
                motionSlider("动作幅度", value: $model.draft.motion.intensity, range: 0...2)
                motionSlider("动作速度", value: $model.draft.motion.speed, range: 0.25...2)
                motionSlider("视线跟随", value: $model.draft.motion.gaze, range: 0...2)
                Toggle("减少动态效果", isOn: $model.draft.motion.reduced)
                    .onChange(of: model.draft.motion.reduced) { _ in model.refreshPreview(immediately: false) }
                Toggle("显示装饰场景道具（影响当前桌宠）", isOn: $props)
                    .onChange(of: props) { PetWindowController.scenePropsEnabled = $0 }
                Text("关闭装饰道具后，场景互动和角色自己的姿势仍然可用。幅度与速度会随形象包保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private func motionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { model.refreshPreview(immediately: false) }
            }).accessibilityLabel(title)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 38)
        }
    }

    private var edgeSection: some View {
        GroupBox("检查并修整透明边缘") {
            VStack(alignment: .leading, spacing: 10) {
                if let index = model.selectedIndex, let image = NSImage(data: model.draft.images[index].png) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 120).frame(maxWidth: .infinity)
                        .background(previewBackground == 0 ? Color.white : previewBackground == 1 ? Color.black : Color(red: 0.3, green: 0.5, blue: 0.4))
                } else { Text("先在「形象」中选中要修整的图片。 ").foregroundStyle(.secondary) }
                Picker("预览底色", selection: $previewBackground) {
                    Text("白色").tag(0); Text("黑色").tag(1); Text("绿色").tag(2)
                }.pickerStyle(.segmented)
                HStack { Text("收边"); Slider(value: $edge, in: 0...1).accessibilityLabel("收边强度") }
                Toggle("去除白色背景残留（白边素材适用）", isOn: $whiteMatte)
                HStack {
                    Button("应用到选中图片") { cleanEdge() }.disabled(model.selectedIndex == nil || model.busy)
                    Button("恢复本次修整前") {
                        guard let i = model.selectedIndex, let png = originalImages[model.draft.images[i].id] else { return }
                        model.draft.images[i].png = png
                        model.refreshPreview(immediately: false)
                    }.disabled(model.selected.flatMap { originalImages[$0] } == nil)
                }
                Text("每次从本次会话的原图计算，避免反复收缩；头发和绒毛建议低强度。切换黑白底检查后再保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var providerSection: some View {
        GroupBox("用文字设计动作") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("制作服务", selection: $config.provider) {
                    Text("MiniMax").tag("minimax")
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI 兼容 / 本地服务").tag("compatible")
                    Text("Codex CLI").tag("codex")
                }.onChange(of: config.provider) { provider in
                    config.baseURL = provider == "anthropic" ? "https://api.anthropic.com/v1" : provider == "minimax" ? "https://api.minimax.io/v1" : "http://127.0.0.1:1234/v1"
                    config.model = ""
                    key = PetStudioSecret.get(provider)
                    consent = false
                }
                TextField("模型 ID（填写服务控制台中的实际名称）", text: $config.model).textFieldStyle(.roundedBorder)
                if config.provider == "codex" {
                    TextField("Codex 可执行文件的绝对路径", text: $config.codexExecutable).textFieldStyle(.roundedBorder)
                    Text("使用本机 Codex 的登录与模型配置，只读方式生成动作 JSON。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("API 基础地址，包含 /v1", text: $config.baseURL).textFieldStyle(.roundedBorder)
                    SecureField("API Key（保存到系统钥匙串，本机服务可留空）", text: $key).textFieldStyle(.roundedBorder)
                }
                TextEditor(text: $prompt).font(.body).frame(height: 70).border(Color.secondary.opacity(0.25))
                    .accessibilityLabel("动作描述")
                Toggle("发送这段制作描述给所选服务（可能产生费用）", isOn: $consent)
                Text("只发送制作描述和动作格式，输入法按键、聊天、参考图都不随此请求发送。图像生成仍在「形象 → AI 补全表情」。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存连接设置") { saveConfig(); message = "连接设置已保存" }
                    Button(running ? "制作中…" : "生成动作草稿") { generate() }
                        .disabled(running || !consent || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if running { ProgressView().controlSize(.small) }
                }
                TextEditor(text: $result).font(.system(.caption, design: .monospaced)).frame(height: 130)
                    .border(Color.secondary.opacity(0.25)).accessibilityLabel("动作 JSON 草稿")
                HStack {
                    Button("导入动作 JSON…") { importJSON() }
                    Button("校验并加入草稿") { applyPlan() }.disabled(result.isEmpty || running)
                }
                Text("结果先校验通道、时长、数值与触发器；加入后在左侧试动作，满意再「保存并使用」。可以直接粘贴其他工具生成的 JSON。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.disabled(model.busy)
    }

    private var toolSection: some View {
        GroupBox("连接本机图像、视频与 3D 工具") {
            VStack(alignment: .leading, spacing: 10) {
                Text("为 Blender、FFmpeg、ComfyUI 或自己的脚本配置任务入口。描述、参考图、输出目录通过任务文件交接。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("视频拆帧模板") { toolTemplate("ffmpeg_frames.py", blender: false) }
                    Button("Blender 透明渲染模板") { toolTemplate("blender_views.py", blender: true) }
                }
                HStack {
                    Button("选择视频 / 3D 工程…") {
                        let panel = NSOpenPanel()
                        if panel.runModal() == .OK { source = panel.url }
                    }
                    Text(source?.lastPathComponent ?? "可选：转换已有视频或 Blender 工程")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                TextField("工具可执行文件的绝对路径", text: $config.executable).textFieldStyle(.roundedBorder)
                TextField("参数 JSON 数组，例如 [\"--background\",\"--python\",\"/路径/制作.py\",\"--\",\"{job}\"]", text: $config.arguments)
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                Text("{job} = 任务 JSON，{dir} = 任务目录，{output} = 输出目录。参数直接传入程序。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("导出制作任务") { exportJob() }
                    Button("运行配置的工具") { runTool() }.disabled(running || config.executable.isEmpty)
                    Button("导入成品…") { importOutput() }
                }
                if let job {
                    Button("在 Finder 打开最近任务") { NSWorkspace.shared.open(job) }
                }
                Text("支持将图片导入当前草稿，将 .lianapet 导入工坊，将 VRM 导入形象库。视频和 GLB 先用工具转换；这里不会把它们当成可直接播放的桌宠。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.disabled(model.busy)
    }

    private func toolTemplate(_ script: String, blender: Bool) {
        guard let resource = Bundle.main.resourceURL else { return }
        let path = resource.appendingPathComponent("PetTools/" + script).path
        config.executable = blender ? "/Applications/Blender.app/Contents/MacOS/Blender" : "/usr/bin/python3"
        let args = blender ? ["--background", "--disable-autoexec", "--python", path, "--", "{job}"]
            : [path, "{job}", "--ffmpeg", "/opt/homebrew/bin/ffmpeg"]
        if let data = try? JSONSerialization.data(withJSONObject: args), let text = String(data: data, encoding: .utf8) {
            config.arguments = text
        }
        message = blender ? "模板已填入。选择有摄像机和动作的 .blend 工程；若 Blender 装在别处请修改路径。"
            : "模板已填入。选择视频；Intel Mac 或自定义安装请把参数里的 FFmpeg 路径改为实际位置。"
    }

    private func saveConfig() {
        config.save()
        PetStudioSecret.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: config.provider)
    }
    private func makeJob(includeReferences: Bool = true) throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Liana/PetStudio/Jobs/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("output"), withIntermediateDirectories: true)
        for image in (includeReferences ? model.draft.images : []) {
            try image.png.write(to: dir.appendingPathComponent(image.role.rawValue + ".png"))
        }
        var task: [String: Any] = ["format": 1, "prompt": prompt, "name": model.draft.name,
            "reference_images": (includeReferences ? model.draft.images : []).map { $0.role.rawValue + ".png" },
            "output": "output", "accepted_output": ["png", "lianapet", "vrm"], "motion_format": PetStudioPlan.instructions]
        if includeReferences, let source { task["source"] = source.path }
        try JSONSerialization.data(withJSONObject: task, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("job.json"), options: .atomic)
        job = dir
        return dir
    }
    private func exportJob() {
        do { let dir = try makeJob(); NSWorkspace.shared.open(dir); message = "任务已导出，包含本地参考图与制作描述。" }
        catch { message = error.localizedDescription }
    }
    private func generate() {
        do {
            saveConfig()
            let dir = try makeJob(includeReferences: false)
            running = true; message = "正在生成动作；结果会先停留在草稿。"
            PetStudioService.generate(prompt: prompt, config: config, key: key, directory: dir) { response in
                DispatchQueue.main.async {
                    running = false
                    switch response {
                    case .success(let text):
                        result = text
                        do { _ = try PetStudioPlan.validate(text); message = "动作格式有效，可以加入草稿并预览。" }
                        catch { message = error.localizedDescription }
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            }
        } catch { message = error.localizedDescription }
    }
    private func applyPlan() {
        do {
            let plan = try PetStudioPlan.validate(result)
            let actions = plan["actions"] as? [String: [String: Any]] ?? [:]
            for (id, json) in actions {
                guard let action = PuppetActionDraft(id: id, json: json) else { continue }
                model.draft.actions.removeAll { $0.id == id }
                model.draft.extraActions.removeValue(forKey: id)
                model.draft.actions.append(action)
            }
            for (key, ids) in plan["triggers"] as? [String: [String]] ?? [:] { model.draft.triggers[key] = ids }
            for (key, lines) in plan["lines"] as? [String: [String]] ?? [:] { model.draft.lines[key] = lines }
            model.selectedAction = actions.keys.sorted().first
            model.refreshPreview(immediately: true)
            message = "已加入 \(actions.count) 个动作。左侧可试播，在「动作与互动」里可继续调关键帧。"
        } catch { message = error.localizedDescription }
    }
    private func importJSON() {
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["json"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { result = try String(contentsOf: url, encoding: .utf8); message = "已读取，请校验并加入草稿。" }
        catch { message = error.localizedDescription }
    }
    private func runTool() {
        do {
            guard let data = config.arguments.data(using: .utf8),
                  let args = try JSONSerialization.jsonObject(with: data) as? [String] else {
                throw PetStudioPlan.failure("参数须为 JSON 字符串数组。")
            }
            saveConfig()
            let dir = try makeJob()
            let resolved = args.map { $0.replacingOccurrences(of: "{job}", with: dir.appendingPathComponent("job.json").path)
                .replacingOccurrences(of: "{dir}", with: dir.path)
                .replacingOccurrences(of: "{output}", with: dir.appendingPathComponent("output").path) }
            let executable = config.executable
            running = true; message = "工具正在制作素材；可在任务目录查看日志。"
            DispatchQueue.global(qos: .userInitiated).async {
                let response = Result { try PetStudioProcess.run(executable: executable, arguments: resolved, directory: dir, timeout: 600) }
                DispatchQueue.main.async {
                    running = false
                    switch response {
                    case .success: message = "工具运行完成。打开任务 output 目录检查成品，再点「导入成品」。"
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            }
        } catch { message = error.localizedDescription }
    }
    private func importOutput() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "webp", "vrm", "lianapet"]
        panel.directoryURL = job?.appendingPathComponent("output")
        guard panel.runModal() == .OK else { return }
        do {
            var images: [URL] = []
            for url in panel.urls {
                switch url.pathExtension.lowercased() {
                case "vrm":
                    let id = try PetImporter.importVRM(from: url, packId: "vrm-" + UUID().uuidString.lowercased(), name: model.draft.name)
                    message = "VRM 已导入形象库，可从桌宠菜单切换。ID：\(id)"
                case "lianapet":
                    let id = try PuppetPackStore.importPack(from: url)
                    if let draft = PuppetPackStore.load(packId: id) { model.load(draft) }
                default: images.append(url)
                }
            }
            if !images.isEmpty { model.add(images) }
        } catch { message = error.localizedDescription }
    }
    private func cleanEdge() {
        guard let i = model.selectedIndex else { return }
        let image = model.draft.images[i]
        let source = originalImages[image.id] ?? image.png
        originalImages[image.id] = source
        if let png = PuppetBuilder.cleanEdges(source, strength: edge, whiteMatte: whiteMatte) {
            model.draft.images[i].png = png
            model.refreshPreview(immediately: false)
            message = "边缘已修整，切换黑白底检查细节。可以恢复本次修整前。"
        } else { message = "边缘修整失败，图片保持原样。" }
    }
}
