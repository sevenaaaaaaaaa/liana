import AppKit
import AVFoundation
import Carbon
import Speech
import SwiftUI

// MARK: - 松萝设置中心
//
// 一个窗口管所有配置：侧栏分区 + 系统设置同款分组表单。
// macOS 26 上 NavigationSplitView 的侧栏、工具栏、按钮自动是 Liquid Glass；
// 旧系统回退为毛玻璃侧栏。原来散落在菜单、权限中心、AI 窗口里的开关都在这里有入口。

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview, input, voice, learning, pet, appearance, clipboard, ai, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .input: return "输入"
        case .voice: return "语音与同传"
        case .learning: return "知你学习"
        case .pet: return "桌宠"
        case .appearance: return "外观"
        case .clipboard: return "剪切板"
        case .ai: return "本地 AI"
        case .privacy: return "隐私与备份"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .input: return "keyboard.fill"
        case .voice: return "mic.fill"
        case .learning: return "brain.head.profile"
        case .pet: return "pawprint.fill"
        case .appearance: return "paintpalette.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .ai: return "cpu.fill"
        case .privacy: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: return LianaDesign.brand
        case .input: return Color(red: 0.40, green: 0.45, blue: 0.55)
        case .voice: return Color(red: 0.95, green: 0.33, blue: 0.36)
        case .learning: return LianaDesign.pine
        case .pet: return Color(red: 0.98, green: 0.62, blue: 0.22)
        case .appearance: return Color(red: 0.62, green: 0.40, blue: 0.95)
        case .clipboard: return Color(red: 0.45, green: 0.50, blue: 0.58)
        case .ai: return Color(red: 0.18, green: 0.64, blue: 0.78)
        case .privacy: return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .about: return Color(red: 0.55, green: 0.55, blue: 0.58)
        }
    }
}

/// 设置状态：真实数据源仍是各模块（UserDefaults / 单例），这里只负责刷新视图。
final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection? = .overview
    @Published private(set) var revision = 0

    func touch() {
        revision += 1
    }

    /// 把「读一个值 / 写一个值」包成 Binding，写完刷新界面。
    func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(
            get: get,
            set: { [weak self] value in
                set(value)
                self?.touch()
            }
        )
    }

    // MARK: 状态读数

    var imeIsCurrent: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return false }
        let id = Unmanaged<CFString>.fromOpaque(ref).takeUnretainedValue() as String
        return id.hasPrefix(Bundle.main.bundleIdentifier ?? "dev.liana")
    }

    var currentMode: LianaMode {
        UserDefaults.standard.string(forKey: "LianaMode").flatMap(LianaMode.init(rawValue:)) ?? .pinyin
    }

    var nutritionCount: Int {
        EncryptedStore.shared.nutritionTsv.split(separator: "\n").filter { !$0.hasPrefix("#") }.count
    }

    var clipboardCount: Int { EncryptedStore.shared.clipboard.count }

    var voiceOnDevice: Bool { VoiceInputController.availability().onDevice }

    var speechAuthorized: Bool {
        VoiceInputController.availability().authorized == .authorized
    }

    var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var translateRuntime: String? { TranslateClient.findRuntime() }
    var translateModel: String? { TranslateClient.translateModelPath() }

    var installedModels: Int {
        AIModelStore.shared.catalog.filter { AIModelStore.shared.isInstalled($0) }.count
    }
}

final class SettingsCenter {
    static let shared = SettingsCenter()

    private var window: NSWindow?
    let model = SettingsModel()

    func show(section: SettingsSection? = nil) {
        if let section {
            model.section = section
        }
        model.touch()
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "松萝设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        window.setContentSize(NSSize(width: 860, height: 600))
        window.center()
        window.setFrameAutosaveName("LianaSettingsCenter")
        self.window = window
        return window
    }
}

// MARK: - 根视图

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $model.section) { section in
                NavigationLink(value: section) {
                    HStack(spacing: 10) {
                        LianaIconBadge(symbol: section.symbol, color: section.color, size: 22)
                        Text(section.title)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch model.section ?? .overview {
                case .overview: OverviewPage(model: model)
                case .input: InputPage(model: model)
                case .voice: VoicePage(model: model)
                case .learning: LearningPage(model: model)
                case .pet: PetPage(model: model)
                case .appearance: AppearancePage(model: model)
                case .clipboard: ClipboardPage(model: model)
                case .ai: AIPage(model: model)
                case .privacy: PrivacyPage(model: model)
                case .about: AboutPage()
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// 分组表单页面骨架：大标题 + 系统设置同款 grouped Form。
struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LianaIconBadge(symbol: section.symbol, color: section.color, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.system(size: 20, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }
            content
        }
        .formStyle(.grouped)
    }
}

/// 表单里的状态行：标题 + 说明 + 右侧状态胶囊。
struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool
    var okText = "就绪"
    var badText = "未就绪"

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ok ? Color.green : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.14)))
        }
    }
}

