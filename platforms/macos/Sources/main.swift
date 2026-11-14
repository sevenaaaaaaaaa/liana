import AppKit
import SwiftUI
import Carbon
import InputMethodKit

// MARK: - 安装辅助命令（注册 / 启用 / 选择 / 状态）
// 与 Squirrel 相同的做法：由输入法自身调用 TIS API，安装后无需注销即可被系统发现。

private func inputSourceID() -> String {
    Bundle.main.bundleIdentifier ?? "dev.liana.inputmethod.ime"
}

private func findInputSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    let prefix = inputSourceID()
    return list.filter { source in
        let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        guard let id = unsafeBitCast(idRef, to: CFString?.self) as String? else { return false }
        return id == prefix || id.hasPrefix(prefix + ".")
    }
}

private func findInputSource() -> TISInputSource? {
    let sources = findInputSources()
    return sources.first { boolProperty($0, kTISPropertyInputSourceIsSelectCapable) == true
        && boolProperty($0, kTISPropertyInputSourceIsEnabled) == true }
        ?? sources.first { boolProperty($0, kTISPropertyInputSourceIsSelectCapable) == true }
        ?? sources.first
}

private func sourceIdentifier(_ source: TISInputSource) -> String {
    let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    return (unsafeBitCast(idRef, to: CFString?.self) as String?) ?? inputSourceID()
}

private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
    guard let ref = TISGetInputSourceProperty(source, key) else { return nil }
    return unsafeBitCast(ref, to: CFBoolean?.self).map(CFBooleanGetValue)
}

private func describe(_ source: TISInputSource) -> String {
    let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
    let selectable = boolProperty(source, kTISPropertyInputSourceIsSelectCapable) ?? false
    let selected = boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
    return "\(sourceIdentifier(source)) enabled=\(enabled) selectable=\(selectable) selected=\(selected)"
}

private var registrationPolicy: InputSourceRegistration {
    InputSourceRegistration(bundleID: inputSourceID(), modeIDs: InputSourceRegistration.declaredModes(
        in: Bundle.main.infoDictionary ?? [:], bundleID: inputSourceID()))
}

private let hbDomain = "com.apple.HIToolbox"
private let hbKey = "AppleEnabledInputSources"
private let tpDomain = "com.apple.inputsources"
private let tpKey = "AppleEnabledThirdPartyInputSources"

private func registrationRows(_ domain: String, _ key: String) throws -> [[String: Any]] {
    guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return [] }
    guard let rows = value as? [[String: Any]] else {
        throw NSError(domain: "Liana.Install", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "系统输入源表格式异常，未修改：" + domain])
    }
    return rows
}

private func isInstalledInputMethod() -> Bool {
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    return installedAppCopies().contains(path)
}

private func requireInstalledInputMethod() throws {
    guard isInstalledInputMethod(), installedAppCopies().count == 1 else {
        throw NSError(domain: "Liana.Install", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "注册仅允许从唯一已安装副本执行；请使用安装器，不能注册构建目录或 DMG 中的副本。"])
    }
}

/// 唯一写入入口。系统 API 的 noErr 不代表持久化成功，必须核对两张表。
@discardableResult
private func normalizeInputSourcePersistence(enable: Bool?) throws -> Bool {
    let policy = registrationPolicy
    let hb = try registrationRows(hbDomain, hbKey)
    let tp = try registrationRows(tpDomain, tpKey)
    let enabled = enable ?? policy.hasModeRegistration(hitoolbox: hb, thirdParty: tp)
    let result = policy.normalize(hitoolbox: hb, thirdParty: tp, enabled: enabled)
    guard result.changed else { return false }
    let fm = FileManager.default
    let backup = fm.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/Liana/InstallBackups/registration-" + UUID().uuidString)
    try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for (name, rows) in [(hbDomain, hb), (tpDomain, tp)] {
        let file = backup.appendingPathComponent(name + ".plist")
        try PropertyListSerialization.data(fromPropertyList: rows, format: .xml, options: 0).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func write(_ rows: [[String: Any]], _ domain: String, _ key: String) {
        CFPreferencesSetAppValue(key as CFString, rows as CFArray, domain as CFString)
        _ = CFPreferencesAppSynchronize(domain as CFString)
    }
    // CFPreferencesAppSynchronize 的返回值只是"已提交"的提示，系统侧仍会重排数组；
    // 成败只看回读内容，并且按无序比较：macOS 会把模式行持久化在容器行之前。
    write(result.thirdParty, tpDomain, tpKey)
    write(result.hitoolbox, hbDomain, hbKey)
    let hitoolboxBelongs = InputSourceRegistration.equalIgnoringOrder(
        try registrationRows(hbDomain, hbKey), result.hitoolbox)
    let thirdPartyBelongs = InputSourceRegistration.equalIgnoringOrder(
        try registrationRows(tpDomain, tpKey), result.thirdParty)
    guard hitoolboxBelongs, thirdPartyBelongs else {
        write(tp, tpDomain, tpKey)
        write(hb, hbDomain, hbKey)
        throw NSError(domain: "Liana.Install", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "输入源持久化校验失败，已尝试恢复；备份：" + backup.path])
    }
    print("已统一输入源注册：第三方表保留唯一容器与声明模式，移除跨表及旧 ID 注册。")
    print("注册备份：" + backup.path)
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil,
        userInfo: nil, deliverImmediately: true)
    return true
}

// MARK: - 安装自检（--verify-install）
// 首次安装出问题的地方几乎都在这里：同一 bundle 装了两份（~/Library 与 /Library）、
// 注册被写进两张表导致菜单出现两条同名条目、启用后没人告诉用户怎么切过去。
// 这个自检把这四件事各自判一次并给出下一步，安装脚本/安装器都以它收尾。

private func installedAppCopies() -> [String] {
    let roots = [NSHomeDirectory() + "/Library/Input Methods", "/Library/Input Methods"]
    return roots.flatMap { root -> [String] in
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return apps.filter { $0.hasSuffix(".app") }.compactMap { name in
            let url = URL(fileURLWithPath: root).appendingPathComponent(name)
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  registrationPolicy.managedBundleIDs.contains(id) else { return nil }
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }.sorted()
}

private func menuVisibleCount() -> Int {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return 0 }
    return list.filter { source in
        (unsafeBitCast(TISGetInputSourceProperty(source, kTISPropertyBundleID), to: CFString?.self) as String?) == inputSourceID()
        && boolProperty(source, kTISPropertyInputSourceIsSelectCapable) == true
        && boolProperty(source, kTISPropertyInputSourceIsEnabled) == true
    }.count
}

