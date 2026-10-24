import AppKit

// MARK: - 媒体控制
//
// 谁在运行听谁：音乐.app / Spotify（AppleScript，系统级通用做法）。
// 音量走系统输出音量，对所有播放器一致。
// 首次控制会弹一次系统的「自动化」授权（松萝 → 音乐/Spotify），属正常一次性流程；
// 拒绝后功能静默失效，可在 系统设置 › 隐私与安全性 › 自动化 里重新打开。
// 查询与控制都以 NSWorkspace 的运行列表为闸门：不会因为查询而拉起播放器。

final class MediaController {
    static let shared = MediaController()

    struct NowPlaying {
        let app: String        // 显示名：音乐 / Spotify
        let title: String
        let artist: String
        let playing: Bool
    }

    /// (bundle id, 显示名)。
    private static let players: [(String, String)] = [
        ("com.apple.Music", "音乐"),
        ("com.spotify.client", "Spotify"),
    ]

    /// 当前在运行的播放器（不会因查询拉起 App）。
    private func runningPlayers() -> [(bundle: String, name: String)] {
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        return Self.players.filter { running.contains($0.0) }
    }

    /// 运行中的播放器显示名（菜单用它决定要不要露出媒体控制，零 AppleScript、不阻塞）。
    func runningPlayerNames() -> [String] {
        runningPlayers().map { $0.name }
    }

    /// 当前曲目：第一个「正在运行且有曲目」的播放器胜出。
    func nowPlaying() -> NowPlaying? {
        for (bundle, name) in runningPlayers() {
            let app = bundle == "com.apple.Music" ? "Music" : "Spotify"
            let src = """
            tell application "\(app)"
                if it is running then
                    try
                        if player state is playing or player state is paused then
                            return (name of current track) & "\u{1F}" & (artist of current track) & "\u{1F}" & (player state as string)
                        end if
                    end try
                end if
            end tell
            return ""
            """
            if let out = run(src), !out.isEmpty {
                let parts = out.components(separatedBy: "\u{1F}")
                return NowPlaying(
                    app: name,
                    title: parts.count > 0 ? parts[0] : "",
                    artist: parts.count > 1 ? parts[1] : "",
                    playing: parts.count > 2 ? parts[2] == "playing" : false
                )
            }
        }
        return nil
    }

    /// 播放/暂停：作用于所有在运行的播放器（通常只有一个）。
    func togglePlay() {
        for (bundle, _) in runningPlayers() {
            let app = bundle == "com.apple.Music" ? "Music" : "Spotify"
            run("tell application \"\(app)\" to if it is running then playpause")
        }
    }

    func next() {
        send("next track")
    }

    func previous() {
        send("previous track")
    }

    private func send(_ command: String) {
        for (bundle, _) in runningPlayers() {
            let app = bundle == "com.apple.Music" ? "Music" : "Spotify"
            run("tell application \"\(app)\" to if it is running then \(command)")
        }
    }

    /// 系统输出音量 ±step（0–100）。返回调节后的值。
    @discardableResult
    func volume(by step: Int) -> Int? {
        let src = """
        set v to output volume of (get volume settings)
        set v to v + \(step)
        if v > 100 then set v to 100
        if v < 0 then set v to 0
        set volume output volume v
        return (output volume of (get volume settings)) as integer as string
        """
        return run(src).flatMap { Int($0) }
    }

    func outputVolume() -> Int? {
        run("return output volume of (get volume settings) as integer as string").flatMap { Int($0) }
    }

    /// 执行 AppleScript；任何失败（未授权 / 播放器不配合）都返回 nil，不惊动用户。
    @discardableResult
    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let error {
            NSLog("Liana media AppleScript 失败: \(error)")
            return nil
        }
        return result?.stringValue
    }
}

// MARK: - 媒体动作 + 提示（桌宠菜单 / 功能面板共用）

enum MediaActions {
    /// 执行并气泡回报结果（当前曲目或音量）。AppleScript 一律离主线程：
    /// 首次授权弹窗期间事件会阻塞，绝不能卡住菜单或面板。
    static func perform(_ kind: MediaKind) {
        DispatchQueue.global(qos: .userInitiated).async {
            let controller = MediaController.shared
            switch kind {
            case .toggle:
                controller.togglePlay()
            case .next:
                controller.next()
            case .previous:
                controller.previous()
            case .volumeUp:
                _ = controller.volume(by: 10)
            case .volumeDown:
                _ = controller.volume(by: -10)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { report() }
    }

    static func report() {
        DispatchQueue.global(qos: .userInitiated).async {
            let np = MediaController.shared.nowPlaying()
            let volume = np == nil ? MediaController.shared.outputVolume() : nil
            DispatchQueue.main.async {
                if let np {
                    let state = np.playing ? "▶" : "⏸"
                    let artist = np.artist.isEmpty ? "" : " · \(np.artist)"
                    GlassToast.shared.show("\(state) \(np.title)\(artist)", symbol: "music.note", duration: 3)
                } else if let volume {
                    GlassToast.shared.show("音量 \(volume)%", symbol: "speaker.wave.2.fill", duration: 2)
                }
            }
        }
    }

    enum MediaKind {
        case toggle, next, previous, volumeUp, volumeDown
    }
}
