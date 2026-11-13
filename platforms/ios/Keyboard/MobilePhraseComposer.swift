import Foundation

/// 多词/整句拼音的分段补全。
///
/// 全拼走 Rust 会话、九宫格走本地 SQLite，两条路都可能拿不到多词候选：
/// - 九宫格的长数字串没有对应的整词条目，前缀匹配返回空 → 候选栏空白；
/// - 设备上随包词典加载失败（内存受限）时会话为空，全拼只剩词库前缀匹配，
///   同样无法识别多音节整句。
///
/// 这里用随包词库 + 用户词库做「分段组合」：把整串输入切成若干个词再拼回整句候选。
/// 目标是「段数最少、词频最高」——同一串数字（九宫格）可以切出很多组合，段数少
/// 的切法更接近用户想输入的那句话；段数相同时用词频决定。
/// 不内置任何词条，也不针对具体句子做特判：候选都来自当前词库里真实存在的词条。
///
/// 九宫格的组合串本身是数字，顶栏不能直接展示；reading 复用同一份分段结果，
/// 用词条读音还原成「jin tian tian qi」这样的可读拼音。
final class MobilePhraseComposer {
    struct Segment {
        let key: String
        /// 该音节的候选词，按本地学习次数与词频降序。
        let words: [String]
        /// 与 words 一一对应的读音（拼音 code）。
        let codes: [String]
        /// 尾段按前缀补全（用户还在打最后一个音节）。
        let completed: Bool

        var best: String { words.first ?? "" }
        var bestCode: String { codes.first ?? key }
    }

    let lexicon: MobileLexicon
    /// 单段最长查询长度：约 6 个音节，足够覆盖常见词组，又不让 SQL 次数失控。
    private let maxSegmentLength: Int
    private let maxSegments: Int
    private var cachedRaw: String?
    private var cachedKind: String?
    private var cachedSegments: [Segment]?
    private var cachedSyllableSet: Set<String>?
    /// 跨按键缓存精确/前缀查询：每次按键只新增「新后缀」那几条 SQL。
    private var cachedLookups: [String: [MobileWord]] = [:]

    /// 学习记录/词库变化后清空结果缓存，避免用旧排序。
    func invalidateCache() {
        cachedRaw = nil
        cachedKind = nil
        cachedSegments = nil
        cachedLookups.removeAll()
    }

    init(lexicon: MobileLexicon, maxSegmentLength: Int = 24, maxSegments: Int = 24) {
        self.lexicon = lexicon
        self.maxSegmentLength = max(1, maxSegmentLength)
        self.maxSegments = max(1, maxSegments)
    }

    /// 整句候选。首候选是最优分段，其后是同段换词得到的近似候选。
    func candidates(_ raw: String, kind: String, limit: Int = 24) -> [String] {
        guard limit > 0, let segments = segments(raw, kind: kind) else { return [] }
        // 噪声过滤：两音节以上却整句切成一串单字（例如「呢/呢」）时不进候选，
        // 这类分段只留给引擎「永不空白」的音节兜底，避免逐字垃圾占满候选位。
        if segments.count >= 2 || syllableCount(of: segments) >= 2,
           segments.map(\.best).allSatisfy({ $0.count <= 1 }) {
            return []
        }
        var output: [String] = []
        var seen = Set<String>()
        func append(_ text: String) {
            guard !text.isEmpty, !seen.contains(text) else { return }
            seen.insert(text)
            output.append(text)
        }
        append(segments.map(\.best).joined())
        guard limit > 1 else { return output }
        // 从尾段往前换词：优先给用户「最后一个词的其他写法」。
        for index in segments.indices.reversed() {
            for word in segments[index].words.dropFirst() {
                var words = segments.map(\.best)
                words[index] = word
                append(words.joined())
                if output.count >= limit { return output }
            }
        }
        return output
    }

