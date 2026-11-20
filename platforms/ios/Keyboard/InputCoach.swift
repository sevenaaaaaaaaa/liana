import Foundation

/// 「输入教练」的账本：按天记键数、上屏字数、删除、选词与首选命中。
///
/// 为什么要在键盘里记：语音、翻译、学习都在键盘扩展的沙盒里，宿主 app
/// 读不到。这些数字只存在本机 UserDefaults，不上传、不跨设备。
final class InputCoach {
    static let shared = InputCoach()

    struct Day: Codable, Equatable {
        var keys = 0
        var chars = 0
        var deletes = 0
        var selections = 0
        var top1Hits = 0
        var voiceChars = 0
    }

    struct Report {
        var windowDays: Int
        var activeDays: Int
        var keys: Int
        var chars: Int
        var deletes: Int
        var selections: Int
        var top1Hits: Int

        /// 首选命中率（百分数）。没有选词时为 0。
        var top1Rate: Double {
            selections > 0 ? Double(top1Hits) / Double(selections) * 100 : 0
        }
        /// 省下的击键：上屏字数 − 按键数，只取正的部分。
        var savedKeys: Int { max(0, chars - keys) }
        /// 每字平均按键数：越接近 1 越省。
        var keysPerChar: Double {
            chars > 0 ? Double(keys) / Double(chars) : 0
        }
    }

    private let storageKey = "coach.days.v2"
    private let defaults: UserDefaults
    private var days: [String: Day]

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
        prune()
    }

    // MARK: - 记账

    func noteKey() { mutate { $0.keys += 1 } }
    func noteDelete() { mutate { $0.deletes += 1 } }

    func noteChars(_ count: Int) {
        guard count > 0 else { return }
        mutate { $0.chars += count }
    }

    func noteVoice(_ count: Int) {
        guard count > 0 else { return }
        mutate { $0.voiceChars += count }
    }

    /// 选词：index 0 就是首选命中。
    func noteSelection(index: Int) {
        mutate {
            $0.selections += 1
            if index == 0 { $0.top1Hits += 1 }
        }
    }

    private func mutate(_ change: (inout Day) -> Void) {
        let key = Self.dayKey.string(from: Date())
        var today = days[key] ?? Day()
        change(&today)
        days[key] = today
        save()
    }

    // MARK: - 读

    /// 最近 n 天（含今天）的汇总。只统计有记录的日期。
    func report(days window: Int = 7) -> Report {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var totals = Day()
        var active = 0
        for offset in 0..<max(1, window) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard let day = days[Self.dayKey.string(from: date)] else { continue }
            if day.keys == 0 && day.chars == 0 && day.voiceChars == 0 { continue }
            active += 1
            totals.keys += day.keys
            totals.chars += day.chars + day.voiceChars
            totals.deletes += day.deletes
            totals.selections += day.selections
            totals.top1Hits += day.top1Hits
        }
        return Report(windowDays: window, activeDays: active, keys: totals.keys,
                      chars: totals.chars, deletes: totals.deletes,
                      selections: totals.selections, top1Hits: totals.top1Hits)
    }

    func today() -> Day { days[Self.dayKey.string(from: Date())] ?? Day() }

    func reset() {
        days = [:]
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - 落盘

    private func save() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// 只留最近 30 天，别让账本无限长。
    private func prune() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let cutoff = calendar.date(byAdding: .day, value: -30, to: today) else { return }
        let limit = Self.dayKey.string(from: cutoff)
        days = days.filter { $0.key >= limit }
    }
}
