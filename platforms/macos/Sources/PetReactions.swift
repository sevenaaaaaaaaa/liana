import AppKit

/// 桌宠对「怎么在打字」的反应：连续删除、狂敲同一个键、功能键 / 快捷键、手速、反复出错。
///
/// 只拿按键的**类别**（删除 / 回车 / 方向键 / ⌘Z …）和时间间隔做判断，从不读取、记录输入的内容；
/// 同一个键被连敲只比较 keyCode 是否相同，判断完即丢弃。
final class PetKeyObserver {
    static let shared = PetKeyObserver()

    struct Reaction {
        let trigger: String
        let emote: String?
        let line: String?
    }

    private var keyTimes: [Date] = []
    private var deleteTimes: [Date] = []
    private var sameKey: (code: UInt16, times: [Date]) = (0, [])
    private var lastCommitAt: Date?
    private var errors: [Date] = []
    private var cooldowns: [String: Date] = [:]

    /// InputController 每个 keyDown 调一次（含 ⌘ 组合键）。
    func key(code: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Reaction? {
        let now = Date()
        if flags.contains(.command) {
            switch characters?.lowercased() {
            case "z": return ready("undo", 4) ? Reaction(trigger: "undo", emote: "⏪", line: nil) : nil
            case "s":
                guard ready("save", 20) else { return nil }
                return Reaction(trigger: "save", emote: "💾", line: ready("save-line", 600) ? "保存了，安心～" : nil)
            case "c": return ready("copy", 3) ? Reaction(trigger: "copy", emote: "📋", line: nil) : nil
            case "v": return ready("paste", 3) ? Reaction(trigger: "paste", emote: "📋", line: nil) : nil
            default: return nil
            }
        }
        if flags.contains(.control) || flags.contains(.option) { return nil }

        // 狂敲同一个键（删除和方向键本来就会连按，不算）
        if ![51, 117, 123, 124, 125, 126].contains(code) {
            sameKey = sameKey.code == code
                ? (code, sameKey.times.filter { now.timeIntervalSince($0) < 2 } + [now])
                : (code, [now])
            if sameKey.times.count >= 7, ready("noisy", 30) {
                sameKey.times.removeAll()
                return Reaction(trigger: "noisy", emote: "💥", line: ["好吵呀～", "键盘要被敲坏啦", "轻一点嘛"].randomElement())
            }
        }

        // 手速：3 秒内 ≥ 24 键（约每秒 8 键）
        keyTimes = keyTimes.filter { now.timeIntervalSince($0) < 3 } + [now]
        if keyTimes.count >= 24, ready("typing_fast", 180) {
            return Reaction(trigger: "typing_fast", emote: "🔥", line: ["手速好快！", "噼里啪啦～", "停不下来了！"].randomElement())
        }

        switch code {
        case 51, 117:   // 删除
            if let commit = lastCommitAt, now.timeIntervalSince(commit) < 2 {
                lastCommitAt = nil
                if let confused = noteError() { return confused }
            }
            deleteTimes = deleteTimes.filter { now.timeIntervalSince($0) < 1 } + [now]
            if deleteTimes.count >= 3, ready("deleting", 3) {
                return Reaction(trigger: "deleting", emote: "🧽", line: nil)
            }
        case 36, 76:
            return ready("enter", 2.5) ? Reaction(trigger: "enter", emote: nil, line: nil) : nil
        case 48:
            return ready("tab", 1.5) ? Reaction(trigger: "tab", emote: nil, line: nil) : nil
        case 53:
            return ready("esc", 4) ? Reaction(trigger: "esc", emote: "🙅", line: nil) : nil
        case 123, 124, 125, 126:
            guard ready("arrow", 0.5) else { return nil }
            let name = [123: "arrow_left", 124: "arrow_right", 125: "arrow_down", 126: "arrow_up"][Int(code)] ?? "arrow_right"
            return Reaction(trigger: name, emote: nil, line: nil)
        default:
            break
        }
        return nil
    }

    /// 上屏（刚上屏就删 = 选错了字）
    func noteCommit() {
        lastCommitAt = Date()
    }

    /// 选词失败（序号超出候选）等明确的出错
    func noteSelectFailed() -> Reaction? {
        noteError()
    }

    /// 90 秒内出错 3 次 → 困惑地问你是不是没找到想要的字
    private func noteError() -> Reaction? {
        let now = Date()
        errors = errors.filter { now.timeIntervalSince($0) < 90 } + [now]
        guard errors.count >= 3, ready("confused", 180) else { return nil }
        errors.removeAll()
        return Reaction(trigger: "confused", emote: "🤔",
                        line: ["是不是没找到想要的字？多打几个拼音试试", "这个词不好打吗？打一次我就记住啦", "选错啦？别急～"].randomElement())
    }

    private func ready(_ key: String, _ cooldown: TimeInterval) -> Bool {
        if let last = cooldowns[key], Date().timeIntervalSince(last) < cooldown { return false }
        cooldowns[key] = Date()
        return true
    }
}