/// 开关行：标题 + 一行说明。
struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - 概览

struct OverviewPage: View {
    @ObservedObject var model: SettingsModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                Text("常用功能")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    FeatureCard(symbol: "text.viewfinder", color: LianaDesign.pine, title: "截图快速学习",
                                detail: "框选屏幕上的文字，新词立刻能打出来") {
                        LianaActions.perform(.screenshotLearn)
                    }
                    FeatureCard(symbol: "mic.fill", color: Color(red: 0.95, green: 0.33, blue: 0.36), title: "语音输入",
                                detail: "打字时按 ⌃` → 2，边说边落字") {
                        model.section = .voice
                    }
                    FeatureCard(symbol: "globe", color: LianaDesign.brand, title: "同声传译",
                                detail: "说中文，直接打出英文 / 日文") {
                        model.section = .voice
                    }
                    FeatureCard(symbol: "pawprint.fill", color: Color(red: 0.98, green: 0.62, blue: 0.22), title: "桌宠",
                                detail: "Live2D / VRM 形象，导入你自己的模型") {
                        model.section = .pet
                    }
                    FeatureCard(symbol: "doc.text.fill", color: Color(red: 0.18, green: 0.64, blue: 0.78), title: "喂它一段",
                                detail: "项目文档、聊天记录 → 专属词库") {
                        LianaActions.perform(.feed)
                    }
                    FeatureCard(symbol: "doc.on.clipboard.fill", color: Color(red: 0.45, green: 0.50, blue: 0.58), title: "剪切板历史",
                                detail: "本地加密保存，默认关闭") {
                        model.section = .clipboard
                    }
                }
                shortcuts
            }
            .padding(24)
        }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSImage(named: "Liana") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("松萝")
                    .font(.system(size: 26, weight: .bold))
                Text("越用越懂你的本地输入法 · 零云 · 零遥测")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Chip(text: model.imeIsCurrent ? "正在使用松萝" : "未选中松萝",
                         symbol: model.imeIsCurrent ? "checkmark.circle.fill" : "keyboard",
                         color: model.imeIsCurrent ? .green : .orange)
                    Chip(text: "默认 \(model.currentMode.title)", symbol: "character.cursor.ibeam", color: LianaDesign.brand)
                    Chip(text: "营养词 \(model.nutritionCount)", symbol: "leaf.fill", color: LianaDesign.pine)
                }
            }
            Spacer()
        }
        .padding(20)
        .lianaGlass(cornerRadius: LianaDesign.radiusLarge, tint: LianaDesign.brand.opacity(0.12))
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ShortcutRow(keys: "⌃ `", title: "功能面板", detail: "截图学习、语音、同传、桌宠一键直达")
                Divider()
                ShortcutRow(keys: "单按 ⇧", title: "中英切换", detail: "左 Shift 单击，不打断当前输入")
                Divider()
                ShortcutRow(keys: "a a", title: "网址 / 表情模式", detail: "浏览器里连按两下 a 进网址模式，聊天工具里进表情")
                Divider()
                ShortcutRow(keys: "u…", title: "符号输入", detail: "u 开头检索符号，如 uduihao → ✓")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .lianaGlass(cornerRadius: LianaDesign.radiusMedium)
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct FeatureCard: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                LianaIconBadge(symbol: symbol, color: color, size: 34)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .lianaGlass(cornerRadius: LianaDesign.radiusMedium, tint: hovering ? color.opacity(0.18) : nil, interactive: true)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: LianaDesign.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ShortcutRow: View {
    let keys: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(minWidth: 64)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 输入

struct InputPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(section: .input, subtitle: "输入方案、标点与中英切换习惯。改动立即生效，无需重启。") {
            Section("输入方案") {
                Picker("默认输入模式", selection: model.binding({ model.currentMode }, { mode in
                    UserDefaults.standard.set(mode.rawValue, forKey: "LianaMode")
                    if mode.isChinese {
                        UserDefaults.standard.set(mode.rawValue, forKey: "LianaLastChineseMode")
                    }
                    NotificationCenter.default.post(name: .lianaModeChanged, object: nil, userInfo: ["mode": mode.rawValue])
                })) {
                    ForEach(LianaMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                ToggleRow(
                    title: "繁体输出",
                    detail: "候选与上屏用繁体字（OpenCC 词组级转换），学习仍按简体记",
                    isOn: model.binding({ UserDefaults.standard.bool(forKey: LianaInputController.traditionalKey) }, { on in
                        UserDefaults.standard.set(on, forKey: LianaInputController.traditionalKey)
                        NotificationCenter.default.post(name: .lianaTraditionalChanged, object: nil)
                    })
                )
            }
            Section("候选") {
                Picker("拼音提示", selection: model.binding({ ReadingDisplay.current }, { ReadingDisplay.current = $0 })) {
                    ForEach(ReadingDisplay.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text("「仅纠错时显示」：模糊音、纠错、简拼（如 wdmz → wo de ming zi）时才在候选下标出拼音，打得和读音一致就不显示")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("标点") {
                ToggleRow(
                    title: "所有应用强制半角标点",
                    detail: "关闭时按应用自动：代码编辑器 / 终端用半角，其余用全角",
                    isOn: model.binding({ UserDefaults.standard.bool(forKey: "LianaForceHalfPunctuation") }, {
                        UserDefaults.standard.set($0, forKey: "LianaForceHalfPunctuation")
                    })
                )
            }
            Section("中英切换") {
                ToggleRow(
                    title: "按应用记忆中 / 英",
                    detail: "在终端里习惯英文、在微信里习惯中文？切过去自动恢复。关闭会清空已学习的偏好",
                    isOn: model.binding({ AppModeMemory.shared.isEnabled }, { AppModeMemory.shared.isEnabled = $0 })
                )
            }
            Section("词库") {
                LabeledContent("内置词库") {
                    Text("20 万词条 · 语料词频校准")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("词典与用户数据目录")
                    Spacer()
                    Button("在访达中打开") { LianaActions.openDataFolder() }
                        .lianaGlassButton()
                }
            }
        }
    }
}

// MARK: - 语音与同传

struct VoicePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(section: .voice, subtitle: "端上语音识别，边说边落字；同声传译用本机小模型，原文与译文都不离开这台 Mac。") {
            Section {
                HowToRow(step: "1", text: "在任意输入框里打字时，按 ⌃`（Control + 反引号）打开功能面板")
                HowToRow(step: "2", text: "按 2 开始语音输入；按 3 / 4 开始同传（译成英文 / 日文）")
                HowToRow(step: "3", text: "说完会给出标点候选，空格确认；按 Esc 随时取消")
            } header: {
                Text("怎么用")
            }
            Section("语音识别") {
                StatusRow(title: "端上识别", detail: "语音模型在本机运行，不回退云端",
                          ok: model.voiceOnDevice, okText: "可用", badText: "此 Mac 不支持")
                StatusRow(title: "麦克风权限", detail: "首次使用会弹出系统授权",
                          ok: model.micAuthorized, okText: "已授权", badText: "未授权")
                StatusRow(title: "语音识别权限", detail: "系统设置 › 隐私与安全性 › 语音识别",
                          ok: model.speechAuthorized, okText: "已授权", badText: "未授权")
                if !model.micAuthorized || !model.speechAuthorized {
                    HStack {
                        Spacer()
                        Button("打开麦克风设置") { LianaActions.openPrivacyPane("Privacy_Microphone") }
                            .lianaGlassButton()
                        Button("打开语音识别设置") { LianaActions.openPrivacyPane("Privacy_SpeechRecognition") }
                            .lianaGlassButton()
                    }
                }
                ToggleRow(
                    title: "代码模式语音（符号词 + 命名模式口令）",
                    detail: "说「点」落 .、「箭头」落 ->、「井号」落 #；说「驼峰 get user」落 getUser，「下划线模式」「常量模式」同理；中文正文照常上屏。默认关",
                    isOn: model.binding({ DevDictation.enabled }, { DevDictation.enabled = $0 })
                )
            }
            Section("同声传译") {
                StatusRow(title: "翻译运行时（llama.cpp）",
                          detail: model.translateRuntime ?? "终端执行 brew install llama.cpp（不自动下载可执行文件）",
                          ok: model.translateRuntime != nil, okText: "已安装", badText: "未安装")
                StatusRow(title: "翻译模型（Gemma 3 270M）",
                          detail: model.translateModel.map { ($0 as NSString).lastPathComponent } ?? "约 278 MB，点击下载并 sha256 校验",
                          ok: model.translateModel != nil, okText: "已下载", badText: "未下载")
                HStack {
                    Spacer()
                    if model.translateRuntime == nil {
                        Button("复制安装命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install llama.cpp", forType: .string)
                            GlassToast.shared.show("已复制：brew install llama.cpp", symbol: "doc.on.doc.fill", duration: 3)
                        }
                        .lianaGlassButton()
                    }
                    Button("管理本地模型…") { SettingsCenter.shared.show(section: .ai) }
                        .lianaProminentButton()
                }
            }
        }
    }
}

struct HowToRow: View {
    let step: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(LianaDesign.brand))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 知你学习

struct LearningPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(section: .learning, subtitle: "选词、纠错、你喂给它的资料都会变成排序依据——全部只在本机。") {
            Section("截图快速学习") {
                HStack(spacing: 14) {
                    LianaIconBadge(symbol: "text.viewfinder", color: LianaDesign.pine, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("框选屏幕 → 认字 → 学会新词")
                        Text("会议纪要、设计稿、聊天截图里的专有名词，一次就能打出来。也可以在功能面板按 1。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("开始截图") { LianaActions.perform(.screenshotLearn) }
                        .lianaProminentButton()
                }
                HStack {
                    Text("上次截图学到的词不满意？")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("逐个审阅…") { ScreenshotLearner.shared.reviewLast() }
                        .lianaGlassButton()
                }
            }
            Section("喂它一段") {
                LabeledContent("营养词") {
                    Text("\(model.nutritionCount) 个")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("导入文档、聊天记录、图片，提炼反复出现的术语")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开喂食窗…") { LianaActions.perform(.feed) }
                        .lianaGlassButton()
                }
            }
            Section("自进化") {
                ToggleRow(
                    title: "知你学习",
                    detail: "把选词与选后删除当作教学信号，按应用、时段调整排序",
                    isOn: model.binding({ EvolutionLearning.isEnabled }, { on in
                        EvolutionLearning.setEnabled(on)
                        NotificationCenter.default.post(name: .evolutionToggled, object: nil)
                    })
                )
                HStack {
                    Text("清空知你账本")
                    Spacer()
                    Button("清空…", role: .destructive) { confirmForget() }
                        .lianaGlassButton()
                }
            }
        }
    }

    private func confirmForget() {
        let alert = NSAlert()
        alert.messageText = "清空知你学习账本？"
        alert.informativeText = "学到的排序偏好会全部删除，无法恢复。用户词与营养词不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        LianaEngine(mode: "pinyin").forgetEvolution()
        EncryptedStore.shared.setEvolution("")
        NotificationCenter.default.post(name: .evolutionToggled, object: nil)
        GlassToast.shared.show("知你学习账本已清空", symbol: "trash.fill", duration: 3)
        model.touch()
    }
}

// MARK: - 桌宠

struct PetPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let installed = PetWindowController.availablePets()
        let installedIds = Set(installed.map { $0.id })
        let downloadable = PetCatalogStore.entries().filter { !installedIds.contains($0.id) }
        return SettingsPage(section: .pet, subtitle: "陪你打字的小伙伴：会对输入做出反应。点它摸头、双击戳一戳，右键看统计与更多设置。") {
            Section {
                ToggleRow(
                    title: "显示桌宠",
                    detail: "在桌面角落常驻，可拖动",
                    isOn: model.binding({ PetWindowController.isEnabled }, { PetWindowController.setEnabled($0) })
                )
                ToggleRow(
                    title: "安静模式",
                    detail: "不主动问候和闲聊，只在你摸它时回应",
                    isOn: model.binding({ PetWindowController.quietMode }, { PetWindowController.quietMode = $0 })
                )
                ToggleRow(
                    title: "场景跟随应用",
                    detail: "打游戏拿手柄、写代码有桌子键盘、听歌摇摆、看视频吃爆米花……只看前台应用是哪个，不看窗口内容",
                    isOn: model.binding({ PetWindowController.scenesEnabled }, { PetWindowController.scenesEnabled = $0 })
                )
                ToggleRow(
                    title: "跟着鼠标走",
                    detail: "鼠标停在远处一会儿，它会沿着屏幕走过去",
                    isOn: model.binding({ PetWindowController.followMouse }, { PetWindowController.followMouse = $0 })
                )
                ToggleRow(
                    title: "入场 / 离场动画",
                    detail: "出现时从天而降、从底下冒出来、从边上走进来或弹出来；隐藏时跳着离开",
                    isOn: model.binding({ PetWindowController.entranceEnabled }, { PetWindowController.entranceEnabled = $0 })
                )
                ToggleRow(
                    title: "不在输入框时打字就聊天",
                    detail: "在桌面等没有输入框的地方连续敲字母，会打开对话气泡。需要辅助功能权限，只用来判断当前是不是输入框，不记录任何按键；聊天内容不保存",
                    isOn: model.binding({ PetChatAutoTrigger.enabled }, { PetChatAutoTrigger.enabled = $0 })
                )
                ToggleRow(
                    title: "复制命令后问我要不要在终端运行",
                    detail: "点「在终端运行」才会运行；rm -rf、sudo、curl | sh 等危险命令会再弹窗确认。剪贴板只判断一次，不记录",
                    isOn: model.binding({ ClipboardActionWatcher.commandsEnabled }, { ClipboardActionWatcher.commandsEnabled = $0 })
                )
                ToggleRow(
                    title: "复制链接后提供浏览器任务",
                    detail: "总结 / 翻译 / 截图存档 / 站点菜谱：用本机 ego lite（优先）或 Chrome 打开，本机模型处理，不走云服务",
                    isOn: model.binding({ ClipboardActionWatcher.linksEnabled }, { ClipboardActionWatcher.linksEnabled = $0 })
                )
                ToggleRow(
                    title: "复制淘宝 / 京东等口令后提示一键打开",
                    detail: "识别口令和电商短链，点「打开」才拉起对应 App（没装就开网页版）。只做本地模式匹配，不记录剪贴板内容",
                    isOn: model.binding({ ClipboardActionWatcher.codesEnabled }, { ClipboardActionWatcher.codesEnabled = $0 })
                )
                HStack {
                    Text("站点菜谱：按域名匹配、在页面里运行的一段 JS").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开菜谱目录…") { LinkRecipeStore.openFolder() }.controlSize(.small)
                }
                ToggleRow(
                    title: "休息提醒",
                    detail: "连续打字 \(PetWindowController.breakMinutes) 分钟后提醒你起身活动",
                    isOn: model.binding({ PetWindowController.breakReminder }, { PetWindowController.breakReminder = $0 })
                )
                Picker("画幅", selection: model.binding({ PetWindowController.framingOverride }, { PetWindowController.framingOverride = $0 })) {
                    Text("全身").tag("full")
                    Text("半身").tag("bust")
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("大小")
                    Slider(value: model.binding({ PetWindowController.zoomOverride * 100 }, { PetWindowController.zoomOverride = $0 / 100 }),
                           in: (PetWindowController.zoomRange.lowerBound * 100)...(PetWindowController.zoomRange.upperBound * 100))
                    Text("\(Int((PetWindowController.zoomOverride * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                Text("也可以在桌宠身上双指捏合，或按住 ⌥ 滚动滚轮调节")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("形象") {
                if installed.isEmpty {
                    Text("还没有安装形象包").foregroundStyle(.secondary)
                }
                ForEach(installed, id: \.id) { pack in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                            if let desc = pack.description, !desc.isEmpty {
                                Text(desc).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if PetWindowController.activePackId == pack.id {
                            Label("使用中", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.green)
                        } else {
                            Button("使用") {
                                PetWindowController.activePackId = pack.id
                                if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
                                model.touch()
                            }
                            .lianaGlassButton()
                        }
                    }
                }
                ForEach(downloadable, id: \.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text("\(entry.license) · \(entry.sizeText)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("下载") {
                            LianaActions.installOrSwitchPet(id: entry.id) { model.touch() }
                        }
                        .lianaGlassButton()
                    }
                }
                HStack {
                    Spacer()
                    Button("形象目录…") { PetCatalogWindowController.shared.show() }
                        .lianaGlassButton()
                }
            }
            Section("自定义形象") {
                CustomPetRow(symbol: "wand.and.stars", title: "用图片做桌宠",
                             detail: "1 张或几张图片，本机抠图生成会动的纸偶形象", button: "打开形象工坊…") {
                    let active = PetWindowController.activePackId
                    PetWorkshopWindowController.shared.show(editing: PuppetPackStore.isPuppet(packId: active) ? active : nil)
                }
                CustomPetRow(symbol: "antenna.radiowaves.left.and.right", title: "形象源",
                             detail: "订阅别人发布的形象目录，一键下载（sha256 校验）", button: "打开…") {
                    PetCommunityWindowController.shared.show()
                }
                CustomPetRow(symbol: "shippingbox.fill", title: "导入 .lianapet 形象包",
                             detail: "别人分享的纸偶形象（只含图片与动作数据，不含代码）", button: "选择…") {
                    PetWorkshopWindowController.shared.importPack()
                    model.touch()
                }
                CustomPetRow(symbol: "person.crop.square.fill", title: "导入 VRM 模型",
                             detail: "VRoid Studio 可免费捏人并导出 .vrm", button: "选择文件…") {
                    LianaActions.importVRM()
                    model.touch()
                }
                CustomPetRow(symbol: "sparkles.rectangle.stack.fill", title: "导入 Live2D 模型",
                             detail: "选择含 *.model3.json 的文件夹或 .zip", button: "选择…") {
                    LianaActions.importLive2D()
                    model.touch()
                }
                CustomPetRow(symbol: "photo.on.rectangle.angled", title: "用一张图片生成 VRM",
                             detail: "云端服务 VTubeMe，会上传你选的图片", button: "打开…") {
                    AvatarCreatorWindowController.shared.show()
                }
                StatusRow(title: "Live2D Cubism Core",
                          detail: "Live2D 官方运行时需自行下载（许可原因不随包分发）",
                          ok: PetRuntimeStore.live2DCoreAvailable(), okText: "已就绪", badText: "未放置")
                if !PetRuntimeStore.live2DCoreAvailable() {
                    HStack {
                        Spacer()
                        Button("去官网下载") { LianaActions.openLive2DCorePage() }
                            .lianaGlassButton()
                        Button("打开放置目录") { NSWorkspace.shared.open(PetRuntimeStore.userLive2DCoreDir) }
                            .lianaGlassButton()
                    }
                }
            }
        }
    }
}

