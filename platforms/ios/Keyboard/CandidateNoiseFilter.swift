import Foundation

/// 候选噪声过滤与九宫格漏键容错。
///
/// 纯逻辑，不依赖 UIKit / SQLite，`scripts/test-logic.sh` 直接跑。
///
/// 两件事：
/// 1. 混排候选（中文里夹拉丁字母或数字，如「看1080P」「2K一」）来自词库里
///    英数条目的前缀补全，拼起来不是一句话，一律不展示；
/// 2. 九宫格漏按一个数字时（想打「可以」keyi，按下 5 9 4，漏了 3），
///    补一位数字再查词库，把「可以」找回来。
enum CandidateNoiseFilter {
    /// 同时含汉字与拉丁字母/数字即视为混排噪声。
    static func isMixedScript(_ text: String) -> Bool {
        var hasHan = false
        var hasLatin = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                hasHan = true
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                hasLatin = true
            default:
                continue
            }
            if hasHan && hasLatin { return true }
        }
        return false
    }

    /// 九宫格数字串的「漏按/多按一位」变体：每个位置补 2–9，再逐个删一位。
    /// 只在整串查不到词条时使用；最多返回 `limit` 个，保证 SQL 次数有上限。
    /// 纠错优先补位（漏按），`includeDeletions: false` 时只补位——删位会切出
    /// 高频单字（94 → 一／以），把真正的整词压下去。
    static func digitVariants(_ raw: String, limit: Int = 48, includeDeletions: Bool = true) -> [String] {
        let digits = Array(raw)
        guard digits.count >= 2, digits.count <= 24, digits.allSatisfy({ $0.isNumber }) else { return [] }
        var output: [String] = []
        var seen = Set<String>([raw])
        for index in digits.indices {
            for digit in "23456789" {
                var variant = digits
                variant.insert(digit, at: index)
                let key = String(variant)
                if seen.insert(key).inserted { output.append(key) }
                if output.count >= limit { return output }
            }
        }
        guard includeDeletions else { return output }
        for index in digits.indices {
            var variant = digits
            variant.remove(at: index)
            guard variant.count >= 2 else { continue }
            let key = String(variant)
            if seen.insert(key).inserted { output.append(key) }
            if output.count >= limit { return output }
        }
        return output
    }
}
