import AppKit

/// 复制即动作：复制了一条命令 → 桌宠问要不要在终端运行；复制了链接 → 用浏览器帮你总结 / 翻译 / 截图存档 / 跑站点菜谱。
///
/// - 只在你点了气泡按钮后才做事；危险命令（rm -rf、sudo、curl | sh …）运行前再弹窗确认。
/// - 剪贴板只在内存里判断一次，不记录（与「剪贴板历史」是两回事，后者默认关闭）。
/// - 链接任务用你本机的浏览器（ego lite 优先，Chrome 调试端口兜底），总结 / 翻译用本机模型，不走任何云服务。

// MARK: - 剪贴板识别

final class ClipboardActionWatcher {
    static let shared = ClipboardActionWatcher()
    private static let commandsKey = "LianaClipCommands"
    private static let linksKey = "LianaClipLinks"

    static var commandsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: commandsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: commandsKey); shared.refresh() }
    }

    static var linksEnabled: Bool {
        get { UserDefaults.standard.object(forKey: linksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: linksKey); shared.refresh() }
    }

    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var lastText = ""
    private var lastAt = Date.distantPast
    private let concealed: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "com.agilebits.onepassword", "com.agilebits.onepassword4",
    ]

    /// 输入法自己写剪贴板（回填剪贴板历史等）后调用：这次变化不算「你复制了」
    func ignoreCurrent() {
        lastChange = NSPasteboard.general.changeCount
    }

    func refresh() {
        let on = Self.commandsEnabled || Self.linksEnabled
        if on, timer == nil {
            lastChange = NSPasteboard.general.changeCount
            let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard !(pb.types ?? []).contains(where: { concealed.contains($0.rawValue) }),
              let raw = pb.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return }
        // 同一段内容 30 秒内不重复打扰
        if text == lastText, Date().timeIntervalSince(lastAt) < 30 { return }
        lastText = text
        lastAt = Date()
        if Self.linksEnabled, let url = LinkDetector.detect(text) {
            LinkActions.offer(url)
        } else if Self.commandsEnabled, let command = CommandDetector.detect(text) {
            CommandActions.offer(command)
        }
    }
}

enum LinkDetector {
    /// 整段就是一个 http(s) 链接（不处理夹在句子里的链接）
    static func detect(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), text.count < 2048,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.contains(".") == true else { return nil }
        return url
    }
}

struct DetectedCommand {
    let command: String
    let dangers: [String]
}

enum CommandDetector {
    /// 常见命令行工具（第一个词命中才算命令，避免把普通文字当命令）
    private static let tools: Set<String> = [
        "git", "gh", "npm", "npx", "pnpm", "yarn", "bun", "deno", "node", "brew", "port", "cd", "ls", "ll", "cat",
        "less", "head", "tail", "grep", "rg", "find", "fd", "sed", "awk", "curl", "wget", "python", "python3",
        "pip", "pip3", "pipx", "uv", "uvx", "conda", "poetry", "ruby", "gem", "bundle", "go", "cargo", "rustup",
        "rustc", "swift", "swiftc", "xcodebuild", "xcrun", "xcode-select", "make", "cmake", "docker", "podman",
        "kubectl", "helm", "terraform", "ssh", "scp", "rsync", "sudo", "chmod", "chown", "mkdir", "rmdir", "rm",
        "cp", "mv", "ln", "touch", "open", "echo", "export", "source", "bash", "sh", "zsh", "fish", "defaults",
        "launchctl", "killall", "pkill", "kill", "ps", "top", "htop", "df", "du", "tar", "zip", "unzip", "ffmpeg",
        "java", "mvn", "gradle", "php", "composer", "ollama", "claude", "ego-browser", "code", "vim", "nvim",
        "nano", "which", "whoami", "env", "printenv", "ping", "dig", "nslookup", "lsof", "netstat", "pbcopy",
        "pbpaste", "say", "diskutil", "hdiutil", "codesign", "spctl", "xattr", "softwareupdate", "mas", "jq",
        "tmux", "screen", "watch", "time", "nohup", "apt", "apt-get", "yum", "dnf", "pacman", "systemctl",
        "journalctl", "pm2", "supervisorctl", "mysql", "psql", "redis-cli", "sqlite3", "mongosh", "aws", "gcloud",
        "az", "firebase", "vercel", "netlify", "wrangler", "flutter", "dart", "adb", "fastlane", "pod", "carthage",
    ]