struct CustomPetRow: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.98, green: 0.62, blue: 0.22))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
                .lianaGlassButton()
        }
    }
}

// MARK: - 外观

struct AppearancePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let skins = ThemeStore.availableSkins()
        return SettingsPage(section: .appearance, subtitle: "候选窗在 macOS 26 上是系统 Liquid Glass；皮肤包只改色调、圆角与字号。") {
            Section("候选窗皮肤") {
                SkinRow(name: "跟随系统（素玻璃）", detail: "与系统输入法一致，推荐", active: ThemeStore.activeId.isEmpty) {
                    ThemeStore.activeId = ""
                    model.touch()
                }
                ForEach(skins, id: \.id) { pack in
                    SkinRow(name: pack.name, detail: pack.description ?? "v\(pack.version)", active: ThemeStore.activeId == pack.id) {
                        ThemeStore.activeId = pack.id
                        model.touch()
                    }
                }
            }
            Section {
                HStack {
                    Text("皮肤包放在插件目录，格式见 docs/adr/0005-plugin-system.md")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开插件目录") { NSWorkspace.shared.open(PluginStore.pluginsDir) }
                        .lianaGlassButton()
                }
            }
        }
    }
}

struct SkinRow: View {
    let name: String
    let detail: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(active ? LianaDesign.brand : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 剪切板

struct ClipboardPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let recent = Array(EncryptedStore.shared.clipboard.prefix(5))
        return SettingsPage(section: .clipboard, subtitle: "复制过的文字加密存在本机；密码管理器等敏感应用自动跳过。") {
            Section {
                ToggleRow(
                    title: "记录剪切板历史",
                    detail: "默认关闭。关闭后已有历史仍保留，可随时清空",
                    isOn: model.binding({ ClipboardMonitor.shared.isEnabled }, { ClipboardMonitor.shared.setEnabled($0) })
                )
                LabeledContent("已保存") {
                    Text("\(model.clipboardCount) 条 · 上限 \(EncryptedStore.maxClipboardItems)")
                        .foregroundStyle(.secondary)
                }
            }
            if !recent.isEmpty {
                Section("最近") {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                        let line = item.text.split(separator: "\n").first.map(String.init) ?? item.text
                        Text(line)
                            .lineLimit(1)
                            .font(.system(size: 13))
                    }
                }
            }
            Section {
                HStack {
                    Button("打开剪切板历史…") { LianaActions.perform(.clipboard) }
                        .lianaProminentButton()
                    Spacer()
                    Button("清空历史", role: .destructive) {
                        EncryptedStore.shared.clearClipboard()
                        model.touch()
                    }
                    .lianaGlassButton()
                    .disabled(model.clipboardCount == 0)
                }
            }
        }
    }
}

