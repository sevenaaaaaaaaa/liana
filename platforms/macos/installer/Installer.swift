import AppKit
import Carbon
import SwiftUI

/// 松萝安装器：欢迎 → (可选)自定义 → 安装进度 → 启用引导。
///
/// 设计：macOS 26 上卡片与按钮是系统 Liquid Glass，旧系统回退毛玻璃；
/// 一键安装是主路径，自定义是次路径；所有耗时步骤在后台跑，界面不卡顿。
///
/// 签名说明：macOS 26+ 的输入源扫描器会拒绝 ad-hoc 签名的第三方输入法，
/// 必须 Developer ID 签名（并公证）才会出现在系统输入法列表；界面会给出诊断。

// MARK: - 玻璃材质（与输入法本体 LianaUI.swift 同源）

@available(macOS 26.0, *)
private func makeInstallerGlass(tint: Color?) -> Glass {
    var glass = Glass.regular
    if let tint {
        glass = glass.tint(tint)
    }
    return glass
}

extension View {
    @ViewBuilder
    func installerGlass(cornerRadius: CGFloat = 20, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeInstallerGlass(tint: tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
                )
        }
    }

    @ViewBuilder
    func installerProminent() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func installerSecondary() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

private let brandBlue = Color(red: 0.25, green: 0.52, blue: 0.93)
private let pineGreen = Color(red: 0.20, green: 0.68, blue: 0.52)

// MARK: - 状态

enum InstallerStage {
    case welcome, customize, installing, finish
}

enum StepState {
    case pending, running, done, failed
}

struct InstallStep: Identifiable {
    let id: Int
    let title: String
    var state: StepState = .pending
    var detail: String = ""
}

final class InstallerModel: ObservableObject {
    @Published var stage: InstallerStage = .welcome
    @Published var steps: [InstallStep] = []
    @Published var log: [String] = []
    @Published var registered = false
    @Published var waitingForSystem = false
    @Published var failed = false
    @Published var showUninstall = false

    // 配置
    @Published var mode = "pinyin"
    @Published var systemWide = false
    @Published var traditional = false
    @Published var clipboard = false
    @Published var pet = true
    @Published var appMemory = true
    @Published var stats = true
    @Published var halfPunct = false
    @Published var purgeOnUninstall = false

    let modeOptions: [(String, String)] = [
        ("pinyin", "全拼（推荐）"),
        ("flypy", "小鹤双拼"),
        ("mspy", "微软双拼"),
        ("zrm", "自然码"),
        ("en", "English"),
        ("ja", "日本語"),
    ]

    private var pollTimer: Timer?
    private var pollCount = 0
    private var promptedSettings = false

    /// 以内嵌 Liana.app 的实际 bundle id 为准（支持 build.sh 的 BUNDLE_ID 覆盖）。
    lazy var imeBundleID: String = {
        let plist = (Bundle.main.resourcePath ?? "") + "/Liana.app/Contents/Info.plist"
        let value = InstallerModel.runShell("/usr/bin/plutil -extract CFBundleIdentifier raw \"\(plist)\" 2>/dev/null")
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? "dev.liana.inputmethod.ime" : id
    }()

    lazy var signatureIsAdhoc: Bool = {
        let info = InstallerModel.runShell("/usr/bin/codesign -dv --verbose=4 \"\(self.sourceApp)\" 2>&1")
        return info.contains("Signature=adhoc")
    }()

