import Foundation
import SQLite3

// KeyboardPayload.swift 依赖 UIKit，命令行测试里用同签名的最小结构体代替。
struct MobileWord: Codable, Equatable {
    var word: String
    var code: String
    var frequency: Int = 1000
    var kind: String = "pinyin"
    var reading: String? = nil
}

/// 九宫格漏键纠错。
///
/// 场景：想打「可以」keyi，九宫格是 5 3 9 4；漏按 3（e），只剩 5 9 4。
/// 期望候选首位是「可以」，而不是空白或逐字噪声。
///
/// 随包 `mobile.sqlite` 是构建产物、CI 上没有，所以这里优先用真词库，
/// 没有就现场建一个只含必要词条的同构夹具库（表结构与 `base.words` 一致）。
@main
struct T9MissingDigitLookupTests {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let real = root.appendingPathComponent("platforms/ios/Resources/mobile.sqlite")
        let forcedFixture = ProcessInfo.processInfo.environment["LIANA_T9_FIXTURE"] == "1"
        let source: URL
        if !forcedFixture, FileManager.default.fileExists(atPath: real.path) {
            source = real
        } else {
            source = makeFixture()
        }

        let lexicon = MobileLexicon(bundle: .main, baseURL: source)
        precondition(lexicon.hasBase, "词库没挂上：\(source.path)")
        precondition(lexicon.exactRanked("594", kind: "t9").isEmpty, "594 不应有精确候选（这正是漏键场景）")
        precondition(lexicon.exactRanked("5394", kind: "t9").first?.word == "可以", "5394 首位应为「可以」")

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

        print("九宫格漏键实测（\(source.lastPathComponent)）：594 → 首选「可以」；候选 \(ranked.prefix(4).map(\.word))")
    }

    /// 只含断言所需词条的夹具库：与 `base.words` 同列，独立于构建产物。
    private static func makeFixture() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liana-t9-fixture-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK, "夹具库打不开")
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE words(word TEXT, code TEXT, digits TEXT, freq INTEGER, kind TEXT, first TEXT, last TEXT, reading TEXT);
        INSERT INTO words VALUES('可以','keyi','5394',472367,'pinyin','k','i','keyi');
        INSERT INTO words VALUES('可惜','kexi','5394',11495,'pinyin','k','x','kexi');
        INSERT INTO words VALUES('辣子','lazi','5294',10328,'pinyin','l','z','lazi');
        INSERT INTO words VALUES('一','yi','94',647414,'pinyin','y','i','yi');
        INSERT INTO words VALUES('以','yi','94',500662,'pinyin','y','i','yi');
        INSERT INTO words VALUES('已','yi','94',173213,'pinyin','y','i','yi');
        """
        precondition(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "夹具库建表失败")
        return url
    }
}