// MARK: - 本地 AI

/// 把 `AIModelStore` 的回调转成 SwiftUI 刷新。设置中心是唯一订阅方。
final class AISettingsBridge: ObservableObject {
    @Published var tick = 0

    init() {
        let store = AIModelStore.shared
        store.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.tick += 1 }
        }
        store.onProgress = { [weak self] _, _ in
            DispatchQueue.main.async { self?.tick += 1 }
        }
        store.onFinish = { [weak self] id, error in
            DispatchQueue.main.async {
                self?.tick += 1
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "下载失败"
                    alert.informativeText = "\(id)：\(error)"
                    alert.runModal()
                }
            }
        }
    }

    var store: AIModelStore { AIModelStore.shared }
}

struct AIPage: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var ai = AISettingsBridge()
    @State private var rerank = SentenceRerank.enabled

    var body: some View {
        let store = ai.store
        let used = ByteCountFormatter.string(fromByteCount: store.diskUsage(), countStyle: .file)
        return SettingsPage(section: .ai, subtitle: "没有云 API。可选的小模型只在你点击后下载，并做 sha256 校验。") {
            Section("内置") {
                StatusRow(title: "统计语言模型", detail: "用户词 + 上下词 + 自动短语，内存 < 1 MB，随输入学习",
                          ok: true, okText: "运行中", badText: "")
                ToggleRow(title: "长句 AI 重排",
                          detail: TranslateClient.rerankModelPath() == nil
                              ? "打长句停顿时，用本机模型挑更通顺的整句。需要下方的 Qwen2.5 0.5B（推荐）或 1.5B 和 llama.cpp"
                              : "打长句停顿时，用本机模型挑更通顺的整句（句子只在本机处理，空闲 5 分钟自动释放内存）",
                          isOn: $rerank)
                    .onChange(of: rerank) { on in
                        SentenceRerank.enabled = on
                        if !on { TranslateClient.rerank.stop() }
                    }
            }
            Section("本机") {
                LabeledContent("内存") {
                    Text(store.totalRamText).foregroundStyle(.secondary)
                }
                LabeledContent("已下载模型占用") {
                    Text(used).foregroundStyle(.secondary)
                }
                StatusRow(title: "llama.cpp 运行时", detail: model.translateRuntime ?? "终端执行 brew install llama.cpp（不自动下载可执行文件）",
                          ok: model.translateRuntime != nil, okText: "已安装", badText: "未安装")
                if model.translateRuntime == nil {
                    HStack {
                        Spacer()
                        Button("复制安装命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install llama.cpp", forType: .string)
                            GlassToast.shared.show("已复制：brew install llama.cpp", symbol: "doc.on.doc.fill", duration: 3)
                        }
                        .lianaGlassButton()
                    }
                }
            }
            Section("可下载模型") {
                ForEach(store.catalog) { item in
                    AIModelRow(model: item, store: store)
                }
            }
        }
        .id(ai.tick)
    }
}