@discardableResult
private func runInstallCheck() -> Bool {
    let bid = inputSourceID()
    var hardOK = true
    func line(_ ok: Bool, _ title: String, _ detail: String, hint: String? = nil) {
        print("\(ok ? "✓" : "✗") \(title)：\(detail)")
        if !ok, let hint { print("   → \(hint)") }
    }

    print("松萝（Liana）安装自检 · bundle \(bid)")
    print("────────────────────────────────────────")

    // 1. 副本唯一性：两份 = 系统会枚举两遍，菜单出现两条
    let copies = installedAppCopies()
    line(copies.count == 1, "安装副本", copies.isEmpty ? "未找到" :
        (copies.count == 1 ? copies[0] : "\(copies.count) 份（\(copies.joined(separator: " + "))）"),
        hint: "同一个输入法装两份会让系统出现两条同名条目：删掉多余那份（/Library 下的需要管理员权限）")
    if copies.count != 1 { hardOK = false }

    // 容器/模式是正常的两条记录，但整个声明只能持久化在一个来源。
    do {
        let hb = try registrationRows(hbDomain, hbKey)
        let tp = try registrationRows(tpDomain, tpKey)
        let canonical = registrationPolicy.isCanonical(hitoolbox: hb, thirdParty: tp)
        line(canonical, "持久化唯一性", "HIToolbox \(hb.filter(registrationPolicy.owns).count) 条 + 第三方表 \(tp.filter(registrationPolicy.owns).count) 条",
             hint: "执行已安装程序的 --repair-input-source；容器跨表重复同样是错误，不能忽略")
        if !canonical { hardOK = false }
    } catch {
        line(false, "持久化唯一性", error.localizedDescription)
        hardOK = false
    }

    // 3. 系统可选模式；界面还可能持有旧缓存，不能仅凭此项断言菜单没有重复。
    let visible = menuVisibleCount()
    line(visible == 1, "系统可选输入模式", "\(visible) 条「松萝」", hint: "执行已安装程序的 --repair-input-source，并刷新输入法菜单后复核")
    if visible != 1 { hardOK = false }

    let enabledSources = (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    let historical = enabledSources.filter { source in
        guard let ref = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return false }
        let id = unsafeBitCast(ref, to: CFString.self) as String
        return id != bid && registrationPolicy.managedBundleIDs.contains(id)
    }
    line(historical.isEmpty, "旧版输入源", "\(historical.count) 条")
    if !historical.isEmpty { hardOK = false }
    if !registrationPolicy.modeIDs.isEmpty {
        let parent = findInputSources().first { sourceIdentifier($0) == bid }
        let enabled = parent.map { boolProperty($0, kTISPropertyInputSourceIsEnabled) == true } ?? false
        line(enabled, "容器启用状态", "enabled=\(enabled)")
        if !enabled { hardOK = false }
    }

    // 4. 启用 / 可选中 / 当前是否已选中
    if let source = findInputSource() {
        let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
        let selectable = boolProperty(source, kTISPropertyInputSourceIsSelectCapable) ?? false
        let selected = boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
        line(enabled && selectable, "注册状态", "enabled=\(enabled) selectable=\(selectable)",
             hint: "跑一次 `--enable-input-source`")
        if !(enabled && selectable) { hardOK = false }
        if !selected {
            print("ℹ 当前未选中松萝：点右上角输入法图标选「松萝」，或按 Control + 空格 切换")
        }
    } else {
        line(false, "注册状态", "系统未收录", hint: "跑 `--register-input-source`，仍不行则注销重登")
        hardOK = false
    }

    // 5. 数据目录（不影响启用，只是确认用户词/桌宠没丢）
    let dataDir = NSHomeDirectory() + "/Library/Application Support/Liana"
    let hasData = FileManager.default.fileExists(atPath: dataDir + "/userdata.enc")
    print("\(hasData ? "✓" : "·") 本地数据：\(hasData ? "userdata.enc 就位（\(dataDir)）" : "尚未创建（首次输入后生成）")")

    print("────────────────────────────────────────")
    if hardOK {
        print("结果：安装注册自检通过。请在刷新后的菜单确认仅一条「松萝」，再切换输入。")
    } else {
        print("结果：需要修复，按上面带 → 的提示逐条处理。")
    }
    return hardOK
}

// 卸载用：把本输入法从 TIS 与两张注册表里一起清掉，避免卸载后菜单里还挂着一条死条目
// （用户下次看到「松萝」却切不过去，比看不到更困惑）。
private func removeInputSourcePersistence() -> Bool {
    do {
        try requireInstalledInputMethod()
        for source in findInputSources() { _ = TISDisableInputSource(source) }
        _ = try normalizeInputSourcePersistence(enable: false)
        return true
    } catch { print(error.localizedDescription); return false }
}

// 全新安装（还没有用户数据）时把自己切到前台：新用户装完第一次运行就能直接打拼音，
// 不用先去右上角菜单里找「松萝」。已有数据的老用户不动——升级时抢走当前输入法很讨厌。
private func selectSelfIfFreshInstall(isFresh: Bool) {
    guard isFresh, let source = findInputSource(),
          boolProperty(source, kTISPropertyInputSourceIsEnabled) == true else { return }
    guard boolProperty(source, kTISPropertyInputSourceIsSelected) != true else { return }
    // 等 IMKServer 起来再切，否则系统可能还没把它当成可用输入法
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        let status = TISSelectInputSource(source)
        NSLog("松萝: 首次安装，已自动切换到松萝 (status=\(status))")
    }
}

