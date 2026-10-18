import Foundation

/// 桌宠互动：点在哪个部位、连续怎么点 → 什么反应；并在本机长期学习「你喜欢怎么跟它玩」。
///
/// 学习只用互动节奏：你点了哪个部位、某个反应之后有没有接着跟它玩（8 秒内再互动 = 喜欢这个反应）。
/// 不涉及任何输入内容；数据只存在本机偏好里，可在右键菜单里清空。
final class PetInteraction {
    static let shared = PetInteraction()

    enum Region: String, CaseIterable {
        case head, face, body, hand, feet, miss

        var title: String {
            switch self {
            case .head: return "摸头"
            case .face: return "戳脸"
            case .body: return "挠痒痒"
            case .hand: return "击掌"
            case .feet: return "踩脚"
            case .miss: return "逗它找你"
            }
        }
    }

    struct Reaction {
        let trigger: String
        let line: String?
        let emote: String?
        /// 好感度变化
        let affection: Double
        /// 正面反应：非纸偶形象用「摸头」反馈代替
        let positive: Bool
    }

    private let prefsKey = "LianaPetActionPrefs"
    private let regionKey = "LianaPetRegionCounts"

    /// 触发器 → 动作 → 喜好分（0…1，初始 0.5）
    private var prefs: [String: [String: Double]]
    private var regionCounts: [String: Int]
    private var lastPlayed: (trigger: String, action: String, at: Date, rewarded: Bool)?
    private var taps: [(region: Region, at: Date)] = []
    private var highFiveDeadline: Date?
    private var invited: (region: Region, deadline: Date)?
    private var lastInvite = Date()

    private init() {
        let defaults = UserDefaults.standard
        prefs = (defaults.dictionary(forKey: prefsKey) as? [String: [String: Double]]) ?? [:]
        regionCounts = (defaults.dictionary(forKey: regionKey) as? [String: Int]) ?? [:]
    }

    // MARK: - 点击

    /// 点了某个部位 → 反应（含连续点击的「下一步」）。
    func tapped(_ region: Region) -> Reaction {
        let now = Date()
        noteInteraction()
        regionCounts[region.rawValue, default: 0] += 1
        UserDefaults.standard.set(regionCounts, forKey: regionKey)
        taps = taps.filter { now.timeIntervalSince($0.at) < 8 } + [(region, now)]
        let streak = taps.reversed().prefix { $0.region == region && now.timeIntervalSince($0.at) < 5 }.count

        // 等着击掌时点到手 → 击掌成功
        if let deadline = highFiveDeadline, now < deadline, region == .hand {
            highFiveDeadline = nil
            return Reaction(trigger: "highfive", line: ["耶！击掌成功！", "好默契！", "啪！✋"].randomElement(),
                            emote: "✨", affection: 1.5, positive: true)
        }
        // 主动邀请后点对了地方 → 额外开心
        if let invite = invited, now < invite.deadline, invite.region == region {
            invited = nil
            return Reaction(trigger: trigger(for: region, streak: 1), line: ["就是这里～", "你还记得！", "嘿嘿，最喜欢这样了"].randomElement(),
                            emote: "❤️", affection: 1.2, positive: true)
        }

        let level = PetEmotion.shared.level
        switch region {
        case .head:
            let lines: [[String]] = [["嗯…谢谢", "你好呀"], ["嘿嘿～", "好舒服"], ["再摸一下嘛", "最喜欢被摸头了"], ["要一直摸哦", "幸福～"]]
            return Reaction(trigger: "tap_head", line: lines[level].randomElement(), emote: nil, affection: 0, positive: true)
        case .face:
            if streak >= 2 {
                return Reaction(trigger: "tap_face2", line: streak >= 3 ? "哼！脸都被戳红了" : "别戳脸啦！",
                                emote: "😤", affection: -0.3, positive: false)
            }
            return Reaction(trigger: "tap_face", line: ["嗯？", "怎么啦？", "脸上有东西吗？"].randomElement(), emote: nil, affection: 0.2, positive: true)
        case .body:
            if streak >= 2 {
                return Reaction(trigger: "tap_body2", line: ["哈哈哈哈别挠了！", "投降投降！"].randomElement(), emote: nil, affection: 0.5, positive: true)
            }
            return Reaction(trigger: "tap_body", line: ["好痒～", "嘻嘻"].randomElement(), emote: nil, affection: 0.3, positive: true)
        case .hand:
            highFiveDeadline = now.addingTimeInterval(3.2)
            return Reaction(trigger: "tap_hand", line: "击个掌！", emote: nil, affection: 0.2, positive: true)
        case .feet:
            return Reaction(trigger: "tap_feet", line: ["踩到我脚了！", "哎哟哟"].randomElement(), emote: nil, affection: 0, positive: false)
        case .miss:
            return Reaction(trigger: "tap_miss", line: ["你在点哪儿呀？", "我在这儿～"].randomElement(), emote: nil, affection: 0, positive: false)
        }
    }

