import Foundation

// KeyboardPayload.swift 依赖 UIKit，命令行测试里用同签名的最小结构体代替。
struct MobileWord: Codable, Equatable {
    var word: String
    var code: String
    var frequency: Int = 1000
    var kind: String = "pinyin"
    var reading: String? = nil
}

/// 九宫格漏键纠错，跑在真实的随包词库上（不是 mock）。
///
/// 场景：想打「可以」keyi，九宫格是 5 3 9 4；漏按 3（e），只剩 5 9 4。
/// 期望候选首位是「可以」，而不是空白或逐字噪声。
@main
struct T9MissingDigitLookupTests {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let base = root.appendingPathComponent("platforms/ios/Resources/mobile.sqlite")
        precondition(FileManager.default.fileExists(atPath: base.path), "找不到随包词库 mobile.sqlite")
        let lexicon = MobileLexicon(bundle: .main, baseURL: base)
        precondition(lexicon.hasBase, "随包词库没挂上")

        precondition(lexicon.exactRanked("594", kind: "t9").isEmpty, "594 不应有精确候选（这正是漏键场景）")
        precondition(lexicon.exactRanked("5394", kind: "t9").first?.word == "可以", "词库 5394 首位应为「可以」")

        var fuzzy: [(word: String, frequency: Int, learned: Int)] = []
        var seen = Set<String>()
        for variant in CandidateNoiseFilter.digitVariants("594", includeDeletions: false) {
            for word in lexicon.exactRanked(variant, kind: "t9", limit: 3) where seen.insert(word.word).inserted {
                fuzzy.append(word)
            }
            if fuzzy.count >= 12 { break }
        }
        let ranked = fuzzy.sorted { $0.learned != $1.learned ? $0.learned > $1.learned : $0.frequency > $1.frequency }
        precondition(ranked.first?.word == "可以", "漏按 3 的 k yi 首位必须是「可以」，实际：\(ranked.prefix(3).map(\.word))")

        print("九宫格漏键实测：594（k yi，漏 e）→ 首选「可以」；候选 \(ranked.prefix(4).map(\.word))")
    }
}