    let userAppPath = NSHomeDirectory() + "/Library/Input Methods/Liana.app"
    let systemAppPath = "/Library/Input Methods/Liana.app"
    var sourceApp: String { Bundle.main.resourcePath.map { $0 + "/Liana.app" } ?? "" }
    var sourceDict: String { Bundle.main.resourcePath.map { $0 + "/base.ifd" } ?? "" }
    /// 整句搭配模型（可选，和词库放在一起）
    var sourceLM: String { Bundle.main.resourcePath.map { $0 + "/base.lm" } ?? "" }
    var userDataDir: String { NSHomeDirectory() + "/Library/Application Support/Liana" }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: userAppPath) || FileManager.default.fileExists(atPath: systemAppPath)
    }

    var modeTitle: String {
        modeOptions.first { $0.0 == mode }?.1 ?? mode
    }

    // MARK: 配置

    func saveConfig() {
        let defaults = UserDefaults(suiteName: imeBundleID)
        defaults?.set(mode, forKey: "LianaMode")
        if mode != "en" && mode != "ja" {
            defaults?.set(mode, forKey: "LianaLastChineseMode")
        }
        defaults?.set(traditional, forKey: "LianaTraditional")
        defaults?.set(clipboard, forKey: "LianaClipboardEnabled")
        defaults?.set(pet, forKey: "LianaPetEnabled")
        defaults?.set(appMemory, forKey: "LianaAppModeMemoryEnabled")
        defaults?.set(stats, forKey: "LianaStatsEnabled")
        defaults?.set(halfPunct, forKey: "LianaForceHalfPunctuation")
        defaults?.synchronize()
        append("已保存配置：模式=\(mode) · 繁体=\(traditional) · 剪切板=\(clipboard) · 桌宠=\(pet)")
    }

    // MARK: 安装

    func install() {
        stage = .installing
        failed = false
        registered = false
        waitingForSystem = false
        steps = [
            InstallStep(id: 0, title: "保存你的设置"),
            InstallStep(id: 1, title: systemWide ? "复制到 /Library/Input Methods" : "复制到 ~/Library/Input Methods"),
            InstallStep(id: 2, title: "安装 20 万词条词库"),
            InstallStep(id: 3, title: "注册并启用输入法"),
            InstallStep(id: 4, title: "等待系统收录"),
        ]
        set(0, .running)
        saveConfig()
        set(0, .done)
        if systemWide {
            installSystem()
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.installForUser()
            }
        }
    }

    private func installForUser() {
        let fm = FileManager.default
        let dest = userAppPath
        onMain { self.set(1, .running) }
        do {
            try fm.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: NSHomeDirectory() + "/Library/Input Methods", withIntermediateDirectories: true)
            Self.runShell("/usr/bin/killall Liana")
            try? fm.removeItem(atPath: dest)
            try fm.copyItem(atPath: sourceApp, toPath: dest)
            Self.runShell("/usr/bin/xattr -dr com.apple.quarantine \"\(dest)\"")
            onMain { self.set(1, .done) }
        } catch {
            onMain { self.fail(1, "复制失败：\(error.localizedDescription)") }
            return
        }
        onMain { self.set(2, .running) }
        if fm.fileExists(atPath: sourceLM) {
            try? fm.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: userDataDir + "/base.lm")
            try? fm.copyItem(atPath: sourceLM, toPath: userDataDir + "/base.lm")
        }
        if fm.fileExists(atPath: sourceDict) {
            try? fm.removeItem(atPath: userDataDir + "/base.ifd")
            do {
                try fm.copyItem(atPath: sourceDict, toPath: userDataDir + "/base.ifd")
                onMain { self.set(2, .done) }
            } catch {
                onMain { self.set(2, .failed, detail: "词库复制失败，将使用内置小词库") }
            }
        } else {
            onMain { self.set(2, .done, detail: "安装包未带外部词库，使用内置词库") }
        }
        onMain { self.set(3, .running) }
        let bin = "\"\(dest)/Contents/MacOS/Liana\""
        append(Self.runShell("\(bin) --register-input-source"))
        append(Self.runShell("\(bin) --enable-input-source"))
        append(Self.runShell("\(bin) --dedupe-input-source"))
        Self.runShell("/usr/bin/killall TextInputMenuAgent imklaunchagent")
        onMain {
            self.set(3, .done)
            self.append("✅ 已安装到 \(dest)")
            self.startPolling()
        }
    }

    private func installSystem() {
        set(1, .running)
        let user = NSUserName()
        let script = """
        #!/bin/bash
        set -e
        SRC="\(sourceApp)"
        DST="/Library/Input Methods/Liana.app"
        DICT_SRC="\(sourceDict)"
        LM_SRC="\(sourceLM)"
        DICT_DST="/Users/\(user)/Library/Application Support/Liana"
        mkdir -p "/Library/Input Methods"
        rm -rf "$DST"
        cp -R "$SRC" "$DST"
        chown -R root:wheel "$DST"
        chmod -R go-w "$DST"
        xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
        mkdir -p "$DICT_DST"
        if [ -f "$DICT_SRC" ]; then cp "$DICT_SRC" "$DICT_DST/base.ifd"; chown \(user) "$DICT_DST/base.ifd" || true; fi
        if [ -f "$LM_SRC" ]; then cp "$LM_SRC" "$DICT_DST/base.lm"; chown \(user) "$DICT_DST/base.lm" || true; fi
        "$DST/Contents/MacOS/Liana" --register-input-source || true
        "$DST/Contents/MacOS/Liana" --enable-input-source || true
        "$DST/Contents/MacOS/Liana" --dedupe-input-source || true
        """
        let path = NSTemporaryDirectory() + "liana-install.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            fail(1, "无法写入安装脚本：\(error.localizedDescription)")
            return
        }
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"/bin/bash \(path)\" with administrator privileges")?
            .executeAndReturnError(&error)
        if let error {
            fail(1, "系统级安装失败或已取消：\(error[NSAppleScript.errorMessage] ?? "")")
            return
        }
        set(1, .done)
        set(2, .done)
        set(3, .done)
        Self.runShell("/usr/bin/killall TextInputMenuAgent imklaunchagent")
        append("✅ 已安装到 \(systemAppPath)")
        startPolling()
    }

    // MARK: 收录检测

    private func startPolling() {
        pollTimer?.invalidate()
        pollCount = 0
        set(4, .running)
        waitingForSystem = true
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollTick() {
        pollCount += 1
        if isRegistered() {
            pollTimer?.invalidate()
            registered = true
            waitingForSystem = false
            set(4, .done)
            append("✅ 系统已收录松萝")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.stage = .finish
            }
        } else if pollCount == 5, !promptedSettings {
            promptedSettings = true
            append("👉 打开「键盘设置」：点 + → 中文（简体）→ 松萝")
        } else if pollCount >= 24 {
            pollTimer?.invalidate()
            waitingForSystem = false
            set(4, .failed, detail: signatureIsAdhoc
                ? "当前是 ad-hoc 签名，macOS 26 不会收录；需要 Developer ID 签名的安装包"
                : "注销并重新登录一次，系统会重新扫描输入法")
            stage = .finish
        }
    }

    func recheck() {
        if isRegistered() {
            registered = true
            append("✅ 系统已收录松萝")
        } else {
            append("⏳ 系统暂未收录")
        }
    }

    func isRegistered() -> Bool {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        for source in list {
            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = unsafeBitCast(idRef, to: CFString.self) as String
            if id.hasPrefix(imeBundleID) {
                return true
            }
        }
        return false
    }

    // MARK: 卸载

    func uninstall() {
        let purge = purgeOnUninstall
        Self.runShell("/usr/bin/killall Liana")
        for path in [userAppPath, systemAppPath] where FileManager.default.fileExists(atPath: path) {
            if path.hasPrefix("/Library") {
                let tmp = NSTemporaryDirectory() + "liana-uninstall.sh"
                try? "#!/bin/bash\nrm -rf \"\(path)\"\n".write(toFile: tmp, atomically: true, encoding: .utf8)
                var error: NSDictionary?
                NSAppleScript(source: "do shell script \"/bin/bash \(tmp)\" with administrator privileges")?
                    .executeAndReturnError(&error)
                if error != nil { append("❌ 系统级卸载失败或已取消") }
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
            append("已移除 \(path)")
        }
        if purge {
            UserDefaults(suiteName: imeBundleID)?.removePersistentDomain(forName: imeBundleID)
            Self.runShell("/usr/bin/security delete-generic-password -s \(imeBundleID) -a userdata-key")
            try? FileManager.default.removeItem(atPath: userDataDir)
            append("已删除用户数据与钥匙串密钥")
        }
        Self.runShell("/usr/bin/killall TextInputMenuAgent imklaunchagent")
        showUninstall = false
        stage = .welcome
        objectWillChange.send()
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 工具

    private func set(_ index: Int, _ state: StepState, detail: String? = nil) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = state
        if let detail {
            steps[index].detail = detail
        }
    }

    private func fail(_ index: Int, _ message: String) {
        set(index, .failed, detail: message)
        failed = true
        append("❌ \(message)")
    }

    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if Thread.isMainThread {
            log.append(trimmed)
        } else {
            DispatchQueue.main.async { self.log.append(trimmed) }
        }
    }

    @discardableResult
    static func runShell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "运行失败: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 界面

