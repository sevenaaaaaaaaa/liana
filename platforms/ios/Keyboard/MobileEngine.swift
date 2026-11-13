import Foundation

enum MobileInputMethod: String, CaseIterable {
    case pinyin, t9, flypy, mspy, zrm, wubi, handwriting
    var title: String {
        switch self {
        case .pinyin: return "全拼"
        case .t9: return "九宫格"
        case .flypy: return "小鹤双拼"
        case .mspy: return "微软双拼"
        case .zrm: return "自然码双拼"
        case .wubi: return "五笔 86"
        case .handwriting: return "手写"
        }
    }
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: "keyboard.method") ?? "") ?? .pinyin }
}

/// The C session, dictionary I/O and decoders are owned by one worker queue.
/// No decode, dictionary initialization or persistence runs on the touch thread.
final class MobileEngine {
    enum Action {
        case feed(String), backspace, space, enter, literal(String), clear
        case select(Int, raw: String, text: String)
        case mode(String), traditional(Bool), save, importWords([MobileWord])
        case glide([CGPoint], [String: CGPoint], Bool)
        case handwriting([[[Double]]])
    }
    struct Snapshot {
        var raw = ""
        var preedit = ""
        var candidates: [String] = []
        var message: String?
    }
    struct Update {
        let sequence: Int
        let document: UUID?
        let snapshot: Snapshot
        let committed: String
        let deletes: Int
    }
    var onUpdate: ((Update) -> Void)?
    /// 会话工厂。测试注入空实现即可模拟「设备上随包词典加载失败」的受限环境，
    /// 用来验证本地词库回退路径；生产环境保持为 nil，走 Rust 会话。
    var sessionFactory: ((String, String?) -> OpaquePointer?)?
    private let queue = DispatchQueue(label: "dev.liana.ios.decode", qos: .userInteractive)
    private var sequence = 0
    private var session: OpaquePointer?
    private var bundle = Bundle.main
    private var lexicon: MobileLexicon?
    private var mode = "pinyin"
    private var traditional = false
    private var raw = ""
    private var externalComposition = false
    private var choices: [(text: String, core: Int?)] = []
    private var decoded = Snapshot()
    private var handwriting: HandwritingRecognizer?
    private var layers: URL?
    private var composerCache: MobilePhraseComposer?
    private var syllableTableCache: Set<String>?
    private var singleCharacterCache: [String: String] = [:]

