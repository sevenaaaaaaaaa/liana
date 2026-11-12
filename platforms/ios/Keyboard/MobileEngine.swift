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
    private func refresh() {
        if externalComposition { decoded = Snapshot(raw: raw, preedit: raw, candidates: choices.map(\.text)); return }
        choices = []
        var preedit = raw
        if let session, let pointer = liana_composition_json(session) {
            let data = Data(String(cString: pointer).utf8)
            liana_free_string(pointer)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                raw = object["raw"] as? String ?? ""
                preedit = object["preedit"] as? String ?? raw
                let candidates = object["candidates"] as? [[String: Any]] ?? []
                choices = candidates.prefix(9).enumerated().compactMap { index, item in (item["text"] as? String).map { ($0, index) } }
                if mode == "pinyin", !raw.isEmpty {
                    let custom = database().shortcuts(raw)
                    let seen = Set(custom.map(\.word))
                    choices = Array((custom.map { ($0.word, nil as Int?) } + choices.filter { !seen.contains($0.text) }).prefix(9))
                }
            }
        }
        // 会话没有给出候选（九宫格没有整词条目、或设备上随包词典加载失败）时，
        // 回退到本地词库：先按整词/前缀取词，再按音节分段组合成整句。
        if choices.isEmpty, !raw.isEmpty, mode != "en" || session == nil {
            let direct = database().lookup(raw, kind: mode).map { ($0.word, nil as Int?) }
            let segmented = direct.isEmpty && ["pinyin", "t9"].contains(mode)
                ? composer().candidates(raw, kind: mode).map { ($0, nil as Int?) }
                : []
            choices = Array((direct + segmented).prefix(9))
        }
        if mode == "t9" {
            // 九宫格内部缓冲是数字串，顶栏只展示可读拼音，避免「顶栏莫名多出数字」。
            preedit = raw.isEmpty ? "" : (composer().reading(raw, kind: mode) ?? "九宫格")
        }
        decoded = Snapshot(raw: raw, preedit: preedit, candidates: choices.map(\.text))
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