struct InstallerRootView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        ZStack {
            InstallerBackdrop()
            Group {
                switch model.stage {
                case .welcome: WelcomeView(model: model)
                case .customize: CustomizeView(model: model)
                case .installing: InstallingView(model: model)
                case .finish: FinishView(model: model)
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                removal: .opacity
            ))
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.stage)
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 28)
        }
        .frame(width: 760, height: 540)
        .sheet(isPresented: $model.showUninstall) {
            UninstallSheet(model: model)
        }
    }
}

/// 柔和的品牌色背景：给玻璃一个有色彩的东西去折射。
struct InstallerBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(brandBlue.opacity(0.35))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: -230, y: -170)
            Circle()
                .fill(pineGreen.opacity(0.32))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: 260, y: 180)
            Circle()
                .fill(Color.purple.opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 80)
                .offset(x: 200, y: -200)
        }
        .ignoresSafeArea()
    }
}

struct WelcomeView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: NSImage(named: "Liana") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: brandBlue.opacity(0.35), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text("松萝")
                    .font(.system(size: 34, weight: .bold))
                Text("越用越懂你的本地输入法")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                FeaturePill(symbol: "lock.shield.fill", title: "零云 · 零遥测", detail: "按键永不离开这台 Mac", color: brandBlue)
                FeaturePill(symbol: "brain.head.profile", title: "知你学习", detail: "常用词进整句解码", color: pineGreen)
                FeaturePill(symbol: "mic.fill", title: "语音与同传", detail: "端上识别，说中出英", color: .pink)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    model.install()
                } label: {
                    Text(model.isInstalled ? "重新安装" : "安装松萝")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 240, height: 30)
                }
                .installerProminent()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                HStack(spacing: 16) {
                    Button("自定义安装…") { model.stage = .customize }
                        .buttonStyle(.link)
                    if model.isInstalled {
                        Button("卸载…") { model.showUninstall = true }
                            .buttonStyle(.link)
                    }
                }
                .font(.system(size: 12))
                Text("推荐设置：仅当前用户 · 全拼 · 隐私优先，无需管理员密码")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if model.signatureIsAdhoc {
                Label("开发版（ad-hoc 签名）：macOS 26 可能不收录，正式版请用 Developer ID 签名包", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeaturePill: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 196, alignment: .leading)
        .installerGlass(cornerRadius: 18)
    }
}

