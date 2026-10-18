import Foundation

/// 桌宠情感：长期「好感度」+ 短期情绪事件（被连戳生气、被冷落委屈、回来时欢迎……）。
///
/// 只根据本机的互动节奏计算（点了几下、多久没理它、删字多不多），不读任何输入内容，不上传。
/// 引擎只负责「判断该有什么情绪」，表现（动作 / 情绪符号 / 台词）由 PetWindowController 执行。
final class PetEmotion {
    static let shared = PetEmotion()

    struct Event {
        let trigger: String        // 纸偶动作触发器名（actions.json 的 triggers）
        let emote: String?         // 头顶情绪符号
        let line: String?
        let proactive: Bool        // 主动发起的（安静模式下不说话，只做动作）
    }

    private let affectionKey = "LianaPetAffection"
    private let affectionDayKey = "LianaPetAffectionDay"

    /// 好感度 0…100：摸头、陪它打字会涨，冷落、连戳会降；隔天没互动缓慢回落。
    private(set) var affection: Double

    private var pets: [Date] = []
    private var pokes: [Date] = []
    private var deletes: [Date] = []
    private var cooldowns: [String: Date] = [:]
    private var lastTouch = Date()
    private var nightNoticed = ""

    private init() {
        let defaults = UserDefaults.standard
        affection = defaults.object(forKey: affectionKey) as? Double ?? 50
        decayForMissedDays()
    }

    /// 0 生疏 / 1 熟悉 / 2 亲近 / 3 最喜欢
    var level: Int {
        switch affection {
        case ..<30: return 0
        case ..<60: return 1
        case ..<85: return 2
        default: return 3
        }
    }

    var hearts: String {
        let full = Int((affection / 20).rounded())
        return String(repeating: "❤️", count: full) + String(repeating: "🤍", count: max(0, 5 - full))
    }

    // MARK: - 输入事件

    /// 摸头。连摸几下 → 心动。
    func petted() -> Event? {
        let now = Date()
        lastTouch = now
        pets = recent(pets, within: 60) + [now]
        // 一分钟内摸太多次不再涨，避免刷好感
        if pets.count <= 8 { adjust(+1.5) }
        guard recent(pets, within: 6).count >= 4, ready("love", cooldown: 25) else { return nil }
        let lines: [[String]] = [
            ["嘿嘿，痒～", "你、你干嘛…"],
            ["好开心～", "再摸一下嘛"],
            ["最喜欢被你摸头了", "嘿嘿嘿～"],
            ["最喜欢你了！", "要一直在一起哦", "你是最好的！"],
        ]
        return Event(trigger: "love", emote: "❤️", line: lines[level].randomElement(), proactive: false)
    }

    /// 戳一戳。几秒内连戳 → 生气背过身。
    func poked() -> Event? {
        let now = Date()
        lastTouch = now
        pokes = recent(pokes, within: 10) + [now]
        guard recent(pokes, within: 4).count >= 3, ready("angry", cooldown: 20) else {
            adjust(+0.3)
            return nil
        }
        adjust(-2)
        pokes.removeAll()
        return Event(trigger: "angry", emote: "💢",
                     line: ["哼！不理你了", "再戳我就生气了！", "别戳啦！"].randomElement(), proactive: false)
    }

    /// 拖动、右键菜单等其他直接互动。
    func touched() {
        lastTouch = Date()
    }

    /// 删字。短时间删得很多 → 安慰你。
    func deleted() -> Event? {
        let now = Date()
        deletes = recent(deletes, within: 20) + [now]
        guard deletes.count >= 15, ready("comfort", cooldown: 300) else { return nil }
        deletes.removeAll()
        return Event(trigger: "comfort", emote: "🍵",
                     line: ["别急，慢慢来", "写不顺就先喝口水", "没关系，改改就好"].randomElement(), proactive: true)
    }