let installArgs = CommandLine.arguments
if installArgs.count > 1 {
    switch installArgs[1] {
    case "--update-check":
        // 开发用：检查更新（不下载）；--nightly 同时看 Nightly
        LianaUpdater.includeNightly = installArgs.contains("--nightly")
        print("当前版本 \(LianaUpdater.currentVersion)")
        LianaUpdater.check { result in
            switch result {
            case .success(let release?):
                print("有更新：\(release.version) \(release.dmg.lastPathComponent) \(release.size) 字节")
                if installArgs.contains("--install") {
                    LianaUpdater.install(release, progress: { _ in }, completion: { result in
                        switch result {
                        case .success(.installed(let v)): print("已安装 \(v)")
                        case .success(.manual(let reason)): print(reason)
                        case .failure(let error): print("安装失败：\(error.localizedDescription)")
                        }
                        exit(0)
                    })
                    return
                }
            case .success(nil): print("已是最新")
            case .failure(let error): print("失败：\(error.localizedDescription)")
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)

    case "--rerank-test":
        // 开发用：按输入法的真实链路（解码 → 整句候选 → 本机模型打分）跑几串按键，打印重排结果与耗时
        let inputs = Array(installArgs.dropFirst(2))
        var index = 0
        func next() {
            guard index < inputs.count else { exit(0) }
            let keys = inputs[index]
            index += 1
            let engine = LianaEngine(mode: "pinyin")
            for ch in keys { _ = engine.feed(ch) }
            let comp = engine.composition
            let sentences = comp.candidates.prefix(5).filter { $0.kind == "sentence" }.map(\.text)
            let started = Date()
            SentenceRerank.pick(sentences) { best in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let picked = best.map { sentences[$0] } ?? "（不可用）"
                print("\(keys)：\(sentences.joined(separator: " / ")) → \(picked)（\(ms)ms）")
                next()
            }
        }
        DispatchQueue.main.async { next() }
        NSApplication.shared.run()
        exit(0)

    case "--engine-query":
        // 开发用：走和输入法相同的加载路径（base.ifd + base.lm + dicts/ 词包），打印每串按键的前 5 个候选
        for keys in installArgs.dropFirst(2) {
            let engine = LianaEngine(mode: "pinyin")
            let started = Date()
            for ch in keys { _ = engine.feed(ch) }
            let top = engine.composition.candidates.prefix(5).map(\.text).joined(separator: " / ")
            print("\(keys)（\(Int(Date().timeIntervalSince(started) * 1000))ms）: \(top)")
        }
        exit(0)

    case "--app-names":
        // 开发用：列出本机应用名词包会收录的名字
        let names = AppNameLexicon.collectNames().sorted()
        print(names.joined(separator: " "))
        print("共 \(names.count) 个")
        exit(0)

    case "--register-input-source", "--repair-input-source", "--enable-input-source", "--dedupe-input-source":
        do {
            try requireInstalledInputMethod()
            let command = installArgs[1]
            if command == "--register-input-source" || command == "--repair-input-source" {
                let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
                guard status == noErr else { print("注册失败 (status=\(status))"); exit(1) }
            }
            func hasNativeModeRegistration() throws -> Bool {
                try registrationPolicy.hasModeRegistration(hitoolbox: registrationRows(hbDomain, hbKey),
                    thirdParty: registrationRows(tpDomain, tpKey))
            }
            if command == "--repair-input-source" || command == "--enable-input-source", try !hasNativeModeRegistration() {
                // 给原生 API 留出主线程事件处理时间；noErr 不能替代实际持久化证据。
                _ = NSApplication.shared
                for selectable in [false, true] {
                    for source in findInputSources() where (boolProperty(source, kTISPropertyInputSourceIsSelectCapable) == true) == selectable {
                        _ = TISEnableInputSource(source)
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
                guard try hasNativeModeRegistration() else {
                    print("程序已安装，但系统尚未原生启用。请在键盘设置 → 输入法 → 编辑 → + → 简体中文 → 松萝中添加。")
                    print("未补写启用记录，避免产生幽灵输入源；原生添加后重新运行 --verify-install-stable。")
                    exit(2)
                }
            }
            // 只整理已有启用证据，不会把全新安装或已移除的输入法强行写成启用。
            let changed = try normalizeInputSourcePersistence(enable: nil)
            print(changed ? "输入源已修复" : "注册未新增，本次无需归一处理")
            exit(0)
        } catch { print(error.localizedDescription); exit(1) }

    case "--verify-install-stable":
        for attempt in 1...3 {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--verify-install"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { print(error.localizedDescription); exit(1) }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            print("独立进程检查 \(attempt)/3")
            if attempt == 3 || process.terminationStatus != 0 {
                print(String(data: output, encoding: .utf8) ?? "")
            }
            guard process.terminationStatus == 0 else { exit(1) }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
        }
        exit(0)

    case "--verify-install":
        // 首次使用的四个断点一次跑完：副本是否唯一、注册是否双写、菜单是否两条、是否已启用
        exit(runInstallCheck() ? 0 : 1)

    case "--remove-input-source":
        exit(removeInputSourcePersistence() ? 0 : 1)

    case "--select-input-source":
        guard let source = findInputSource(), boolProperty(source, kTISPropertyInputSourceIsEnabled) == true else {
            print("输入源未启用，请先 --enable-input-source")
            exit(1)
        }
        if boolProperty(source, kTISPropertyInputSourceIsSelected) == true {
            print("已选中")
            exit(0)
        }
        let status = TISSelectInputSource(source)
        print(status == noErr ? "已切换到松萝" : "切换失败 (status=\(status))")
        exit(status == noErr ? 0 : 1)

    case "--input-source-status":
        guard let source = findInputSource() else {
            print("未注册")
            exit(1)
        }
        print("\(inputSourceID()) \(describe(source))")
        exit(0)

    case "--ai-dump":
        for model in LianaEngine.aiCatalog() {
            print(
                "\(model.id)\t\(model.sizeBytes)\t\(model.ramMb)MB\t\(model.kinds.joined(separator: ","))\t\(model.license)"
            )
        }
        let ramMb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let rec = LianaEngine.aiRecommend(totalRamMb: ramMb)
        print("totalRamMb=\(rec.totalRamMb)")
        for r in rec.recommendations {
            print("\(r.kind)\t\(r.modelId ?? "-")\t\(r.levelLabel)")
        }
        exit(0)

    case "--backup-smoke":
        exit(BackupManager.smokeTest() ? 0 : 1)

    case "--store-smoke":
        exit(EncryptedStore.smokeTest() ? 0 : 1)

    case "--candidate-demo":
        let demoEngine = LianaEngine(mode: "pinyin")
        for ch in "nihao" { _ = demoEngine.feed(ch) }
        let comp = demoEngine.composition
        let demoWindow = CandidateWindowController()
        demoWindow.present(
            candidates: comp.candidates,
            page: 0,
            near: NSRect(x: 300, y: 300, width: 2, height: 18),
            onPick: { _ in }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/candidate-demo.png"
        demoWindow.snapshot(to: out)
        print("候选数=\(comp.candidates.count)，已渲染: \(out)")
        exit(0)

    case "--layout-diag":
        // 布局诊断：候选格实际 frame vs 文本 intrinsic（找省略号截断根因）
        let demoWindow = CandidateWindowController()
        var cands: [Candidate] = [
            Candidate(text: "省略", consumed: 6, kind: "word", comment: nil),
            Candidate(text: "省", consumed: 3, kind: "char", comment: "sheng"),
            Candidate(text: "省略号", consumed: 9, kind: "word", comment: "sheng lve hao"),
            Candidate(text: "生了", consumed: 6, kind: "word", comment: "sheng le"),
            Candidate(text: "过程", consumed: 4, kind: "word", comment: "guo cheng"),
            Candidate(text: "输入", consumed: 4, kind: "word", comment: "shu ru"),
            Candidate(text: "这是一个比较长的候选用来压宽度", consumed: 15, kind: "sentence", comment: "zhe shi yi ge bi jiao chang de hou xuan"),
            Candidate(text: "好", consumed: 2, kind: "char", comment: nil),
            Candidate(text: "的", consumed: 2, kind: "char", comment: "de"),
        ]
        demoWindow.present(
            candidates: cands,
            page: 0,
            near: NSRect(x: 300, y: 300, width: 2, height: 18),
            onPick: { _ in }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        demoWindow.dumpLayout(prefix: "diag")
        let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/layout-diag.png"
        demoWindow.snapshot(to: out)
        print("布局诊断已渲染: \(out)")
        exit(0)

    case "--voice-demo":
        // 语音候选卡片快照（不启动麦克风）：验证融合候选的样式
        let demoWindow = CandidateWindowController()
        let voiceText = CommandLine.arguments.count > 3
            ? CommandLine.arguments[3]
            : "帮我把这段代码改成异步"
        let voiceCand = Candidate(
            text: voiceText,
            consumed: 0,
            kind: "voice",
            comment: "语音"
        )
        demoWindow.present(
            candidates: [voiceCand],
            page: 0,
            near: NSRect(x: 300, y: 300, width: 2, height: 18),
            onPick: { _ in }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/voice-demo.png"
        demoWindow.snapshot(to: out)
        print("语音候选已渲染: \(out)")
        exit(0)

    case "--punct-demo":
        // 标点二次确认候选快照（不启动麦克风）：[原样, 。, ，, ！, ？]
        let demoWindow = CandidateWindowController()
        let labels = ["原样", "。", "，", "！", "？"]
        let cands = labels.map {
            Candidate(text: $0, consumed: 0, kind: "voice", comment: nil)
        }
        demoWindow.present(
            candidates: cands,
            page: 0,
            near: NSRect(x: 300, y: 300, width: 2, height: 18),
            onPick: { _ in }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/punct-demo.png"
        demoWindow.snapshot(to: out)
        print("标点确认候选已渲染: \(out)")
        exit(0)

    case "--translate-check":
        let runtime = TranslateClient.findRuntime()
        let model = TranslateClient.translateModelPath()
        print("runtime=\(runtime ?? "未检测到（brew install llama.cpp）")")
        print("model=\(model ?? "未安装（AI 增强下载 gemma-3-270m-it-q8）")")
        exit(runtime != nil && model != nil ? 0 : 1)

    case "--translate-demo":
        guard TranslateClient.findRuntime() != nil else {
            print("❌ 无运行时：brew install llama.cpp"); exit(1)
        }
        guard let modelPath = TranslateClient.translateModelPath() else {
            print("❌ 无翻译模型：--ai-download gemma-3-270m-it-q8"); exit(1)
        }
        print("model=\(modelPath)")
        let text = CommandLine.arguments.count > 2
            ? CommandLine.arguments[2]
            : "今天天气不错，我们去公园散步吧。"
        let target = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "en"
        var result: String?
        var failure: String?
        var done = false
        let started = Date()
        TranslateClient.shared.translate(text, target: target) { outcome in
            switch outcome {
            case .success(let translated): result = translated
            case .failure(let error): failure = error.localizedDescription
            }
            done = true
        }
        while !done, Date().timeIntervalSince(started) < 120 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        TranslateClient.shared.stop()
        // 给 stop() 的异步清理一点时间排空（≤2s），不等满超时窗
        let drainUntil = Date().addingTimeInterval(2)
        while Date() < drainUntil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let result {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("译文(\(target), \(ms)ms): \(result)")
            exit(0)
        }
        print("❌ \(failure ?? "超时")")
        exit(1)

    case "--ai-download":
        guard CommandLine.arguments.count > 2,
              let model = AIModelStore.shared.catalog.first(where: { $0.id == CommandLine.arguments[2] })
        else {
            print("用法: --ai-download <model-id>；可用目录：")
            for m in AIModelStore.shared.catalog {
                print("  \(m.id)\t\(m.sizeText)\t\(m.kinds.joined(separator: ","))")
            }
            exit(2)
        }
        if AIModelStore.shared.isInstalled(model) {
            print("已安装: \(model.id)"); exit(0)
        }
        print("开始下载 \(model.id)（\(model.sizeText) · 用户显式请求）…")
        var failure: String?
        var finished = false
        var lastPercent = -1
        AIModelStore.shared.onProgress = { _, progress in
            let percent = Int(progress * 100)
            if percent != lastPercent { lastPercent = percent; print("进度 \(percent)%") }
        }
        AIModelStore.shared.onFinish = { _, error in failure = error; finished = true }
        AIModelStore.shared.download(model)
        let deadline = Date().addingTimeInterval(60 * 60)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if AIModelStore.shared.isInstalled(model) { finished = true }
        }
        if AIModelStore.shared.isInstalled(model) {
            print("✅ 安装完成（sha256 校验通过）: \(model.id)")
            AIModelStore.shared.onProgress = nil
            AIModelStore.shared.onFinish = nil
            exit(0)
        }
        print("❌ 失败: \(failure ?? "超时")")
        exit(1)

    case "--clipboard-smoke":
        ClipboardMonitor.shared.setEnabled(true)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("clipboard-test-\(UUID().uuidString)", forType: .string)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        EncryptedStore.shared.flush()
        print("clipboardItems=\(EncryptedStore.shared.clipboard.count)")
        exit(EncryptedStore.shared.clipboard.isEmpty ? 1 : 0)

    case "--store-info":
        _ = EncryptedStore.shared.load()
        print("bundleId=\(Bundle.main.bundleIdentifier ?? "nil")")
        print("clipboardEnabled=\(UserDefaults.standard.bool(forKey: ClipboardMonitor.enabledKey))")
        print("keyAvailable=\(EncryptedStore.shared.keyAvailable)")
        print("userModelTsvBytes=\(EncryptedStore.shared.userModelTsv.utf8.count)")
        print("clipboardItems=\(EncryptedStore.shared.clipboard.count)")
        exit(0)

    case "--ai-settings", "--settings":
        let section: SettingsSection = installArgs[1] == "--ai-settings" ? .ai : .overview
        SettingsCenter.shared.show(section: section)
        NSApplication.shared.run()
        exit(0)

    case "--pet-switch-test":
        // 进程内连续切换形象包并快照，验证切换是否真的生效
        PluginStore.seedBundledPacks()
        PetWindowController.setEnabled(true)
        let dir = installArgs.count > 2 ? installArgs[2] : "/tmp/pet-switch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for id in ["pet-orange-cat", "pet-robot", "pet-oriental-beauty", "pet-orange-cat"] {
            PetWindowController.activePackId = id
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let path = "\(dir)/\(id).png"
            PetWindowController.shared.snapshot(to: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("switch -> \(id)  snapshot=\(size ?? 0)B")
        }
        exit(0)

    case "--voice-check":
        let avail = VoiceInputController.availability()
        print("端上语音识别可用: \(avail.onDevice)")
        print("语音识别授权状态: \(avail.authorized.rawValue)（0=未决 1=受限 2=拒绝 3=已授权）")
        exit(0)

    case "--pet-catalog-window":
        PetCatalogWindowController.shared.show()
        NSApplication.shared.run()
        exit(0)

    case "--avatar-creator":
        AvatarCreatorWindowController.shared.show()
        NSApplication.shared.run()
        exit(0)

    case "--live2d-import":
        guard installArgs.count > 2 else {
            print("用法: --live2d-import <模型文件夹或zip>")
            exit(1)
        }
        do {
            let id = try PetImporter.importLive2D(from: URL(fileURLWithPath: installArgs[2]))
            print("imported \(id); coreAvailable=\(PetRuntimeStore.live2DCoreAvailable())")
        } catch {
            print("failed: \(error.localizedDescription)")
        }
        exit(0)

    case "--pet-catalog":
        PluginStore.seedBundledPacks()
        for entry in PetCatalogStore.entries() {
            print("\(entry.id)\t\(entry.name)\t\(entry.license)\t\(entry.sizeText)\t\((entry.sha256 ?? "").isEmpty ? "无校验和" : "sha256")")
        }
        exit(0)

    case "--pet-fetch-seed":
        PetModelInstaller.install(PetModelCatalog.seedSan, onProgress: { _ in }) { result in
            switch result {
            case .success:
                print("seed-san 安装成功")
            case .failure(let error):
                print("seed-san 失败: \(error.localizedDescription)")
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)

    case "--pet-catalog-fetch":
        guard installArgs.count > 2,
              let entry = PetCatalogStore.entries().first(where: { $0.id == installArgs[2] }) else {
            print("用法: --pet-catalog-fetch <id>（用 --pet-catalog 查看）")
            exit(1)
        }
        PetModelInstaller.install(entry, onProgress: { _ in }) { result in
            switch result {
            case .success: print("installed \(entry.id)")
            case .failure(let error): print("failed: \(error.localizedDescription)")
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)

    case "--pet-vrm-check":
        PluginStore.seedBundledPacks()
        PetWindowController.activePackId = "pet-vrm-sample"
        PetWindowController.setEnabled(true)
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        PetWindowController.shared.vrmDebugState { state in
            print("vrm-debug: \(state)")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        PetWindowController.shared.captureVrmPNG(to: "/tmp/petshots/vrm-live.png") { ok in
            print("capture=\(ok)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)

    case "--pet-capture":
        // JS canvas 抓图（能捕获 WebGL，--pet-demo 的 takeSnapshot 抓不到 VRM）
        PluginStore.seedBundledPacks()
        let pid = installArgs.count > 2 ? installArgs[2] : "pet-vrm-sample"
        let out = installArgs.count > 3 ? installArgs[3] : "/tmp/pet-capture.png"
        PetWindowController.activePackId = pid
        PetWindowController.setEnabled(true)
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        PetWindowController.shared.captureVrmPNG(to: out) { ok in
            print("capture \(pid) ok=\(ok) -> \(out)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)

    case "--pet-eval":
        // 开发用：加载形象 → 依次执行几段 JS（每段之间等 1.2 秒）→ 打印页面状态并抓图
        // 用法: --pet-eval <packId> <out.png> "<js>" ["<js>" …]
        guard installArgs.count > 4 else { print("用法: --pet-eval <packId> <out.png> \"<js>\" …"); exit(1) }
        PluginStore.seedBundledPacks()
        PetWindowController.activePackId = installArgs[2]
        PetWindowController.setEnabled(true)
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        for js in installArgs.dropFirst(4) {
            PetWindowController.shared.debugEval(js) { print("eval \(js) -> \($0)") }
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        }
        PetWindowController.shared.vrmDebugState { print("state: \($0)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        PetWindowController.shared.captureVrmPNG(to: installArgs[3]) { ok in
            print("capture ok=\(ok)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)

    case "--pet-demo":
        PluginStore.seedBundledPacks()
        let packId = installArgs.count > 2 ? installArgs[2] : ""
        PetWindowController.activePackId = packId
        PetWindowController.setEnabled(true)
        let out = installArgs.count > 3 ? installArgs[3] : "/tmp/pet-demo.png"
        let state = installArgs.count > 4 ? installArgs[4] : ""
        RunLoop.main.run(until: Date().addingTimeInterval(state.isEmpty ? 5.0 : 3.5))
        if !state.isEmpty {
            PetWindowController.shared.debugApplyState(state)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        }
        PetWindowController.shared.snapshotAsync(to: out) { ok in
            print("pack=\(packId.isEmpty ? "builtin" : packId) -> \(out) ok=\(ok)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)

    case "--pets":
        PluginStore.seedBundledPacks()
        let catalog = PluginStore.scan()
        print("插件包共 \(catalog.packs.count) 个：")
        for pack in catalog.packs {
            print("  [\(pack.kind)] \(pack.id)\t\(pack.name)\t\(pack.description ?? "")")
        }
        for error in catalog.errors {
            print("  ! \(error.dir): \(error.error)")
        }
        exit(0)

    case "--pet-workshop":
        // 开发用：打开形象工坊，可附带图片路径直接载入（不改桌宠设置，除非点「保存并使用」）
        PetWorkshopWindowController.shared.show()
        let paths = installArgs.dropFirst(2)
        let images = paths.filter { !$0.hasSuffix(".snapshot.png") && $0 != "actions" && $0 != "studio" }.map { URL(fileURLWithPath: $0) }
        if !images.isEmpty || paths.contains("studio") {
            PetWorkshopWindowController.shared.debugAdd(Array(images), actionsTab: paths.contains("actions"), studioTab: paths.contains("studio"))
        }
        // 以 .snapshot.png 结尾的参数：6 秒后把窗口内容存成 PNG 并退出（WebGL 预览区会是空白）
        if let out = paths.first(where: { $0.hasSuffix(".snapshot.png") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if let view = PetWorkshopWindowController.shared.window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
        NSApplication.shared.run()
        exit(0)

    case "--imagegen-test":
        // 开发用：对本地模拟服务跑一遍「AI 补全表情」的请求与解析（参数：<baseURL> <openai|gemini> <参考图>）
        var config = PetImageGenConfig()
        config.provider = PetImageGenProvider(rawValue: installArgs[3]) ?? .openai
        config.baseURL = installArgs[2]
        guard let png = try? Data(contentsOf: URL(fileURLWithPath: installArgs[4])),
              let reference = PetImageGen.referencePNG(from: png) else { print("参考图读不了"); exit(1) }
        PetImageGen.generate(role: .happy, reference: reference, config: config, key: "test-key") { result in
            switch result {
            case .success(let data):
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("imagegen-test.png")
                try? data.write(to: file)
                let processed = try? PuppetBuilder.process([file])
                print("OK", config.provider.rawValue, "bytes:", data.count, "processed:", processed?.first?.image.pixelSize ?? .zero)
            case .failure(let error):
                print("FAILED", error.localizedDescription)
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)

    case "--puppet-build":
        // 开发用：走形象工坊的完整流程（抠图 / 裁切 / 找脸 / 自动对齐）打包 .lianapet，并输出对齐检查图
        // 参数：<名字> <输出 .lianapet> <对齐检查图.png> [--no-talk] <role=图片路径>…（第一个必须是 idle）
        let name = installArgs[2], out = installArgs[3], sheetPath = installArgs[4]
        let noTalk = installArgs.contains("--no-talk")
        // --id=<形象包 id>：覆盖已装的同一个形象（不加则新建）
        let fixedId = installArgs.first { $0.hasPrefix("--id=") }.map { String($0.dropFirst(5)) }
        let pairs: [(PuppetRole, URL)] = installArgs.dropFirst(5).compactMap { arg in
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let role = PuppetRole(rawValue: parts[0]) else { return nil }
            return (role, URL(fileURLWithPath: parts[1]))
        }
        guard pairs.first?.0 == .idle else { print("第一个必须是 idle=…"); exit(1) }
        do {
            let processed = try PuppetBuilder.process(pairs.map(\.1))
            var images: [PuppetImage] = []
            for (index, item) in processed.enumerated() {
                var image = item.image
                image.role = pairs[index].0
                if image.role == .idle && noTalk { image.rig.mouth = nil }   // 平时本身张着嘴：不再自动生成张嘴图
                images.append(image)
            }
            let idle = images[0]
            for (i, aligned) in PuppetImage.alignAll(images, idle: idle).enumerated() where i > 0 {
                images[i].align = aligned.align
                images[i].canvasAligned = aligned.canvas
            }
            for image in images {
                let a = image.align
                print(String(format: "%-10@ %4.0f×%-4.0f 脸:%@ 眼:%d 对齐%@ s=%.2f dx=%+.2f dy=%+.2f %@",
                             image.role.rawValue as NSString, image.pixelSize.width, image.pixelSize.height,
                             (image.rig.face == nil ? "无" : "有") as NSString, image.rig.eyes.count,
                             (image.canvasAligned ? "(画布)" : "") as NSString,
                             a.scale, a.dx, a.dy, (image.role == .idle ? "" : (PuppetImage.mismatch(image, idle: idle).map { "⚠️ " + $0 } ?? "✓")) as NSString))
            }
            // 对齐检查图：每格 = 平时（半透明）+ 该表情按对齐参数叠上去（与渲染器同一套坐标）
            let cw: CGFloat = 260, ch: CGFloat = 320, cols = 5
            let rows = (images.count + cols - 1) / cols
            let sheet = NSImage(size: NSSize(width: cw * CGFloat(cols), height: (ch + 24) * CGFloat(rows)))
            sheet.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: sheet.size).fill()
            let idleImage = NSImage(data: idle.png)!
            for (i, image) in images.enumerated() {
                let col = CGFloat(i % cols), row = CGFloat(rows - 1 - i / cols)
                let cell = NSRect(x: col * cw, y: row * (ch + 24) + 24, width: cw, height: ch)
                let hb = min(ch * 0.86, cw * 0.92 / idle.aspect), ground = cell.minY + ch * 0.05
                idleImage.draw(in: NSRect(x: cell.midX - hb * idle.aspect / 2, y: ground, width: hb * idle.aspect, height: hb),
                               from: .zero, operation: .sourceOver, fraction: image.role == .idle ? 1 : 0.3)
                if image.role != .idle, let ns = NSImage(data: image.png) {
                    let h = hb * image.align.scale, w = h * image.aspect
                    ns.draw(in: NSRect(x: cell.midX - w / 2 + image.align.dx * hb, y: ground + image.align.dy * hb, width: w, height: h),
                            from: .zero, operation: .sourceOver, fraction: 0.75)
                }
                NSAttributedString(string: image.role.shortTitle, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                    .draw(at: NSPoint(x: cell.minX + 6, y: cell.minY - 20))
            }
            sheet.unlockFocus()
            if let tiff = sheet.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: sheetPath)) }

            var draft = PuppetDraft()
            draft.name = name
            draft.images = images
            let id = fixedId ?? PuppetPackStore.newPackId()
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("puppet-build-\(UUID().uuidString)")
            try PuppetPackStore.write(draft, to: work, id: id)
            try? FileManager.default.removeItem(atPath: out)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--norsrc", work.path, out]
            try zip.run()
            zip.waitUntilExit()
            print("ok", id, out)
        } catch {
            print("failed", error.localizedDescription)
        }
        exit(0)

    case "--puppet-make":
        // 开发用：用一组按表情命名的 PNG（idle.png、happy.png…）+ 固定骨架生成 .lianapet
        // 参数：<图片目录> <名字> <输出 .lianapet> [骨架 JSON]
        guard installArgs.count >= 5 else { print("用法：--puppet-make <dir> <name> <out.lianapet> [rig.json]"); exit(1) }
        let dir = URL(fileURLWithPath: installArgs[2])
        var rigJSON: [String: Any]?
        if installArgs.count > 5, let data = try? Data(contentsOf: URL(fileURLWithPath: installArgs[5])) {
            rigJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        var draft = PuppetDraft()
        draft.name = installArgs[3]
        draft.shareable = true
        for role in PuppetRole.allCases {
            let file = dir.appendingPathComponent("\(role.rawValue).png")
            guard let png = try? Data(contentsOf: file), let rep = NSBitmapImageRep(data: png) else { continue }
            draft.images.append(PuppetImage(role: role, png: png,
                                            pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh),
                                            rig: PuppetRig(json: rigJSON)))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("puppet-make-\(UUID().uuidString)")
        let id = "puppet-" + String(UUID().uuidString.lowercased().prefix(8))
        do {
            try PuppetPackStore.write(draft, to: work, id: id)
            let out = installArgs[4]
            try? FileManager.default.removeItem(atPath: out)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--norsrc", work.path, out]
            try zip.run()
            zip.waitUntilExit()
            print("ok", id, draft.images.map(\.role.rawValue).joined(separator: ","), out)
        } catch {
            print("failed", error.localizedDescription)
        }
        exit(0)

    case "--pet-scenes":
        // 开发用：各场景道具 + 一个示意角色，渲染成一张 PNG（参数：输出路径 [角色图片]）
        let out = installArgs.count > 2 ? installArgs[2] : "/tmp/pet-scenes.png"
        let figure = installArgs.count > 3 ? NSImage(contentsOfFile: installArgs[3]) : nil
        let scenes: [(PetScene, Bool)] = [(.office, false), (.coding, false), (.game, false), (.music, false), (.video, false),
                                          (.chat, false), (.design, false), (.reading, false), (.meeting, false), (.browse, false),
                                          (.office, true), (.none, true)]
        let cell = NSSize(width: 220, height: 300)
        let sheet = NSImage(size: NSSize(width: cell.width * 6, height: (cell.height + 24) * 2))
        sheet.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, item) in scenes.enumerated() {
            let host = NSView(frame: NSRect(origin: .zero, size: cell))
            let back = PetSceneView(frame: host.bounds, layer: .back)
            let front = PetSceneView(frame: host.bounds, layer: .front)
            back.show(item.0, night: item.1, animated: false)
            front.show(item.0, night: item.1, animated: false)
            host.addSubview(back)
            if let figure {
                let iv = NSImageView(frame: NSRect(x: 30, y: 15, width: 160, height: 258))
                iv.image = figure
                iv.imageScaling = .scaleProportionallyUpOrDown
                host.addSubview(iv)
            }
            host.addSubview(front)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let col = CGFloat(i % 6), row = CGFloat(1 - i / 6)
            let origin = NSPoint(x: col * cell.width, y: row * (cell.height + 24) + 24)
            NSImage(cgImage: rep.cgImage!, size: cell).draw(in: NSRect(origin: origin, size: cell))
            let label = item.0.rawValue + (item.1 ? " · 夜" : "")
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                .draw(at: NSPoint(x: origin.x + 8, y: origin.y - 20))
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
        }
        exit(0)

    case "--clip-test":
        // 开发用：命令 / 链接识别 + 危险检测；带 --ego 时用 ego lite 实跑一次 example.com
        let samples = [
            "brew install llama.cpp",
            "$ git status && git log --oneline -5",
            "curl -fsSL https://example.com/install.sh | sh",
            "sudo rm -rf /tmp/demo",
            "git push --force origin main",
            "今天天气不错，我们去公园 ls 一下",
            "./scripts/build.sh --release",
            "export FOO=1\nnpm run dev",
            "Hello world",
            "https://example.com/a?b=1",
            "看看 https://example.com",
        ]
        for text in samples {
            if let url = LinkDetector.detect(text) { print("LINK   ", url.absoluteString); continue }
            if let cmd = CommandDetector.detect(text) { print("COMMAND", cmd.command.replacingOccurrences(of: "\n", with: " ⏎ "), cmd.dangers); continue }
            print("none   ", text)
        }
        guard installArgs.contains("--ego") else { exit(0) }
        let shot = NSTemporaryDirectory() + "liana-ego-test.png"
        let request = PageRequest(url: URL(string: "https://example.com")!, wantText: true, screenshotPath: shot,
                                  script: "Array.from(document.querySelectorAll('h1,p')).length", waitMs: 800)
        BrowserRunner.run(request) { result in
            switch result {
            case .success(let page):
                print("EGO title:", page.title, "| text chars:", page.text.count, "| shot:", page.screenshot ?? "-", "| recipe:", page.scriptResult ?? "-")
            case .failure(let error):
                print("EGO failed:", error.localizedDescription)
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)

    case "--pet-keys-test":
        // 开发用：按键类反应规则（只看 keyCode 与修饰键）
        let o = PetKeyObserver.shared
        func k(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ ch: String? = nil) -> String {
            o.key(code: code, flags: flags, characters: ch)?.trigger ?? "-"
        }
        print("3 deletes:", k(51), k(51), k(51))
        print("same key x7:", (0..<7).map { _ in k(0) }.joined(separator: " "))
        print("cmd+z:", k(6, .command, "z"), "cmd+s:", k(1, .command, "s"), "cmd+v:", k(9, .command, "v"))
        print("arrows:", k(123), k(126))
        print("enter:", k(36), "esc:", k(53), "tab:", k(48))
        var errors: [String] = []
        for _ in 0..<3 { o.noteCommit(); errors.append(k(51)) }
        print("commit→delete x3:", errors.joined(separator: " "))
        print("fast typing:", (0..<30).map { k(UInt16(($0 % 6) + 2)) }.filter { $0 != "-" })
        exit(0)

    case "--pet-chat-test":
        // 开发用：模拟在对话气泡里打字（拼音组字 → 选词 → 发送），并检查本机规则回复
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        var sent: [String] = []
        composer.onSend = { sent.append($0) }
        func key(_ chars: String, _ code: UInt16) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                composer.keyDown(with: event)
            }
        }
        for ch in "nihao" { key(String(ch), 0) }
        print("candidates:", composer.candidateTexts.prefix(3))
        key(" ", 49); key(",", 43); key("w", 0); key("o", 0); key("3", 20); key("\r", 36)
        for ch in "ceshi" { key(String(ch), 0) }
        key("\r", 36); key("\r", 36)
        print("sent:", sent)
        for message in ["跳个舞吧", "现在几点了", "今天打了多少字", "你叫什么名字"] {
            PetChatBrain.reply(to: message, history: [], petName: "小松") { reply in
                print("reply[\(message)]:", reply.text, reply.action ?? reply.trigger ?? "")
            }
        }
        exit(0)

    case "--pet-sketches":
        // 开发用：把形象工坊的 12 张表情示意图渲染成一张 PNG
        let out = installArgs.count > 2 ? installArgs[2] : "/tmp/pet-sketches.png"
        Task { @MainActor in
            renderRoleSketches(to: out)
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)

    case "--clipboard-window":
        ClipboardWindowController.shared.show()
        NSApplication.shared.run()
        exit(0)

    case "--pet-window":
        PetWindowController.setEnabled(true)
        PetWindowController.shared.react(.commit)
        NSApplication.shared.run()
        exit(0)

    default:
        break
    }
}

// MARK: - 品牌迁移（InputFlow → 松萝 / Liana，一次性、非破坏）

/// 把旧品牌时代的数据搬进新位置。只复制、不删除、失败静默降级——
/// 回滚到旧版 InputFlow 时旧数据仍完好。钥匙串密钥不受影响（服务名钉死，见 EncryptedStore）。
private func migrateLegacyBrandData() {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let legacyDir = appSupport.appendingPathComponent("InputFlow", isDirectory: true)
    let newDir = appSupport.appendingPathComponent("Liana", isDirectory: true)

    // 数据目录：旧 ~/Library/Application Support/InputFlow/userdata.enc 存在、
    // 且新目录还没有 userdata.enc 时，整目录复制过去（含 base.ifd / models / plugins）。
    let legacyEnc = legacyDir.appendingPathComponent("userdata.enc")
    let newEnc = newDir.appendingPathComponent("userdata.enc")
    if fm.fileExists(atPath: legacyEnc.path), !fm.fileExists(atPath: newEnc.path) {
        do {
            try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: legacyDir.path) {
                let dst = newDir.appendingPathComponent(item)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: legacyDir.appendingPathComponent(item), to: dst)
                }
            }
            NSLog("松萝: 已从 InputFlow 迁移用户数据（用户词/知你账本/营养库/剪切板历史）")
        } catch {
            NSLog("松萝: 迁移旧数据失败（\(error.localizedDescription)），本次按空数据继续，旧数据未动")
        }
    }

    // 偏好键：旧域 → 新域。bundle id 迁移过多次，逐个源域搬运，同名规则覆盖
    // LianaAIModel.<kind> 这类动态后缀键。不删旧域，留作回滚。
    //   dev.inputflow.ime / dev.inputflow.inputmethod : InputFlow* → Liana*
    //   dev.liana.ime                                 : Liana*      → Liana*（仅换域）
    let legacyPrefDomains: [(domain: String, prefix: String)] = [
        ("dev.inputflow.ime", "InputFlow"),
        ("dev.inputflow.inputmethod", "InputFlow"),
        ("dev.liana.ime", "Liana"),
    ]
    let newDefaults = UserDefaults.standard
    var migrated = 0
    for source in legacyPrefDomains {
        guard let legacy = newDefaults.persistentDomain(forName: source.domain),
              !legacy.isEmpty else { continue }
        let replacement = source.prefix == "InputFlow" ? "Liana" : source.prefix
        for (key, value) in legacy where key.hasPrefix(source.prefix) {
            let newKey = replacement + key.dropFirst(source.prefix.count)
            if newDefaults.object(forKey: newKey) == nil {
                newDefaults.set(value, forKey: newKey)
                migrated += 1
            }
        }
    }
    if migrated > 0 {
        NSLog("松萝: 已迁移 \(migrated) 项旧偏好设置（中英模式记忆/桌宠/皮肤等）")
    }
}

// MARK: - 输入法主进程

// M1：加密用户数据（钥匙串密钥；不可用则本次仅内存）+ 剪切板监控（默认关闭）
_ = NSApplication.shared
// 应用代理只处理「打开文件」（双击 .lianapet 导入）；NSApplication.delegate 是弱引用，用全局常量持有
let appDelegate = LianaAppDelegate()
NSApplication.shared.delegate = appDelegate
// 已经有一份松萝在运行（Finder 双击 .lianapet 时系统可能另起一份）：
// 这份只负责把文件导入并通知正在运行的那份，不启动输入法服务、不显示桌宠，几秒后自行退出
let ownPID = ProcessInfo.processInfo.processIdentifier
// 只认「活着且已经跑了一会儿」的那份：安装 / 升级时旧进程正在退出，不能让新进程误以为有人在跑而退出
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != ownPID && !$0.isTerminated
        && Date().timeIntervalSince($0.launchDate ?? Date()) > 3 }) {
    appDelegate.forwardOnly = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    NSApplication.shared.run()
    exit(0)
}
// 别的进程导入了形象包 → 这里换上
DistributedNotificationCenter.default().addObserver(forName: .lianaPetImported, object: nil, queue: .main) { note in
    guard let id = note.object as? String,
          PetWindowController.availablePets().contains(where: { $0.id == id }) else { return }
    PetWindowController.activePackId = id
    if !PetWindowController.isEnabled { PetWindowController.setEnabled(true) }
    let name = PuppetPackStore.load(packId: id)?.name ?? id
    GlassToast.shared.show("已导入并换上「\(name)」", symbol: "pawprint.fill")
}
migrateLegacyBrandData()
PluginStore.seedBundledPacks()
// 「全新安装」必须在 EncryptedStore.load() 之前判定：load 会创建 userdata.enc
let isFreshInstall = !FileManager.default.fileExists(
    atPath: NSHomeDirectory() + "/Library/Application Support/Liana/userdata.enc")
selectSelfIfFreshInstall(isFresh: isFreshInstall)
_ = EncryptedStore.shared.load()
ClipboardMonitor.shared.startIfEnabled()
ClipboardActionWatcher.shared.refresh()
AppNameLexicon.startPeriodicRefresh()
PetWindowController.restoreIfEnabled()
PetLinkWindow.shared.restoreIfEnabled()
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    EncryptedStore.shared.flush()
}

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "dev.liana.inputmethod.ime_Connection"

guard let server = IMKServer(name: connectionName, bundleIdentifier: inputSourceID()) else {
    NSLog("Liana: 创建 IMKServer 失败（检查 Info.plist 的 InputMethodConnectionName）")
    exit(1)
}

// 保留 server 到进程结束
_ = server
NSApplication.shared.run()