    /// 可读拼音（如「jin tian tian qi」），九宫格顶栏用；切不出来时返回 nil。
    func reading(_ raw: String, kind: String) -> String? {
        guard let segments = segments(raw, kind: kind), !segments.isEmpty else { return nil }
        let syllables = cachedSyllableSet ?? {
            let set = Set(lexicon.syllables()); cachedSyllableSet = set; return set
        }()
        let parts = segments.map { split($0.bestCode, syllables: syllables).joined(separator: " ") }.filter { !$0.isEmpty }
        let text = parts.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// 带单条缓存的入口：候选与 preedit 共用同一份分段结果，避免重复查询。
    func segments(_ raw: String, kind: String) -> [Segment]? {
        if cachedRaw == raw, cachedKind == kind { return cachedSegments }
        let value = composition(raw, kind: kind)
        cachedRaw = raw; cachedKind = kind; cachedSegments = value
        return value
    }

    /// 把整串输入切成若干词；切不动（含无法补全的尾段）时返回 nil。
    func composition(_ raw: String, kind: String) -> [Segment]? {
        let characters = Array(raw.lowercased())
        guard !characters.isEmpty, characters.count <= 64 else { return nil }
        let count = characters.count
        let unreachable = Int.max
        var segmentsAt = Array(repeating: unreachable, count: count + 1)
        var scoreAt = Array(repeating: -Double.infinity, count: count + 1)
        var stepAt = Array<Step?>(repeating: nil, count: count + 1)
        segmentsAt[0] = 0
        scoreAt[0] = 0
        for offset in 0..<count where segmentsAt[offset] != unreachable {
            let reach = min(count - offset, maxSegmentLength)
            // 整词：最长优先只影响探索顺序，取舍由「段数最少 → 词频最高」决定。
            for length in stride(from: reach, through: 1, by: -1) {
                let key = String(characters[offset..<(offset + length)])
                guard let match = exactMatch(key, kind: kind) else { continue }
                let next = offset + length
                let segments = segmentsAt[offset] + 1
                let score = scoreAt[offset] + log10(Double(match.frequency) + 2)
                guard segments < segmentsAt[next] || (segments == segmentsAt[next] && score > scoreAt[next]) else { continue }
                segmentsAt[next] = segments
                scoreAt[next] = score
                stepAt[next] = Step(offset: offset, key: key, words: match.words, codes: match.codes, completed: false)
            }
            // 尾段前缀补全：剩下的整串当成「最后一个还没打完的音节」。
            let tail = String(characters[offset...])
            guard tail.count < count, let completion = prefixMatch(tail, kind: kind) else { continue }
            let segments = segmentsAt[offset] + 1
            let score = scoreAt[offset] + log10(Double(completion.frequency) + 2)
            guard segments < segmentsAt[count] || (segments == segmentsAt[count] && score > scoreAt[count]) else { continue }
            segmentsAt[count] = segments
            scoreAt[count] = score
            stepAt[count] = Step(offset: offset, key: tail, words: completion.words, codes: completion.codes, completed: true)
        }
        guard segmentsAt[count] != unreachable else { return nil }
        var result: [Segment] = []
        var cursor = count
        while cursor > 0 {
            guard let step = stepAt[cursor], step.offset < cursor else { return nil }
            result.append(Segment(key: step.key, words: step.words, codes: step.codes, completed: step.completed))
            cursor = step.offset
            guard result.count <= maxSegments else { return nil }
        }
        return result.reversed()
    }

    /// 分段对应的音节数（用于判断「是不是逐字垃圾」）。
    private func syllableCount(of segments: [Segment]) -> Int {
        let syllables = cachedSyllableSet ?? {
            let set = Set(lexicon.syllables()); cachedSyllableSet = set; return set
        }()
        return segments.reduce(0) { total, segment in
            total + max(1, split(segment.bestCode, syllables: syllables).count)
        }
    }

    /// 把一个词的拼音 code 拆成音节（jintian → jin / tian）；拆不开时保留整词。
    private func split(_ code: String, syllables: Set<String>) -> [String] {
        let characters = Array(code)
        guard !characters.isEmpty else { return [] }
        var output: [String] = []
        var offset = 0
        while offset < characters.count {
            var matched: String?
            for length in stride(from: min(6, characters.count - offset), through: 1, by: -1) {
                let candidate = String(characters[offset..<(offset + length)])
                if syllables.contains(candidate) { matched = candidate; break }
            }
            guard let matched else { return [code] }
            output.append(matched)
            offset += matched.count
        }
        return output
    }

    private struct Step {
        let offset: Int
        let key: String
        let words: [String]
        let codes: [String]
        let completed: Bool
    }

    private struct Match {
        let words: [String]
        let codes: [String]
        let frequency: Int
    }

    private func exactMatch(_ key: String, kind: String) -> Match? {
        let token = "exact|\(kind)|\(key)"
        let matches: [MobileWord]
        if let cached = cachedLookups[token] {
            matches = cached
        } else {
            matches = lexicon.exact(key, kind: kind)
            if cachedLookups.count < 512 { cachedLookups[token] = matches }
        }
        guard let first = matches.first else { return nil }
        return Match(words: matches.map(\.word), codes: matches.map(\.code), frequency: first.frequency)
    }

    private func prefixMatch(_ key: String, kind: String) -> Match? {
        let token = "prefix|\(kind)|\(key)"
        let matches: [MobileWord]
        if let cached = cachedLookups[token] {
            matches = cached
        } else {
            matches = lexicon.lookup(key, kind: kind, limit: 6)
            if cachedLookups.count < 512 { cachedLookups[token] = matches }
        }
        guard let first = matches.first else { return nil }
        return Match(words: matches.map(\.word), codes: matches.map(\.code), frequency: first.frequency)
    }
}