    /// 离开很久后重新开始打字 → 欢迎回来。
    func resumed(afterIdle seconds: TimeInterval) -> Event? {
        guard seconds >= 600, ready("welcome", cooldown: 1800) else { return nil }
        adjust(+1)
        let lines = level >= 2 ? ["你回来啦！想你了～", "欢迎回来！等你好久了"] : ["你回来啦！", "欢迎回来～"]
        return Event(trigger: "welcome", emote: "✨", line: lines.randomElement(), proactive: true)
    }

    /// 鼠标在桌宠附近来回猛晃 → 晕了。
    func shaken() -> Event? {
        guard ready("dizzy", cooldown: 20) else { return nil }
        lastTouch = Date()
        return Event(trigger: "dizzy", emote: "💫", line: ["别晃啦，晕了…", "眼前全是星星"].randomElement(), proactive: false)
    }

    /// 鼠标一直停在桌宠身上 → 害羞。
    func stared() -> Event? {
        guard ready("shy", cooldown: 40) else { return nil }
        return Event(trigger: "shy", emote: "☺️", line: ["一直盯着我看干嘛…", "被看得不好意思了"].randomElement(), proactive: false)
    }

    /// 每秒一次：被冷落、深夜提醒。`typingRecently` = 最近两分钟在打字（人在电脑前）。
    func tick(typingRecently: Bool) -> Event? {
        guard typingRecently else { return nil }
        let hour = Calendar.current.component(.hour, from: Date())
        let today = PetStats.dayKey(Date().addingTimeInterval(-6 * 3600))   // 凌晨算前一天的夜里
        if hour >= 23 || hour < 4, nightNoticed != today {
            nightNoticed = today
            return Event(trigger: "night", emote: "🌙",
                         line: ["很晚了，早点睡吧", "熬夜对身体不好哦", "我都困了…你也早点休息"].randomElement(), proactive: true)
        }
        if Date().timeIntervalSince(lastTouch) > 45 * 60, ready("lonely", cooldown: 45 * 60) {
            adjust(-1)
            return Event(trigger: "lonely", emote: "💧",
                         line: ["你都好久没理我了…", "陪我玩一会儿嘛", "是不是把我忘了"].randomElement(), proactive: true)
        }
        return nil
    }

    /// 上屏：陪你打字也会慢慢涨好感（每天最多 +5）。
    func committed() {
        let key = "LianaPetAffectionTyping-" + PetStats.dayKey()
        let gained = UserDefaults.standard.double(forKey: key)
        guard gained < 5 else { return }
        UserDefaults.standard.set(gained + 0.05, forKey: key)
        adjust(+0.05)
    }

    /// 外部互动（部位反应、击掌成功……）带来的好感变化。
    func reward(_ delta: Double) {
        adjust(delta)
    }

    // MARK: - 内部

    private func recent(_ list: [Date], within seconds: TimeInterval) -> [Date] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return list.filter { $0 > cutoff }
    }

    private func ready(_ key: String, cooldown: TimeInterval) -> Bool {
        if let last = cooldowns[key], Date().timeIntervalSince(last) < cooldown { return false }
        cooldowns[key] = Date()
        return true
    }

    private func adjust(_ delta: Double) {
        affection = min(100, max(0, affection + delta))
        UserDefaults.standard.set(affection, forKey: affectionKey)
        UserDefaults.standard.set(PetStats.dayKey(), forKey: affectionDayKey)
    }

    /// 隔天没互动：每天回落 3 点，最低回到 20（不会因为放假就变成陌生人）。
    private func decayForMissedDays() {
        guard let last = UserDefaults.standard.string(forKey: affectionDayKey) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let lastDate = df.date(from: last) else { return }
        let days = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
        guard days > 1 else { return }
        let floor = min(affection, 20)
        affection = max(floor, affection - Double(days - 1) * 3)
        UserDefaults.standard.set(affection, forKey: affectionKey)
    }
}