    private func trigger(for region: Region, streak: Int) -> String {
        switch region {
        case .head: return "tap_head"
        case .face: return "tap_face"
        case .body: return "tap_body"
        case .hand: return "highfive"
        case .feet: return "tap_feet"
        case .miss: return "tap_miss"
        }
    }

    /// 举手后没等到击掌 → 小委屈（由调用方在截止时间后调用）。
    func highFiveMissed() -> Reaction? {
        guard let deadline = highFiveDeadline, Date() >= deadline else { return nil }
        highFiveDeadline = nil
        return Reaction(trigger: "highfive_miss", line: ["哼，不跟我击掌…", "手都举酸了"].randomElement(),
                        emote: nil, affection: -0.2, positive: false)
    }

    // MARK: - 学习

    /// 页面上报「刚播了哪个动作」：上一条若一直没人理，记一次「不太喜欢」。
    func played(trigger: String, action: String) {
        if let last = lastPlayed, !last.rewarded {
            reward(last.trigger, last.action, 0)
        }
        lastPlayed = (trigger, action, Date(), false)
    }

    /// 任意直接互动：上一个反应 8 秒内被接着互动 → 喜欢这个反应。
    func noteInteraction() {
        guard let last = lastPlayed, !last.rewarded else { return }
        let liked = Date().timeIntervalSince(last.at) < 8
        reward(last.trigger, last.action, liked ? 1 : 0)
        lastPlayed?.rewarded = true
    }

    private func reward(_ trigger: String, _ action: String, _ value: Double) {
        var table = prefs[trigger] ?? [:]
        let old = table[action] ?? 0.5
        table[action] = old * 0.8 + value * 0.2
        prefs[trigger] = table
        UserDefaults.standard.set(prefs, forKey: prefsKey)
    }

    /// 某触发器下各动作的权重：喜欢的出现得更多，但永远保留一点新鲜感（最低 0.3）。
    func weights(for trigger: String) -> [String: Double] {
        (prefs[trigger] ?? [:]).mapValues { 0.3 + $0 * 1.4 }
    }

    /// 最常互动的部位（至少互动过 10 次才算数）。
    var favoriteRegion: Region? {
        let total = regionCounts.values.reduce(0, +)
        guard total >= 10,
              let best = regionCounts.filter({ $0.key != Region.miss.rawValue }).max(by: { $0.value < $1.value }),
              let region = Region(rawValue: best.key) else { return nil }
        return region
    }

    /// 偶尔主动邀请你用最喜欢的方式跟它玩（每 15～25 分钟最多一次）。
    func invite() -> Reaction? {
        guard Date().timeIntervalSince(lastInvite) > Double.random(in: 900...1500),
              let region = favoriteRegion else { return nil }
        lastInvite = Date()
        invited = (region, Date().addingTimeInterval(8))
        let lines: [Region: String] = [
            .head: "摸摸头？", .face: "要不要戳戳我的脸～", .body: "来挠挠我呀", .hand: "击个掌？", .feet: "我脚不疼了，再来？",
        ]
        if region == .hand { highFiveDeadline = Date().addingTimeInterval(8) }
        return Reaction(trigger: region == .hand ? "tap_hand" : "invite", line: lines[region], emote: "🥺", affection: 0, positive: true)
    }

    /// 清空学到的互动偏好。
    func forget() {
        prefs = [:]
        regionCounts = [:]
        UserDefaults.standard.removeObject(forKey: prefsKey)
        UserDefaults.standard.removeObject(forKey: regionKey)
    }
}
