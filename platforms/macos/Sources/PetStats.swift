import AppKit
import Foundation

/// 输入统计：只计数、不存内容。键数/删除/回车/上屏字数/节省击键/活跃秒数/最长发呆。
/// 数据存 UserDefaults（与按应用记忆同级的行为元数据），保留最近 7 天，可一键清空。
final class PetStats {
    static let shared = PetStats()

    struct Day: Codable {
        var chars = 0
        var keys = 0
        var deletes = 0
        var enters = 0
        var saved = 0
        var voice = 0
        var activeSecs = 0.0
        var stareMaxSecs = 0.0
        // ——— 知你评估层（E3）：选词质量 ———
        var selections = 0
        var top1 = 0
        var baseTop1 = 0
        var reselects = 0

        var isEmpty: Bool {
            chars == 0 && keys == 0 && deletes == 0 && enters == 0 && voice == 0 && selections == 0
        }

        init() {}

        /// 旧档兼容：E3 之前存的天没有选词质量字段，缺省为 0。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chars = try c.decodeIfPresent(Int.self, forKey: .chars) ?? 0
            keys = try c.decodeIfPresent(Int.self, forKey: .keys) ?? 0
            deletes = try c.decodeIfPresent(Int.self, forKey: .deletes) ?? 0
            enters = try c.decodeIfPresent(Int.self, forKey: .enters) ?? 0
            saved = try c.decodeIfPresent(Int.self, forKey: .saved) ?? 0
            voice = try c.decodeIfPresent(Int.self, forKey: .voice) ?? 0
            activeSecs = try c.decodeIfPresent(Double.self, forKey: .activeSecs) ?? 0
            stareMaxSecs = try c.decodeIfPresent(Double.self, forKey: .stareMaxSecs) ?? 0
            selections = try c.decodeIfPresent(Int.self, forKey: .selections) ?? 0
            top1 = try c.decodeIfPresent(Int.self, forKey: .top1) ?? 0
            baseTop1 = try c.decodeIfPresent(Int.self, forKey: .baseTop1) ?? 0
            reselects = try c.decodeIfPresent(Int.self, forKey: .reselects) ?? 0
        }
    }

    private let storeKey = "LianaStatsDays"
    private let enabledKey = "LianaStatsEnabled"

    /// 内存态缓存：计数每键都在涨，但没必要每键都「解码 JSON → 改 → 编码 → 写
    /// UserDefaults（cfprefsd IPC + 落盘）」。内存里改，1.5 秒静默后再落盘一次；
    /// 退出前 flush。统计值不变，只是延迟写。
    private var cache: [String: Day] = [:]
    private var loaded = false
    private var saveWork: DispatchWorkItem?
    private var enabledCache: Bool?

    private init() {
        // 进程被杀前尽量把最后几秒的计数落盘
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        }
    }

    var isEnabled: Bool {
        get {
            if let cached = enabledCache { return cached }
            let value = UserDefaults.standard.object(forKey: enabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: enabledKey)
            enabledCache = value
            return value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            enabledCache = newValue
            if !newValue {
                wipeAll()
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let dict = try? JSONDecoder().decode([String: Day].self, from: data)
        else { return }
        cache = dict
    }

    private func days() -> [String: Day] {
        loadIfNeeded()
        return cache
    }

    /// 内存态写回：保留最近 7 天，延迟合并成一次编码 + 一次 UserDefaults 写。
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 立即落盘（退出 / 设置页读取前的兜底）。
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard loaded else { return }
        let cutoff = Self.dayKey(Date().addingTimeInterval(-7 * 86_400))
        cache = cache.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    /// 与界面展示同源的日期键（本地时区）。DateFormatter 创建很贵，复用同一个。
    static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func mutate(_ transform: (inout Day) -> Void) {
        guard isEnabled else { return }
        var days = days()
        let key = Self.dayKey()
        var day = days[key] ?? Day()
        transform(&day)
        days[key] = day
        cache = days
        scheduleSave()
    }

    // MARK: - 记录（InputController 调）

    func recordKeys(_ n: Int) { mutate { $0.keys += n } }
    func recordDelete() { mutate { $0.deletes += 1 } }
    func recordEnter() { mutate { $0.enters += 1 } }
    /// 上屏：`keys` 是本次组合消耗的按键数，节省 = keys − 字数（为正才计）。
    func recordCommit(chars: Int, keys: Int) {
        mutate {
            $0.chars += chars
            $0.saved += max(0, keys - chars)
        }
    }
    /// 语音上屏（端上语音路径接通后计入）。
    func recordVoice(chars: Int) { mutate { $0.voice += chars } }
    /// 两次按键间隔 < 10s 计为活跃打字时间。
    func recordActive(seconds: Double) {
        mutate { $0.activeSecs += seconds }
    }
    /// 一次发呆结束（间隔 ≥ 5s），保留当天最长。
    func recordStare(seconds: Double) {
        mutate { $0.stareMaxSecs = max($0.stareMaxSecs, seconds) }
    }

    /// 一次选词的评估（E3）：实际/反事实首选命中与重选，喂给傍晚小结的学习收益对比。
    func recordSelection(_ eval: SelectionEvalData) {
        mutate {
            $0.selections += 1
            if eval.actualTop1 { $0.top1 += 1 }
            if eval.baseTop1 { $0.baseTop1 += 1 }
            if eval.reselect { $0.reselects += 1 }
        }
    }

    // MARK: - 读取

    func day(_ key: String) -> Day {
        days()[key] ?? Day()
    }

    var today: Day { day(Self.dayKey()) }

    var yesterday: Day { day(Self.dayKey(Date().addingTimeInterval(-86_400))) }

    func wipeAll() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        cache = [:]
        loaded = true
    }

    // MARK: - 指标（内核计算）

    struct Digest: Codable {
        let speed_cpm: Double
        let accuracy: Double
        let kcal: Double
        let saved_keys: Int
        let voice_chars: Int
        let deletes: Int
        let enters: Int
        let stare_max_secs: Int
        let top1_rate: Double
        let base_top1_rate: Double
        let reselect_rate: Double
    }

    /// 调内核把一天计数折算成指标（速度/准确率/卡路里/选词质量）。
    static func digest(_ day: Day) -> Digest? {
        let json = liana_stats_digest_json(
            UInt64(max(0, day.chars)), UInt64(max(0, day.keys)),
            UInt64(max(0, day.deletes)), UInt64(max(0, day.enters)),
            UInt64(max(0, day.saved)), UInt64(max(0, day.voice)),
            UInt64(max(0, Int(day.activeSecs))), UInt64(max(0, Int(day.stareMaxSecs))),
            UInt64(max(0, day.selections)), UInt64(max(0, day.top1)),
            UInt64(max(0, day.baseTop1)), UInt64(max(0, day.reselects))
        )
        guard let json else { return nil }
        defer { liana_free_string(json) }
        guard
            let data = String(cString: json).data(using: .utf8),
            let digest = try? JSONDecoder().decode(Digest.self, from: data)
        else { return nil }
        return digest
    }

    /// 总结文案（多行，用于桌宠气泡卡片）。
    static func summaryText(for day: Day, title: String) -> String? {
        guard let d = digest(day) else { return nil }
        func dur(_ secs: Int) -> String {
            secs >= 60 ? "\(secs / 60) 分 \(secs % 60) 秒" : "\(secs) 秒"
        }
        var lines = ["📊 \(title)"]
        if day.isEmpty {
            lines.append("还没有输入记录，明天来看看吧")
            return lines.joined(separator: "\n")
        }
        lines.append("速度 \(Int(d.speed_cpm.rounded())) 字/分 · 准确率 \(Int(d.accuracy.rounded()))%")
        var third = "纠错 \(d.deletes) 次 · 回车 \(d.enters) 次"
        if d.saved_keys > 0 {
            third += " · 省了 \(d.saved_keys) 次击键"
        }
        lines.append(third)
        var fourth = "最长发呆 \(dur(d.stare_max_secs)) · ≈\(String(format: "%.1f", d.kcal)) 千卡"
        if d.voice_chars > 0 {
            fourth += " · 语音 \(d.voice_chars) 字"
        }
        lines.append(fourth)
        // 知你评估层（E3）：选词质量与学习收益（反事实对比）
        if day.selections > 0 {
            var fifth = "首选命中 \(Int(d.top1_rate.rounded()))% · 重选 \(day.reselects) 次"
            let gain = d.top1_rate - d.base_top1_rate
            if gain >= 0.5 {
                fifth += "\n🎯 知你学习：首选命中比无学习高 \(Int(gain.rounded())) 个百分点"
            }
            lines.append(fifth)
        }
        return lines.joined(separator: "\n")
    }
}
