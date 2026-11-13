import Foundation
import SQLite3

/// Disk-backed indexes keep nine-key and shape input out of the Rust dictionary's
/// memory budget. All access is serialized by MobileEngine.
final class MobileLexicon {
    private var database: OpaquePointer?
    /// 随包只读词库是否挂上。挂不上时仍可用用户词库，不能让查询整条失效。
    private(set) var hasBase = false
    /// 随包词库是否带类别标签表（旧库没有 tags 表时优雅降级为「没有标签」）。
    private(set) var hasTags = false
    private var tagCache: [String: Bool] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keyboard", isDirectory: true)

    init(bundle: Bundle, baseURL: URL? = nil) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = Self.directory.appendingPathComponent("personal.sqlite").path
        guard sqlite3_open(path, &database) == SQLITE_OK else { return }
        execute("PRAGMA cache_size=-512; PRAGMA journal_mode=WAL;")
        execute("CREATE TABLE IF NOT EXISTS words(word TEXT,code TEXT,digits TEXT,freq INTEGER,kind TEXT,reading TEXT,PRIMARY KEY(word,code,kind)); CREATE INDEX IF NOT EXISTS custom_code ON words(kind,code); CREATE INDEX IF NOT EXISTS custom_digits ON words(digits); CREATE TABLE IF NOT EXISTS learned(word TEXT,code TEXT,n INTEGER,PRIMARY KEY(word,code)); CREATE INDEX IF NOT EXISTS learned_code ON learned(code);")
        execute("ALTER TABLE words ADD COLUMN reading TEXT")
        if let base = baseURL ?? bundle.url(forResource: "mobile", withExtension: "sqlite") {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, "ATTACH DATABASE ? AS base", -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, base.path, -1, transient)
                hasBase = sqlite3_step(statement) == SQLITE_DONE
            }
            sqlite3_finalize(statement)
            if hasBase {
                var check: OpaquePointer?
                if sqlite3_prepare_v2(database, "SELECT 1 FROM base.sqlite_master WHERE type='table' AND name='tags'", -1, &check, nil) == SQLITE_OK {
                    hasTags = sqlite3_step(check) == SQLITE_ROW
                }
                sqlite3_finalize(check)
            }
        }
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) { sqlite3_exec(database, sql, nil, nil, nil) }
    static func digits(_ code: String) -> String {
        let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
        return code.lowercased().compactMap { c in groups.firstIndex(where: { $0.contains(c) }).map { String($0 + 2) } }.joined()
    }
    func importWords(_ words: [MobileWord]) -> Int {
        execute("BEGIN IMMEDIATE")
        defer { execute("COMMIT") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO words(word,code,digits,freq,kind,reading) VALUES(?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        var count = 0
        for entry in words.prefix(20_000) where !entry.word.isEmpty && !entry.code.isEmpty && entry.word.count <= 64 && entry.code.count <= 128 && ["pinyin", "wubi"].contains(entry.kind) && !entry.word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            sqlite3_reset(statement)
            let code = entry.code.lowercased().replacingOccurrences(of: "ü", with: "v").filter { $0.isASCII && $0.isLetter }
            guard !code.isEmpty else { continue }
            let reading = entry.reading ?? entry.code
            guard reading.count <= 128, reading.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " " || $0 == "'") }) else { continue }
            for (i, value) in [entry.word, code, Self.digits(code)].enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
            sqlite3_bind_int64(statement, 4, Int64(max(1, min(10_000_000, entry.frequency))))
            sqlite3_bind_text(statement, 5, entry.kind, -1, transient)
            sqlite3_bind_text(statement, 6, reading, -1, transient)
            if sqlite3_step(statement) == SQLITE_DONE { count += 1 }
        }
        return count
    }
    func lookup(_ raw: String, kind: String, customOnly: Bool = false, limit: Int = 9) -> [MobileWord] {
        guard !raw.isEmpty, raw.count <= 64 else { return [] }
        let column = kind == "t9" ? "digits" : "code"
        let realKind = kind == "t9" ? "pinyin" : kind
        let base = customOnly || !hasBase ? "" : " UNION ALL SELECT word,code,freq,kind,\(column) AS matchKey FROM base.words WHERE kind=? AND \(column)>=? AND \(column)<?"
        let sql = "SELECT w.word,w.code,MAX(w.freq),w.kind FROM (SELECT word,code,freq,kind,\(column) AS matchKey FROM words WHERE kind=? AND \(column)>=? AND \(column)<?\(base)) w LEFT JOIN learned l ON l.word=w.word AND l.code=? GROUP BY w.word ORDER BY MAX(w.matchKey=?) DESC,MAX(IFNULL(l.n,0)) DESC,MAX(w.freq) DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var args = [realKind, raw, raw + "~"]
        if !customOnly && hasBase { args += [realKind, raw, raw + "~"] }
        args.append(raw)
        args.append(raw)
        for (i, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        sqlite3_bind_int(statement, Int32(args.count + 1), Int32(limit))
        var output: [MobileWord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(MobileWord(word: text(statement, 0), code: text(statement, 1), frequency: Int(sqlite3_column_int64(statement, 2)), kind: text(statement, 3)))
        }
        return output
    }
    /// 单字读音集合（拼音音节），用于把整词 code 拆成「jin tian」这样的可读拼音。
    /// 从词库里的单字条目派生，不另存音节表。
    private var cachedSyllables: [String]?
    func syllables() -> [String] {
        if let cachedSyllables { return cachedSyllables }
        let sql = hasBase
            ? "SELECT DISTINCT code FROM words WHERE kind='pinyin' AND LENGTH(word)=1 UNION SELECT DISTINCT code FROM base.words WHERE kind='pinyin' AND LENGTH(word)=1"
            : "SELECT DISTINCT code FROM words WHERE kind='pinyin' AND LENGTH(word)=1"
        var statement: OpaquePointer?
        var values: Set<String> = []
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let code = text(statement, 0)
                if !code.isEmpty, code.count <= 6, code.allSatisfy({ $0.isASCII && $0.isLetter }) { values.insert(code) }
            }
        }
        let sorted = values.sorted { $0.count > $1.count }
        cachedSyllables = sorted
        return sorted
    }

    /// 单个音节取单字最高频候选（「永远不会没有候选」的音节兜底用）。
    func singleCharacter(for code: String) -> String? {
        exact(code, kind: "pinyin", limit: 8).first(where: { $0.word.count == 1 })?.word
    }

    /// 类别标签（place/person）：数据缺失或旧库没有 tags 表时返回 false。
    func hasTag(_ word: String, tag: String) -> Bool {
        guard hasTags, !word.isEmpty, !tag.isEmpty, word.count <= 64 else { return false }
        let token = tag + "|" + word
        if let cached = tagCache[token] { return cached }
        var value = false
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT 1 FROM base.tags WHERE word=? AND tag=? LIMIT 1", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, word, -1, transient)
            sqlite3_bind_text(statement, 2, tag, -1, transient)
            value = sqlite3_step(statement) == SQLITE_ROW
        }
        sqlite3_finalize(statement)
        if tagCache.count < 1024 { tagCache[token] = value }
        return value
    }

    /// 整串精确命中并返回学习次数（用于「学习 > 上下文 > 会话」排序）。
    func exactRanked(_ key: String, kind: String, limit: Int = 9) -> [(word: String, frequency: Int, learned: Int)] {
        guard !key.isEmpty, key.count <= 64 else { return [] }
        let column = kind == "t9" ? "digits" : "code"
        let realKind = kind == "t9" ? "pinyin" : kind
        let layer = hasBase ? " UNION ALL SELECT word,code,freq,kind FROM base.words WHERE kind=? AND \(column)=?" : ""
        let sql = "SELECT w.word,MAX(w.freq),MAX(IFNULL(l.n,0)) AS learned FROM (SELECT word,code,freq,kind FROM words WHERE kind=? AND \(column)=?\(layer)) w LEFT JOIN learned l ON l.word=w.word AND l.code=? GROUP BY w.word ORDER BY learned DESC, MAX(w.freq) DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var args = [realKind, key]
        if hasBase { args += [realKind, key] }
        args.append(key)
        for (i, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        sqlite3_bind_int(statement, Int32(args.count + 1), Int32(limit))
        var output: [(word: String, frequency: Int, learned: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append((text(statement, 0), Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 2))))
        }
        return output
    }

    /// 用户学习过的词（可能只存在于 learned 表，例如整句候选）。
    func learnedWords(code: String, limit: Int = 24) -> [String] {
        guard !code.isEmpty, code.count <= 128 else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT word FROM learned WHERE code=? ORDER BY n DESC, word LIMIT ?", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, code, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var output: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { output.append(text(statement, 0)) }
        return output
    }

    /// 清空学习记录（重置 / 测试隔离）。
    func resetLearning() {
        execute("DELETE FROM learned")
    }

    /// 词库是否收录该词（诊断/回归测试用；只查索引列）。
    func contains(word: String, code: String, kind: String = "pinyin") -> Bool {
        guard !word.isEmpty, !code.isEmpty, code.count <= 64 else { return false }
        let column = kind == "t9" ? "digits" : "code"
        let realKind = kind == "t9" ? "pinyin" : kind
        let layer = hasBase ? " UNION ALL SELECT word FROM base.words WHERE kind=? AND \(column)=? AND word=?" : ""
        let sql = "SELECT 1 FROM (SELECT word FROM words WHERE kind=? AND \(column)=? AND word=?\(layer)) LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        var args = [realKind, code, word]
        if hasBase { args += [realKind, code, word] }
        for (i, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 分段组合用的精确匹配：本地词库与随包词库中 code（或九宫格 digits）完全相同的词条。
    /// 命中按「学过的次数 → 词频」排序，供整句分段时挑选每个音节的代表词。
    func exact(_ key: String, kind: String, limit: Int = 6) -> [MobileWord] {
        guard !key.isEmpty, key.count <= 64 else { return [] }
        let column = kind == "t9" ? "digits" : "code"
        let realKind = kind == "t9" ? "pinyin" : kind
        let layer = hasBase ? " UNION ALL SELECT word,code,freq,kind FROM base.words WHERE kind=? AND \(column)=?" : ""
        let sql = "SELECT w.word,w.code,w.freq,w.kind FROM (SELECT word,code,freq,kind FROM words WHERE kind=? AND \(column)=?\(layer)) w LEFT JOIN learned l ON l.word=w.word AND l.code=? GROUP BY w.word ORDER BY MAX(IFNULL(l.n,0)) DESC, MAX(w.freq) DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var args = [realKind, key]
        if hasBase { args += [realKind, key] }
        args.append(key)
        for (i, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        sqlite3_bind_int(statement, Int32(args.count + 1), Int32(limit))
        var output: [MobileWord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(MobileWord(word: text(statement, 0), code: text(statement, 1), frequency: Int(sqlite3_column_int64(statement, 2)), kind: text(statement, 3)))
        }
        return output
    }

    func learn(_ word: String, raw: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO learned VALUES(?,?,1) ON CONFLICT(word,code) DO UPDATE SET n=MIN(n+1,1000)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, word, -1, transient); sqlite3_bind_text(statement, 2, raw, -1, transient)
        sqlite3_step(statement)
    }
    func shortcuts(_ raw: String) -> [MobileWord] {
        guard !raw.isEmpty, raw.count <= 64 else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT word,code,freq FROM words WHERE kind='pinyin' AND code=? AND LOWER(REPLACE(REPLACE(COALESCE(reading,code),' ',''),char(39),''))<>code ORDER BY freq DESC LIMIT 9"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, raw, -1, transient)
        var result: [MobileWord] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(MobileWord(word: text(statement, 0), code: text(statement, 1), frequency: Int(sqlite3_column_int64(statement, 2)))) }
        return result
    }
    func glideWords(first: Character, last: Character, english: Bool) -> [MobileWord] {
        var statement: OpaquePointer?
        let sql = "SELECT word,code,freq,kind FROM base.words WHERE kind=? AND first=? AND last=? ORDER BY freq DESC LIMIT 800"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (i, value) in [english ? "en" : "pinyin", String(first), String(last)].enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        var result: [MobileWord] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(MobileWord(word: text(statement, 0), code: text(statement, 1), frequency: Int(sqlite3_column_int64(statement, 2)), kind: text(statement, 3))) }
        return result
    }
    func exportPinyinLayer() -> URL {
        let folder = Self.directory.appendingPathComponent("dicts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var statement: OpaquePointer?
        var lines: [String] = []
        if sqlite3_prepare_v2(database, "SELECT word,COALESCE(reading,code),freq FROM words WHERE kind='pinyin' LIMIT 20000", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW { lines.append("\(text(statement, 0))\t\(text(statement, 1))\t\(sqlite3_column_int64(statement, 2))") }
        }
        sqlite3_finalize(statement)
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("personal.tsv"), atomically: true, encoding: .utf8)
        return folder
    }
    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