struct AIModelRow: View {
    let model: AIModelInfo
    let store: AIModelStore

    var body: some View {
        let kind = model.kinds.first ?? "assist"
        let level = store.recommendation.level(for: kind)
        let enabled = AIModelStore.selectedModelId(for: kind) == model.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.name)  ·  \(model.quantText)")
                    Text("\(model.sizeText) 磁盘 · 约 \(model.ramMb) MB 内存 · \(model.license)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(model.note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer()
                Text(store.recommendation.levelLabel(for: kind))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(levelColor(level))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(levelColor(level).opacity(0.14)))
            }
            HStack {
                Text(model.kinds.map(kindLabel).joined(separator: " / "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isDownloading(model) {
                    ProgressView(value: store.downloadProgress(for: model))
                        .frame(width: 90)
                    Button("取消") { store.cancel(model) }
                        .lianaGlassButton()
                } else if store.isInstalled(model) {
                    Button(enabled ? "已启用" : "启用") {
                        if enabled {
                            AIModelStore.setSelectedModelId(nil, for: kind)
                        } else {
                            AIModelStore.setSelectedModelId(model.id, for: kind)
                        }
                        store.onStateChange?()
                    }
                    .lianaProminentButton()
                    Button("删除", role: .destructive) {
                        for itemKind in model.kinds where AIModelStore.selectedModelId(for: itemKind) == model.id {
                            AIModelStore.setSelectedModelId(nil, for: itemKind)
                        }
                        store.delete(model)
                    }
                    .lianaGlassButton()
                } else {
                    Button("下载") { store.download(model) }
                        .lianaProminentButton()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func kindLabel(_ id: String) -> String {
        switch id {
        case "assist": return "候选优化"
        case "speech": return "语音输入"
        case "translate": return "同声传译"
        default: return id
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "suggested": return .green
        case "moderate": return .orange
        default: return .secondary
        }
    }
}

// MARK: - 隐私与备份

struct PrivacyPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(section: .privacy, subtitle: "内核不发起任何网络请求。每项敏感能力都能关闭，关闭即清除对应数据。") {
            Section("统计") {
                ToggleRow(
                    title: "输入统计",
                    detail: "只记次数与秒数（速度、纠错、省键），绝不记录按键内容。关闭即清空",
                    isOn: model.binding({ PetStats.shared.isEnabled }, { PetStats.shared.isEnabled = $0 })
                )
            }
            Section("权限总览") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("权限与隐私中心")
                        Text("每一项能力碰什么数据、存在哪、怎么删").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开…") { PermissionCenterWindowController.shared.show() }
                        .lianaGlassButton()
                }
            }
            Section("备份与恢复") {
                Text("只含用户词与短语，不含剪切板。加密备份用你设定的密码（PBKDF2 + ChaCha20-Poly1305）。换设备请走备份，不要拷 userdata.enc（密钥在本机钥匙串）。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("导出加密备份…") { LianaActions.exportEncryptedBackup() }
                        .lianaProminentButton()
                    Button("从备份恢复…") { LianaActions.restoreBackup(); model.touch() }
                        .lianaGlassButton()
                    Spacer()
                    Button("导出明文…") { LianaActions.exportPlainBackup() }
                        .buttonStyle(.link)
                }
            }
            Section("钥匙串") {
                StatusRow(
                    title: "用户数据密钥",
                    detail: EncryptedStore.shared.keyAvailable
                        ? "密钥在系统钥匙串，用户词与剪切板加密落盘"
                        : "钥匙串不可用，本次运行不落盘（仅内存）",
                    ok: EncryptedStore.shared.keyAvailable,
                    okText: "可用",
                    badText: "不可用"
                )
            }
        }
    }
}