    func start(bundle: Bundle, mode: String) -> Int {
        self.bundle = bundle
        return submit(.mode(mode), document: nil)
    }
    @discardableResult
    func submit(_ action: Action, document: UUID?) -> Int {
        sequence += 1
        let number = sequence
        queue.async { [self] in
            autoreleasepool {
                var committed = ""
                var deletes = 0
                var message: String?
                switch action {
                case .mode(let value):
                    committed = commitAll()
                    save()
                    if let session { liana_free(session) }; session = nil
                    mode = value; raw = ""; choices = []; handwriting = nil
                    if !["t9", "wubi", "handwriting"].contains(mode) { createSession() }
                case .feed(let text):
                    if externalComposition { committed = commitAll() }
                    if ["t9", "wubi"].contains(mode) {
                        if mode == "wubi", raw.count >= 4 { committed = commitAll() }
                        raw += text.lowercased()
                    } else if let session {
                        for character in text { _ = liana_feed(session, String(character)) }
                    } else {
                        // 会话没建起来（设备上随包词典加载失败）时也要留得住输入，
                        // 交给本地词库的回退路径组合候选，不能整串丢掉。
                        raw += text.lowercased()
                    }
                case .backspace:
                    if externalComposition { raw = ""; choices = []; externalComposition = false }
                    else if raw.isEmpty { deletes = 1 }
                    else if let session { _ = liana_backspace(session) }
                    else { raw.removeLast(); choices = [] }
                case .space:
                    if !choices.isEmpty { committed = select(0) }
                    else if !raw.isEmpty { committed = commitAll() }
                    else { committed = " " }
                case .enter: committed = raw.isEmpty && choices.isEmpty ? "\n" : commitAll()
                case .literal(let text): committed = commitAll() + text
                case .clear: raw = ""; choices = []; externalComposition = false; if let session { liana_clear(session) }
                case .select(let index, let expected, let text):
                    if externalComposition, raw == expected {
                        committed = text; database().learn(text, raw: raw)
                        raw = ""; choices = []; externalComposition = false
                        if let session { liana_clear(session) }
                    } else if raw == expected, choices.indices.contains(index), choices[index].text == text { committed = select(index) }
                    else if raw.hasPrefix(expected), !expected.isEmpty {
                        // A new key may have reached the worker while an older candidate
                        // was still visible. Consume only that candidate's displayed prefix.
                        let suffix = String(raw.dropFirst(expected.count))
                        if let session {
                            liana_clear(session)
                            for c in expected { _ = liana_feed(session, String(c)) }
                            refresh()
                            if let match = choices.firstIndex(where: { $0.text == text }) { committed = select(match) }
                            else { committed = text; liana_clear(session) }
                            for c in suffix { _ = liana_feed(session, String(c)) }
                        } else { committed = text; raw = suffix; choices = [] }
                    }
                case .traditional(let enabled): traditional = enabled; if let session { _ = liana_set_traditional(session, enabled ? 1 : 0) }
                case .save: save()
                case .importWords(let words):
                    committed = commitAll()
                    let count = database().importWords(words)
                    composerCache?.invalidateCache()
                    syllableTableCache = nil
                    singleCharacterCache.removeAll()
                    layers = database().exportPinyinLayer()
                    if let session { save(); liana_free(session); self.session = nil; createSession() }
                    message = "已导入 \(count) 条词语"
                case .glide(let points, let centers, let english):
                    committed = commitAll()
                    let matches = GlideDecoder.decode(points: points, centers: centers, lexicon: database(), english: english)
                    raw = "滑动"
                    externalComposition = true
                    choices = matches.map { ($0.word, nil) }
                case .handwriting(let strokes):
                    if strokes.isEmpty { raw = ""; choices = [] }
                    else {
                        if handwriting == nil { handwriting = HandwritingRecognizer(bundle: bundle) }
                        choices = (handwriting?.recognize(strokes) ?? []).map { ($0, nil) }
                        raw = "手写"
                        if choices.isEmpty { message = "未识别出文字，请重新书写" }
                    }
                }
                if case .glide = action { decoded = Snapshot(raw: raw, preedit: raw, candidates: choices.map(\.text)) }
                else if mode == "handwriting" { decoded = Snapshot(raw: raw, preedit: raw, candidates: choices.map(\.text)) }
                else { refresh() }
                if let message { decoded.message = message }
                let update = Update(sequence: number, document: document, snapshot: decoded, committed: committed, deletes: deletes)
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
            }
        }
        return number
    }
    func whenIdle(_ completion: @escaping () -> Void) { queue.async { DispatchQueue.main.async(execute: completion) } }
    deinit { if let session { liana_free(session) } }
    private func database() -> MobileLexicon {
        if let lexicon { return lexicon }
        let value = MobileLexicon(bundle: bundle); lexicon = value; return value
    }
    private func createSession() {
        let base = bundle.url(forResource: "base", withExtension: "ifd")?.path
        if let sessionFactory {
            session = sessionFactory(mode, base)
        } else {
            let folder = layers ?? MobileLexicon.directory.appendingPathComponent("dicts")
            session = liana_new_with_layers(mode, base, folder.path)
        }
        if let saved = UserDefaults.standard.string(forKey: "user_dict_tsv"), let session { _ = liana_user_import(session, saved) }
        if let session { _ = liana_set_traditional(session, traditional ? 1 : 0) }
    }
    /// 候选分层合并：本地整串精确命中 → Rust 会话 → 分段组合 → 音节兜底。
    /// 去重后截断 9 个；会话候选保留原始索引，选择/学习仍走原有逻辑。
    private func refresh() {
        if externalComposition { decoded = Snapshot(raw: raw, preedit: raw, candidates: choices.map(\.text)); return }
        choices = []
        var preedit = raw
        var sessionChoices: [(text: String, core: Int?)] = []
        if let session, let pointer = liana_composition_json(session) {
            let data = Data(String(cString: pointer).utf8)
            liana_free_string(pointer)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                raw = object["raw"] as? String ?? ""
                preedit = object["preedit"] as? String ?? raw
                let candidates = object["candidates"] as? [[String: Any]] ?? []
                sessionChoices = candidates.prefix(9).enumerated().compactMap { index, item in
                    (item["text"] as? String).map { ($0, index) }
                }
            }
        }
        // 全拼直接可用；双拼用会话 preedit 里的全拼（如 nihc → "ni hao"）去查库。
        let pinyin = fullPinyin(for: raw, preedit: preedit)
        var merged: [(text: String, core: Int?)] = []
        var seen = Set<String>()
        func add(_ text: String, _ core: Int?) {
            guard !text.isEmpty, !seen.contains(text) else { return }
            seen.insert(text)
            merged.append((text, core))
        }
        // 1) 本地词库整串精确命中（含用户学习/钉选/快捷词），优先级最高。
        if !raw.isEmpty {
            switch mode {
            case "pinyin", "flypy", "mspy", "zrm":
                if pinyin.allSatisfy({ $0.isASCII && $0.isLetter }) {
                    if mode == "pinyin" { for word in database().shortcuts(pinyin) { add(word.word, nil) } }
                    for word in database().exact(pinyin, kind: "pinyin", limit: 9) { add(word.word, nil) }
                }
            case "t9":
                for word in database().exact(raw, kind: "t9", limit: 9) { add(word.word, nil) }
            default:
                break
            }
        }
        // 2) Rust 会话候选（整句、纠错、简拼、词频与学习重排都在会话内完成）。
        for candidate in sessionChoices { add(candidate.text, candidate.core) }
        // 3) 分段组合：优先级低于会话；会话已占满 9 个空位时追加也不会进候选栏。
        if merged.count < 9, !raw.isEmpty {
            if mode == "t9" {
                for text in composer().candidates(raw, kind: "t9") { add(text, nil) }
            } else if ["pinyin", "flypy", "mspy", "zrm"].contains(mode), !pinyin.isEmpty {
                for text in composer().candidates(pinyin, kind: "pinyin") { add(text, nil) }
            }
        }
        // 4) 兜底：任何合法拼音都要有候选（逐音节取单字）。
        if merged.isEmpty, !raw.isEmpty, ["pinyin", "t9", "flypy", "mspy", "zrm"].contains(mode) {
            if let fallback = syllableFallback(pinyin: pinyin, raw: raw) { add(fallback, nil) }
        }
        // 五笔/英文保持原来的前缀补全行为。
        if merged.isEmpty, !raw.isEmpty, mode == "wubi" || (mode == "en" && session == nil) {
            for word in database().lookup(raw, kind: mode) { add(word.word, nil) }
        }
        choices = Array(merged.prefix(9))
        if mode == "t9" {
            // 九宫格内部缓冲是数字串，顶栏只展示可读拼音，避免「顶栏莫名多出数字」。
            preedit = raw.isEmpty ? "" : (composer().reading(raw, kind: "t9") ?? "九宫格")
        }
        decoded = Snapshot(raw: raw, preedit: preedit, candidates: choices.map(\.text))
    }

    /// 双拼会话的 preedit 是全拼（Rust 侧保证）；全拼模式直接用 raw。
    private func fullPinyin(for raw: String, preedit: String) -> String {
        switch mode {
        case "pinyin", "t9", "wubi", "en", "handwriting":
            return raw.lowercased()
        default:
            let derived = preedit.lowercased().filter { $0.isASCII && $0.isLetter }
            if !derived.isEmpty, PinyinSyllables.split(derived, extra: syllableTable()) != nil { return derived }
            return raw.lowercased()
        }
    }

    /// 音节兜底：切音节 → 每个音节取单字最高频候选。
    private func syllableFallback(pinyin: String, raw: String) -> String? {
        if mode == "t9" {
            if let segments = composer().segments(raw, kind: "t9"), !segments.isEmpty,
               let characters = singleCharacters(for: segments.map(\.bestCode).joined()) {
                return characters
            }
            return raw
        }
        if let characters = singleCharacters(for: pinyin) { return characters }
        return pinyin.isEmpty ? raw : pinyin
    }

    private func singleCharacters(for pinyin: String) -> String? {
        guard let syllables = PinyinSyllables.split(pinyin, extra: syllableTable()), !syllables.isEmpty else { return nil }
        var output = ""
        for syllable in syllables {
            if let character = singleCharacter(for: syllable) { output += character }
        }
        return output.isEmpty ? nil : output
    }

    private func singleCharacter(for syllable: String) -> String? {
        if let cached = singleCharacterCache[syllable] { return cached.isEmpty ? nil : cached }
        let value = database().singleCharacter(for: syllable) ?? ""
        if singleCharacterCache.count < 512 { singleCharacterCache[syllable] = value }
        return value.isEmpty ? nil : value
    }

    private func syllableTable() -> Set<String> {
        if let syllableTableCache { return syllableTableCache }
        let value = Set(database().syllables())
        syllableTableCache = value
        return value
    }

    private func composer() -> MobilePhraseComposer {
        if let composerCache { return composerCache }
        let value = MobilePhraseComposer(lexicon: database()); composerCache = value; return value
    }
    private func select(_ index: Int) -> String {
        guard choices.indices.contains(index) else { return "" }
        let choice = choices[index]
        if let core = choice.core, let session, let pointer = liana_select(session, UInt32(core)) {
            let text = String(cString: pointer); liana_free_string(pointer); refresh(); return text
        }
        database().learn(choice.text, raw: raw)
        composerCache?.invalidateCache()
        if let session { _ = liana_record_commit(session, choice.text); liana_clear(session) }
        raw = ""; choices = []; externalComposition = false
        return choice.text
    }
    private func commitAll() -> String {
        if choices.isEmpty && (mode == "handwriting" || externalComposition) { raw = ""; externalComposition = false; return "" }
        var output = ""
        var attempts = 0
        while !raw.isEmpty && attempts < 64 {
            let before = raw
            if !choices.isEmpty { output += select(0) }
            else if let session, let pointer = liana_commit_raw(session) { output += String(cString: pointer); liana_free_string(pointer); refresh() }
            else { output += raw; raw = "" }
            attempts += 1
            if before == raw { raw = ""; choices = []; if let session { liana_clear(session) }; break }
        }
        return output
    }
    private func save() {
        guard let session, let pointer = liana_user_export(session) else { return }
        let text = String(cString: pointer); liana_free_string(pointer)
        UserDefaults.standard.set(text, forKey: "user_dict_tsv")
    }
}