struct CustomizeView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自定义安装")
                .font(.system(size: 24, weight: .bold))
            Text("这些都能在装好后的「松萝设置」里随时修改。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("输入").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("默认输入模式", selection: $model.mode) {
                        ForEach(model.modeOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    Toggle("繁体输出", isOn: $model.traditional)
                    Toggle("所有应用强制半角标点", isOn: $model.halfPunct)
                    Toggle("按应用记忆中 / 英", isOn: $model.appMemory)
                    Divider()
                    Text("安装位置").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $model.systemWide) {
                        Text("仅当前用户").tag(false)
                        Text("所有用户（需管理员）").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .toggleStyle(.switch)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .installerGlass(cornerRadius: 20)

                VStack(alignment: .leading, spacing: 12) {
                    Text("体验与隐私").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Toggle("桌宠", isOn: $model.pet)
                    Toggle("输入统计（仅本地计次）", isOn: $model.stats)
                    Toggle("剪切板历史（加密保存）", isOn: $model.clipboard)
                    Spacer(minLength: 0)
                    Label("内核不发起任何网络请求", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .installerGlass(cornerRadius: 20)
            }
            .frame(height: 300)
            Spacer(minLength: 0)
            HStack {
                Button("返回") { model.stage = .welcome }
                    .installerSecondary()
                Spacer()
                Button {
                    model.install()
                } label: {
                    Text("安装").frame(width: 120)
                }
                .installerProminent()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct InstallingView: View {
    @ObservedObject var model: InstallerModel
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.failed ? "安装没有完成" : "正在安装松萝…")
                .font(.system(size: 24, weight: .bold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.steps) { step in
                    StepRow(step: step)
                    if step.id != model.steps.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .installerGlass(cornerRadius: 20)

            if model.waitingForSystem {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill")
                        .foregroundStyle(brandBlue)
                    Text("等系统收录时，可以先去「键盘设置」添加：文字输入 › 编辑 › + › 中文（简体）› 松萝")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("打开键盘设置") { model.openKeyboardSettings() }
                        .installerSecondary()
                }
                .padding(14)
                .installerGlass(cornerRadius: 16, tint: brandBlue.opacity(0.10))
            }

            DisclosureGroup("详细信息", isExpanded: $showLog) {
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 90)
            }
            .font(.system(size: 12))
            Spacer(minLength: 0)
            if model.failed {
                HStack {
                    Button("返回") { model.stage = .welcome }
                        .installerSecondary()
                    Spacer()
                    Button("重试") { model.install() }
                        .installerProminent()
                }
            }
        }
    }
}

struct StepRow: View {
    let step: InstallStep

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                switch step.state {
                case .pending:
                    Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 13, weight: step.state == .running ? .semibold : .regular))
                    .foregroundStyle(step.state == .pending ? Color.secondary : Color.primary)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

struct FinishView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill((model.registered ? Color.green : Color.orange).opacity(0.16))
                    .frame(width: 92, height: 92)
                Image(systemName: model.registered ? "checkmark" : "hand.raised.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(model.registered ? Color.green : Color.orange)
            }
            Text(model.registered ? "装好了" : "还差最后一步")
                .font(.system(size: 30, weight: .bold))
            Text(model.registered
                 ? "在「键盘设置」里添加松萝后，按 ⌃空格 或 🌐 切换过来就能用。"
                 : (model.steps.last?.detail.isEmpty == false ? model.steps.last!.detail : "系统还没收录松萝，注销重登一次通常就好。"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                TipCard(keys: "⌃ `", title: "功能面板", detail: "截图学习、语音、同传、桌宠")
                TipCard(keys: "⇧", title: "中英切换", detail: "单按左 Shift")
                TipCard(keys: "⌘ ,", title: "松萝设置", detail: "输入法菜单 › 松萝设置")
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("打开键盘设置") { model.openKeyboardSettings() }
                    .installerSecondary()
                    .controlSize(.large)
                if !model.registered {
                    Button("重新检测") { model.recheck() }
                        .installerSecondary()
                        .controlSize(.large)
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("完成").frame(width: 110)
                }
                .installerProminent()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TipCard: View {
    let keys: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 190)
        .installerGlass(cornerRadius: 18)
    }
}

struct UninstallSheet: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("卸载松萝", systemImage: "trash.fill")
                .font(.system(size: 17, weight: .semibold))
            Text("会移除输入法本体。用户词、学习账本默认保留，重新安装后自动恢复。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("同时删除用户数据与钥匙串密钥（无法恢复）", isOn: $model.purgeOnUninstall)
            HStack {
                Spacer()
                Button("取消") { model.showUninstall = false }
                    .keyboardShortcut(.cancelAction)
                Button("卸载", role: .destructive) { model.uninstall() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

// MARK: - 入口

final class InstallerWindowController: NSWindowController {
    let model = InstallerModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "松萝安装器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: InstallerRootView(model: model))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    /// 离屏快照（`LianaInstaller --snapshot <前缀>`），用于开发时检查界面。
    func snapshot(stage: InstallerStage, to path: String) {
        model.stage = stage
        if stage == .installing && model.steps.isEmpty {
            model.steps = [
                InstallStep(id: 0, title: "保存你的设置", state: .done),
                InstallStep(id: 1, title: "复制到 ~/Library/Input Methods", state: .done),
                InstallStep(id: 2, title: "安装 20 万词条词库", state: .running),
                InstallStep(id: 3, title: "注册并启用输入法"),
                InstallStep(id: 4, title: "等待系统收录"),
            ]
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class InstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct InstallerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = InstallerAppDelegate()
        app.delegate = delegate
        let args = CommandLine.arguments
        if args.count > 2, args[1] == "--snapshot" {
            app.setActivationPolicy(.accessory)
            let controller = InstallerWindowController()
            controller.showWindow(nil)
            let stages: [(InstallerStage, String)] = [
                (.welcome, "welcome"), (.customize, "customize"), (.installing, "installing"), (.finish, "finish"),
            ]
            for (stage, name) in stages {
                controller.snapshot(stage: stage, to: "\(args[2])-\(name).png")
            }
            exit(0)
        }
        app.setActivationPolicy(.regular)
        let controller = InstallerWindowController()
        controller.showWindow(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((delegate, controller)) {
            app.run()
        }
    }
}