// MARK: - 关于

struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short)（\(build)）"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSImage(named: "Liana") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            Text("松萝 Liana")
                .font(.system(size: 24, weight: .bold))
            Text("版本 \(version)")
                .foregroundStyle(.secondary)
            Text("Rust 内核 + 原生外壳 · AGPL-3.0\n词库：rime-ice（GPL-3.0）· 词包：THUOCL、chinese-xinhua（MIT）· 词频：wordfreq（CC BY-SA 4.0）\n整句搭配：万象 LMDG（CC BY 4.0）· 简繁：OpenCC")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            UpdatePanel()
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 在线更新：点了才联网检查；发现新版本后点「立即更新」下载、校验并替换，输入法自动重启。
struct UpdatePanel: View {
    enum Phase {
        case idle, checking, upToDate, found(LianaUpdater.Release), downloading(Double), installing
        case done(String), failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var nightly = LianaUpdater.includeNightly

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Toggle("也接收 Nightly（每日构建）", isOn: $nightly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .onChange(of: nightly) { LianaUpdater.includeNightly = $0 }
                Spacer()
                Button(checking ? "正在检查…" : "检查更新") { check() }
                    .disabled(busy)
                    .lianaGlassButton()
            }
            status
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var checking: Bool { if case .checking = phase { return true }; return false }
    private var busy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .idle:
            Text("只在你点「检查更新」时连接 GitHub，安装包会做 sha256 校验").font(.system(size: 11)).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("已是最新版本（\(LianaUpdater.currentVersion)）", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        case .found(let release):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("发现新版本 \(release.version)").font(.system(size: 13, weight: .semibold))
                    if release.size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("更新说明", destination: release.page).font(.system(size: 12))
                    Button("立即更新") { install(release) }.lianaGlassButton()
                }
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes.prefix(1500))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
            }
        case .downloading(let value):
            ProgressView(value: value) { Text("正在下载… \(Int(value * 100))%").font(.system(size: 11)) }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("正在校验并安装…").font(.system(size: 12)) }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
        }
    }

    private func check() {
        phase = .checking
        LianaUpdater.check { result in
            switch result {
            case .success(let release?): phase = .found(release)
            case .success(nil): phase = .upToDate
            case .failure(let error): phase = .failed(error.localizedDescription)
            }
        }
    }

    private func install(_ release: LianaUpdater.Release) {
        phase = .downloading(0)
        LianaUpdater.install(release, progress: { value in
            phase = value >= 1 ? .installing : .downloading(value)
        }, completion: { result in
            switch result {
            case .success(.installed(let version)):
                phase = .done("已更新到 \(version)，输入法马上重启")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { LianaUpdater.relaunch() }
            case .success(.manual(let reason)):
                phase = .done(reason)
            case .failure(let error):
                phase = .failed(error.localizedDescription)
            }
        })
    }
}