    static func detect(_ text: String) -> DetectedCommand? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        guard !lines.isEmpty, lines.count <= 20 else { return nil }
        // 去掉文档里常见的提示符前缀：「$ 」「% 」「> 」
        lines = lines.map { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            for prompt in ["$ ", "% ", "> ", "❯ "] where l.hasPrefix(prompt) { l.removeFirst(prompt.count) }
            return l
        }
        // 行尾 \ 续行合并后再看第一个词
        let joined = lines.joined(separator: "\n")
        guard let firstLine = lines.first(where: { !$0.hasPrefix("#") }) else { return nil }
        let firstWord = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let word = firstWord.split(separator: "=").count > 1 && firstLine.contains(" ")
            ? String(firstLine.split(separator: " ").dropFirst().first ?? "")   // FOO=bar cmd …
            : firstWord
        let isTool = tools.contains(word.lowercased())
        let isPath = (word.hasPrefix("./") || word.hasPrefix("~/") || word.hasPrefix("/")) && !word.hasSuffix("/")
        guard isTool || isPath else { return nil }
        // 中文为主的一段话不是命令（引号里的中文除外，这里粗略看比例）
        let cjk = joined.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        guard Double(cjk) / Double(max(1, joined.count)) < 0.3 else { return nil }
        return DetectedCommand(command: joined, dangers: dangers(in: joined))
    }

    /// 危险操作：运行前必须再确认一次
    static func dangers(in command: String) -> [String] {
        let c = " " + command.lowercased() + " "
        var found: [String] = []
        func check(_ pattern: String, _ reason: String) {
            if c.range(of: pattern, options: .regularExpression) != nil, !found.contains(reason) { found.append(reason) }
        }
        check(#"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|-r\s+-f|-f\s+-r|--recursive)"#, "递归强制删除文件（rm -rf）")
        check(#"\bsudo\b"#, "以管理员权限运行（sudo）")
        check(#"(curl|wget)[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "下载脚本并直接执行（curl | sh）")
        check(#"\|\s*(sudo\s+)?(ba|z)?sh\b"#, "把内容交给 shell 执行（| sh）")
        check(#"base64\s+(-d|--decode)[^|]*\|"#, "解码隐藏内容后执行（base64 -d |）")
        check(#"\beval\b"#, "动态执行字符串（eval）")
        check(#"\b(mkfs|newfs|diskutil\s+(erase|zero|partition)|dd\s+if=)"#, "格式化或覆写磁盘")
        check(#">\s*/dev/(disk|sd|rdisk)"#, "直接写磁盘设备")
        check(#"\bchmod\s+(-r\s+)?(777|a\+w)"#, "放开所有人的写权限（chmod 777）")
        check(#"\bchown\s+-r\b"#, "递归修改文件归属（chown -R）")
        check(#":\(\)\s*\{"#, "fork 炸弹")
        check(#"\b(shutdown|reboot|halt)\b"#, "关机 / 重启")
        check(#"git\s+push\s+.*(--force|-f\b)"#, "强制推送覆盖远端（git push --force）")
        check(#"git\s+(reset\s+--hard|clean\s+-[a-z]*f)"#, "丢弃本地改动（git reset --hard / clean -f）")
        check(#"xattr\s+-[a-z]*d[a-z]*\s+com\.apple\.quarantine"#, "移除下载隔离标记（绕过 Gatekeeper）")
        check(#"\bosascript\b"#, "执行 AppleScript")
        check(#"\b(launchctl|defaults\s+delete|csrutil|spctl\s+--master-disable)"#, "修改系统服务或安全设置")
        check(#"\bkillall\b|\bpkill\b"#, "结束进程")
        check(#"(~|\$home)/\.(ssh|aws|gnupg)|\bid_rsa\b|keychain"#, "涉及密钥 / 钥匙串")
        return found
    }
}

// MARK: - 终端

enum TerminalLauncher {
    /// 在终端里运行（iTerm2 正在运行就用它，否则用系统「终端」）。需要「自动化」权限（首次会弹系统授权）。
    static func run(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let iTermRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
        let source = iTermRunning
            ? """
              tell application "iTerm"
                  activate
                  set w to (create window with default profile)
                  tell current session of w to write text "\(escaped)"
              end tell
              """
            : """
              tell application "Terminal"
                  activate
                  do script "\(escaped)"
              end tell
              """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
            return "没有权限控制终端：请在系统设置 › 隐私与安全性 › 自动化 里允许「松萝」控制「终端」"
        }
        return (error[NSAppleScript.errorMessage] as? String) ?? "终端启动失败"
    }
}

enum CommandActions {
    static func offer(_ cmd: DetectedCommand) {
        let firstLine = cmd.command.split(separator: "\n").first.map(String.init) ?? cmd.command
        let preview = firstLine.count > 60 ? String(firstLine.prefix(58)) + "…" : firstLine
        let more = cmd.command.contains("\n") ? "（共 \(cmd.command.split(separator: "\n").count) 行）" : ""
        let warning = cmd.dangers.isEmpty ? nil : "⚠️ " + cmd.dangers.joined(separator: "、")
        ActionBubble.shared.show(
            title: cmd.dangers.isEmpty ? "复制了一条命令\(more)" : "复制了一条有风险的命令\(more)",
            detail: preview,
            warning: warning,
            actions: [
                ("在终端运行", { run(cmd) }),
                ("取消", {}),
            ]
        )
        PetWindowController.shared.clipNoticed(emote: cmd.dangers.isEmpty ? "⌨️" : "⚠️")
    }

    private static func run(_ cmd: DetectedCommand) {
        if !cmd.dangers.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "这条命令有风险，确定要运行吗？"
            alert.informativeText = cmd.dangers.map { "• " + $0 }.joined(separator: "\n")
                + "\n\n只运行你信任的来源给出的命令；网页可能把恶意命令偷偷放进剪贴板。\n\n" + cmd.command.prefix(800)
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "仍然运行")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if let error = TerminalLauncher.run(cmd.command) {
            PetWindowController.shared.notify("notify_error")
            PetWindowController.shared.showToast(error, duration: 6)
        }
    }
}

// MARK: - 气泡（带按钮）

/// 桌宠旁边的操作气泡：几个按钮，点了才做事；10 秒不理会自动收起。
final class ActionBubble {
    static let shared = ActionBubble()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
    }

    private var panel: Panel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, detail: String?, warning: String?, actions: [(String, () -> Void)], timeout: TimeInterval = 10) {
        hide()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        var rows: [NSView] = [titleLabel]
        if let detail {
            let d = NSTextField(labelWithString: detail)
            d.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            d.textColor = .secondaryLabelColor
            d.lineBreakMode = .byTruncatingTail
            d.preferredMaxLayoutWidth = 280
            rows.append(d)
        }
        if let warning {
            let w = NSTextField(wrappingLabelWithString: warning)
            w.font = .systemFont(ofSize: 11)
            w.textColor = .systemRed
            w.preferredMaxLayoutWidth = 280
            rows.append(w)
        }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        for (index, action) in actions.enumerated() {
            let button = ClosureButton(title: action.0) { [weak self] in
                self?.hide()
                action.1()
            }
            button.bezelStyle = .rounded
            button.controlSize = .small
            if index == 0 { button.keyEquivalent = "\r" }
            buttons.addArrangedSubview(button)
        }
        rows.append(buttons)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        let size = stack.fittingSize
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        box.frame = NSRect(origin: .zero, size: size)
        panel.contentView = box
        panel.setFrameOrigin(anchor(for: size))
        panel.orderFrontRegardless()
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    /// 桌宠在就放它旁边，不在就放鼠标附近
    private func anchor(for size: NSSize) -> NSPoint {
        if let pet = PetWindowController.shared.petFrame {
            let screen = (NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main)?.visibleFrame ?? pet
            var x = pet.minX - size.width - 8
            if x < screen.minX + 8 { x = pet.maxX + 8 }
            let y = min(max(pet.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)
            return NSPoint(x: x, y: y)
        }
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: size)
        return NSPoint(x: min(max(mouse.x + 12, screen.minX + 8), screen.maxX - size.width - 8),
                       y: min(max(mouse.y - size.height - 12, screen.minY + 8), screen.maxY - size.height - 8))
    }
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func fire() { handler() }
}

// MARK: - 链接任务

/// 站点菜谱：按域名匹配，在页面里运行一段 JS（返回字符串或 JSON），ego lite 和 Chrome 都能跑。
/// 放在 ~/Library/Application Support/Liana/link-recipes/*.json，只在你点了按钮后运行。
struct LinkRecipe: Codable {
    var name: String
    /// 域名：`example.com` 匹配它和所有子域；`*` 匹配所有
    var match: [String]
    /// 在页面里执行的 JS 表达式（可返回 Promise）
    var script: String
    /// 打开后等多久再执行（毫秒）
    var waitMs: Int?

    func matches(_ host: String) -> Bool {
        let h = host.lowercased()
        return match.contains { m in
            let d = m.lowercased().replacingOccurrences(of: "*.", with: "")
            return d == "*" || h == d || h.hasSuffix("." + d)
        }
    }
}

enum LinkRecipeStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liana/link-recipes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func recipes(for url: URL) -> [LinkRecipe] {
        guard let host = url.host,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(LinkRecipe.self, from: $0) }
        }.filter { $0.matches(host) }
    }

    /// 第一次打开菜谱目录时放一个示例，照着改就行
    static func openFolder() {
        let sample = dir.appendingPathComponent("示例-页面里的所有标题.json")
        if !FileManager.default.fileExists(atPath: sample.path) {
            let recipe = LinkRecipe(
                name: "列出页面里的所有标题",
                match: ["example.com"],
                script: "Array.from(document.querySelectorAll('h1,h2,h3')).map(h => h.innerText.trim()).filter(Boolean).join('\\n')",
                waitMs: 1500
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try? encoder.encode(recipe).write(to: sample)
        }
        NSWorkspace.shared.open(dir)
    }
}

struct PageResult {
    var title = ""
    var text = ""
    var screenshot: String?
    var scriptResult: String?
}

struct PageRequest {
    var url: URL
    var wantText = false
    var screenshotPath: String?
    var script: String?
    var waitMs = 1200
}

/// 正文提取：优先 <article>，其次 <main>，最后整个 body
private let extractTextJS = """
(() => { const n = document.querySelector('article') || document.querySelector('main') || document.body; \
return (n ? n.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 20000); })()
"""

enum BrowserRunner {
    /// ego lite 优先（带你的登录状态），没有就连 Chrome 的调试端口
    static func run(_ request: PageRequest, completion: @escaping (Result<PageResult, Error>) -> Void) {
        if let ego = EgoDriver.executable() {
            EgoDriver.run(request, executable: ego) { result in
                if case .failure = result {
                    ChromeCDPDriver.run(request) { fallback in
                        // 两个都失败时报 ego 的错误（它是首选）
                        if case .failure = fallback { completion(result) } else { completion(fallback) }
                    }
                } else {
                    completion(result)
                }
            }
        } else {
            ChromeCDPDriver.run(request, completion: completion)
        }
    }
}

enum BrowserError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// ego lite：通过 `ego-browser nodejs` 跑一段脚本（独立的任务空间，不动你正在用的标签页）。
enum EgoDriver {
    static func executable() -> String? {
        let candidates = [NSHomeDirectory() + "/.local/bin/ego-browser", "/opt/homebrew/bin/ego-browser", "/usr/local/bin/ego-browser"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ request: PageRequest, executable: String, completion: @escaping (Result<PageResult, Error>) -> Void) {
        func js(_ value: Any?) -> String {
            guard let value else { return "null" }
            let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[null]"
            return String(text.dropFirst().dropLast())
        }
        let script = """
        let task;
        try { task = await taskSpace("liana-link"); } catch (e) { task = await taskSpace("liana-link-" + Date.now()); }
        const page = task.page("p1");
        await page.goto(\(js(request.url.absoluteString)));
        await page.waitForTimeout(\(request.waitMs));
        const title = await page.title();
        const text = \(request.wantText) ? await page.evaluate(\(js(extractTextJS))) : "";
        let shot = null;
        if (\(js(request.screenshotPath)) !== null) shot = await page.screenshot({ path: \(js(request.screenshotPath)), fullPage: true });
        let result = null;
        if (\(js(request.script)) !== null) { result = await page.evaluate(\(js(request.script))); }
        if (result !== null && typeof result !== "string") result = JSON.stringify(result, null, 2);
        console.log("__LIANA__" + JSON.stringify({ title, text, shot, result }));
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = ["nodejs"]
            // ego-browser 把脚本输出写在 stderr：两路合进同一根管子读，也避免分开读时缓冲区写满卡死
            let input = Pipe(), output = Pipe()
            proc.standardInput = input
            proc.standardOutput = output
            proc.standardError = output
            do { try proc.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            input.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
            try? input.fileHandleForWriting.close()
            // 90 秒超时
            let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            killer.cancel()
            let text = String(data: data, encoding: .utf8) ?? ""
            let result: Result<PageResult, Error>
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__LIANA__") }),
               let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("__LIANA__".count).utf8)) as? [String: Any] {
                result = .success(PageResult(title: json["title"] as? String ?? "", text: json["text"] as? String ?? "",
                                             screenshot: json["shot"] as? String, scriptResult: json["result"] as? String))
            } else {
                let all = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                let reason = all.first { $0.contains("Error") } ?? all.last.map { "ego lite：" + $0.prefix(160) }
                    ?? "ego lite 没有返回结果（是否已打开 ego lite？）"
                result = .failure(BrowserError.message(reason))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Chrome DevTools Protocol：连本机 127.0.0.1:9222。没开调试端口时，用单独的配置目录启动一个（不碰你日常的 Chrome 配置）。
enum ChromeCDPDriver {
    private static let port = 9222

    static func run(_ request: PageRequest, completion: @escaping (Result<PageResult, Error>) -> Void) {
        Task {
            let result: Result<PageResult, Error>
            do { result = .success(try await perform(request)) } catch { result = .failure(error) }
            await MainActor.run { completion(result) }
        }
    }

    private static func perform(_ request: PageRequest) async throws -> PageResult {
        if !(await reachable()) {
            try launchChrome()
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await reachable() { break }
            }
            guard await reachable() else { throw BrowserError.message("没找到 ego lite，Chrome 调试端口也没打开") }
        }
        // 新开一个标签页做任务，做完关掉
        var newURL = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json/new?\(request.url.absoluteString)")!)
        newURL.httpMethod = "PUT"
        let (data, _) = try await URLSession.shared.data(for: newURL)
        guard let target = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ws = (target["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)),
              let targetId = target["id"] as? String else { throw BrowserError.message("Chrome 没有返回标签页") }
        let session = CDPSession(url: ws)
        defer {
            session.close()
            Task { _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/close/\(targetId)")!) }
        }
        try await Task.sleep(nanoseconds: UInt64(max(800, request.waitMs + 1500)) * 1_000_000)
        var result = PageResult()
        result.title = try await session.evaluate("document.title") as? String ?? ""
        if request.wantText { result.text = try await session.evaluate(extractTextJS) as? String ?? "" }
        if let path = request.screenshotPath {
            let metrics = try await session.send("Page.getLayoutMetrics")
            let size = (metrics["cssContentSize"] ?? metrics["contentSize"]) as? [String: Any]
            let width = size?["width"] as? Double ?? 1280, height = min(size?["height"] as? Double ?? 2000, 16000)
            let shot = try await session.send("Page.captureScreenshot", [
                "format": "png", "captureBeyondViewport": true,
                "clip": ["x": 0, "y": 0, "width": width, "height": height, "scale": 1],
            ])
            if let b64 = shot["data"] as? String, let png = Data(base64Encoded: b64) {
                try png.write(to: URL(fileURLWithPath: path))
                result.screenshot = path
            }
        }
        if let script = request.script {
            let value = try await session.evaluate(script)
            if let s = value as? String { result.scriptResult = s } else if let value,
               let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed]) {
                result.scriptResult = String(data: d, encoding: .utf8)
            }
        }
        return result
    }

    private static func reachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    private static func launchChrome() throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw BrowserError.message("没找到 ego lite，也没装 Chrome")
        }
        let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liana/chrome-cdp", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--remote-debugging-port=\(port)", "--user-data-dir=\(profile.path)", "--no-first-run"]
        NSWorkspace.shared.openApplication(at: app, configuration: config)
    }
}

/// 极简 CDP 会话：按 id 收发 JSON-RPC。
private final class CDPSession {
    private let task: URLSessionWebSocketTask
    private var nextId = 0

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextId += 1
        let id = nextId
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await task.send(.string(String(data: body, encoding: .utf8) ?? "{}"))
        while true {
            let message = try await task.receive()
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  json["id"] as? Int == id else { continue }   // 跳过事件和别的回包
            if let error = json["error"] as? [String: Any] {
                throw BrowserError.message(error["message"] as? String ?? "CDP 出错")
            }
            return json["result"] as? [String: Any] ?? [:]
        }
    }

    func evaluate(_ expression: String) async throws -> Any? {
        let r = try await send("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true])
        return (r["result"] as? [String: Any])?["value"]
    }
}

// MARK: - 链接动作

enum LinkActions {
    static func offer(_ url: URL) {
        var actions: [(String, () -> Void)] = [
            ("总结", { summarize(url) }),
            ("翻译", { translate(url) }),
            ("截图存档", { archive(url) }),
        ]
        for recipe in LinkRecipeStore.recipes(for: url).prefix(3) {
            actions.append((recipe.name, { runRecipe(recipe, url) }))
        }
        ActionBubble.shared.show(title: "复制了链接 · \(url.host ?? "")", detail: nil, warning: nil, actions: actions)
        PetWindowController.shared.clipNoticed(emote: "🔗")
    }

    private static func start(_ what: String) {
        PetWindowController.shared.linkTaskStarted(what)
    }

    static func summarize(_ url: URL) {
        start("我去看看这个网页…")
        BrowserRunner.run(PageRequest(url: url, wantText: true)) { result in
            switch result {
            case .failure(let error): fail(error)
            case .success(let page):
                guard !page.text.isEmpty else { return fail(BrowserError.message("这个页面没有可读的正文")) }
                withLocalModel(
                    system: "用简体中文把下面的网页总结成 3 条要点，每条不超过 30 个字，再用一句话说这页对读者有什么用。只输出要点。",
                    user: "标题：\(page.title)\n\n\(page.text.prefix(6000))", maxTokens: 320,
                    noModel: "没有本机模型，先给你开头：\n" + page.text.prefix(200)
                ) { summary in
                    finish(title: "「\(page.title.prefix(30))」要点", body: summary, url: url, text: page.text)
                }
            }
        }
    }

    static func translate(_ url: URL) {
        start("我去把它翻成中文…")
        BrowserRunner.run(PageRequest(url: url, wantText: true)) { result in
            switch result {
            case .failure(let error): fail(error)
            case .success(let page):
                guard !page.text.isEmpty else { return fail(BrowserError.message("这个页面没有可读的正文")) }
                withLocalModel(
                    system: "把下面的网页正文完整翻译成通顺的简体中文，保留段落，不要省略，不要解释。",
                    user: String(page.text.prefix(3500)), maxTokens: 1800,
                    noModel: "没有本机模型，没法翻译（在设置 › AI 里下载一个模型就可以了）"
                ) { translation in
                    finish(title: "「\(page.title.prefix(30))」译文", body: translation, url: url, text: page.text)
                }
            }
        }
    }

    static func archive(_ url: URL) {
        start("截图存档中…")
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let safeHost = (url.host ?? "page").replacingOccurrences(of: "/", with: "-")
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("松萝存档/\(df.string(from: Date()))-\(safeHost)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = folder.appendingPathComponent("page.png").path
        BrowserRunner.run(PageRequest(url: url, wantText: true, screenshotPath: shot)) { result in
            switch result {
            case .failure(let error): fail(error)
            case .success(let page):
                let markdown = "# \(page.title)\n\n来源：\(url.absoluteString)\n存档时间：\(Date())\n\n\(page.text)\n"
                try? markdown.write(to: folder.appendingPathComponent("正文.md"), atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("page.png")])
                PetWindowController.shared.linkTaskFinished(ok: true, line: "存好啦：截图和正文都在「下载/松萝存档」")
            }
        }
    }

    static func runRecipe(_ recipe: LinkRecipe, _ url: URL) {
        start("按菜谱「\(recipe.name)」处理中…")
        BrowserRunner.run(PageRequest(url: url, script: recipe.script, waitMs: recipe.waitMs ?? 1200)) { result in
            switch result {
            case .failure(let error): fail(error)
            case .success(let page):
                let body = (page.scriptResult ?? "（菜谱没有返回内容）").prefix(3000)
                finish(title: recipe.name, body: String(body), url: url, text: nil)
            }
        }
    }

    private static func withLocalModel(system: String, user: String, maxTokens: Int, noModel: String,
                                       completion: @escaping (String) -> Void) {
        guard TranslateClient.findRuntime() != nil, TranslateClient.translateModelPath() != nil else {
            return completion(noModel)
        }
        TranslateClient.shared.chat(system: system, user: user, maxTokens: maxTokens) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text): completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
                case .failure(let error): completion("本机模型出错：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func finish(title: String, body: String, url: URL, text: String?) {
        PetWindowController.shared.linkTaskFinished(ok: true, line: nil)
        PetChatController.shared.present(title: title, body: body)
        if let text, !text.isEmpty {
            ActionBubble.shared.show(title: "要把这页的术语喂给输入法吗？", detail: nil, warning: nil, actions: [
                ("喂给营养库", { FeedWindowController.shared.show(text: String(text.prefix(20000)), source: url.host ?? url.absoluteString) }),
                ("不用", {}),
            ], timeout: 12)
        }
    }

    private static func fail(_ error: Error) {
        PetWindowController.shared.linkTaskFinished(ok: false, line: "没办成：\(error.localizedDescription)")
    }
}
