import AppKit
import CryptoKit
import Foundation
import Security

/// 剪切板历史条目。
struct ClipboardItem: Codable, Equatable {
    let text: String
    let createdAt: Date
}

/// TSV 合并用的键：预先算好 FNV-1a，避免 Swift 对中文长键做 Unicode 哈希。
/// 5 万行账本的合并里，光是 String 哈希就占了大头（约 10 倍差距）。
private struct TSVKey: Hashable {
    let text: String
    let hash: UInt64
    func hash(into hasher: inout Hasher) { hasher.combine(hash) }
    static func == (lhs: TSVKey, rhs: TSVKey) -> Bool { lhs.hash == rhs.hash && lhs.text == rhs.text }
}

/// 五列带时间戳的行（知你账本 / 营养库）：整行原文 + 末列时间。
private struct DatedRow {
    var line: String
    var last: UInt64
}

/// 加密持久化：`userdata.enc` = magic + 版本 + ChaChaPoly(JSON)。
///
/// 密钥优先来自钥匙串；不可用时本次运行退化为「仅内存」，绝不把密钥落盘。
/// 设计见 `docs/adr/0005-encrypted-persistence.md`。
final class EncryptedStore {
    static let shared = EncryptedStore()

    static let maxClipboardItems = 200
    static let maxClipboardItemBytes = 100 * 1024

    private(set) var clipboard: [ClipboardItem] = []
    private(set) var userModelTsv: String = ""
    /// 知你账本 TSV（词\t特征\t亲和度\t观察数\t最后触摸），随 userdata.enc 加密落盘。
    private(set) var evolutionTsv: String = ""
    /// 营养库 TSV（词\t按键串\t出处\t强度\t加入时间），喂食层的落盘。
    private(set) var nutritionTsv: String = ""
    /// 钥匙串是否可用（false = 本次运行不落盘）。
    private(set) var keyAvailable = false

    private let fileURL: URL
    /// 剪切板单独一档。剪切板历史可能有数 MB（200 条 × 100KB），
    /// 跟着用户词一起整档加密的话，每次上屏都要重写整份历史。
    private let clipboardURL: URL
    private var key: SymmetricKey?
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "dev.liana.store.save", qos: .utility)
    private var terminateObserver: NSObjectProtocol?
    private var payloadDirty = false
    private var clipboardDirty = false
    /// 钥匙串服务名故意钉死在初代产品（InputFlow）的 bundle id 上，品牌升级为
    /// 松萝 / Liana、换 bundle id（dev.liana.ime）都不跟着改：换 ID 后密钥不变，
    /// 旧 userdata.enc 依旧可解（bundle id 本身不参与加解密，只做钥匙串寻址）。
    private let service = "dev.inputflow.inputmethod"
    private let account = "userdata-key"

    private static let magic = Data("IFUE".utf8)
    private static let header = magic + Data([1])

    private struct Payload: Codable {
        var schemaVersion: Int
        var userModelTsv: String
        /// v2 起新增；解码 v1 旧档时为 nil。
        var evolutionTsv: String?
        /// v3 起新增（喂食层营养库）；解码 v1/v2 旧档时为 nil。
        var nutritionTsv: String?
        var clipboard: [ClipboardItem]
    }

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liana", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.init(fileURL: base.appendingPathComponent("userdata.enc"))
    }

    init(fileURL: URL, key: SymmetricKey? = nil) {
        self.fileURL = fileURL
        self.clipboardURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".clip.enc")
        if let key {
            self.key = key
            self.keyAvailable = true
        } else if let k = Self.keychainLoadOrCreate(service: service, account: account) {
            self.key = k
            self.keyAvailable = true
        } else {
            NSLog("Liana: 钥匙串不可用，本次运行的用户词/剪切板不会落盘")
        }
        // 进程退出前把还没写的内容同步写完（异步队列里在途的也要等）
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.flush() }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    // MARK: - 加载 / 保存

    @discardableResult
    func load() -> Bool {
        guard let key else { return false }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return false }
        do {
            let plaintext = try Self.open(data, key: key)
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            userModelTsv = payload.userModelTsv
            evolutionTsv = payload.evolutionTsv ?? ""
            nutritionTsv = payload.nutritionTsv ?? ""
            if FileManager.default.fileExists(atPath: clipboardURL.path) {
                loadClipboard(key: key)
            } else if !payload.clipboard.isEmpty {
                // v3 及更早：剪切板与主数据同档。读出来后就地迁移：
                // 之后上屏只重写主档（几十 KB），不再加密整份剪切板历史。
                clipboard = payload.clipboard
                clipboardDirty = true
                payloadDirty = true
                scheduleSave()
            }
            return true
        } catch {
            NSLog("Liana: userdata.enc 解析失败（\(error.localizedDescription)），按空数据处理")
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            userModelTsv = ""
            evolutionTsv = ""
            nutritionTsv = ""
            clipboard = []
            return false
        }
    }

    func setUserModel(_ tsv: String) {
        userModelTsv = tsv
        markDirty()
    }

    /// 覆盖知你账本（权限中心「一键忘记」后归零走这里）。
    func setEvolution(_ tsv: String) {
        evolutionTsv = tsv
        markDirty()
    }

    /// 合并另一份知你账本 TSV（多控制器同时使用时避免互相覆盖）：
    /// 同一 (词, 特征) 取「最后触摸」较新的整行——亲和度与观察数是一体的。
    func mergeEvolution(tsv: String) {
        guard !tsv.isEmpty else { return }
        var rows: [TSVKey: DatedRow] = [:]
        _ = Self.mergeDatedRows(evolutionTsv, into: &rows, requiresAffinity: true)
        guard Self.mergeDatedRows(tsv, into: &rows, requiresAffinity: true) else { return }
        evolutionTsv = Self.renderDatedRows(rows)
        markDirty()
    }

    /// 覆盖营养库（权限中心「清空」后归零走这里）。
    func setNutrition(_ tsv: String) {
        nutritionTsv = tsv
        markDirty()
    }

    /// 合并另一份营养库 TSV：同一词取「加入时间」较新的整行。
    func mergeNutrition(tsv: String) {
        guard !tsv.isEmpty else { return }
        var rows: [TSVKey: DatedRow] = [:]
        _ = Self.mergeDatedRows(nutritionTsv, into: &rows, requiresAffinity: false)
        guard Self.mergeDatedRows(tsv, into: &rows, requiresAffinity: false) else { return }
        nutritionTsv = Self.renderDatedRows(rows)
        markDirty()
    }

    /// 合并另一份用户词 TSV（多控制器同时使用时避免互相覆盖），按计数取大合并。
    ///
    /// 行类型无关：词（`词\t次数`）、二元组（`@pair\t…`）、短语（`@phrase\t…`）
    /// 一律按「除最后一列以外的全部字段」当键，所以内核以后加新行类型也不会在这里丢数据。
    func mergeUserModel(tsv: String) {
        guard !tsv.isEmpty else { return }
        var records: [TSVKey: Int] = [:]
        Self.parseTsv(userModelTsv, into: &records)
        var incoming: [TSVKey: Int] = [:]
        Self.parseTsv(tsv, into: &incoming)
        var changed = false
        for (key, c) in incoming where c > (records[key] ?? 0) {
            records[key] = c
            changed = true
        }
        guard changed else { return }
        userModelTsv = Self.renderTsv(records)
        markDirty()
    }

    // MARK: - 剪切板

    /// 记录一条剪切板内容；返回是否有变化。超过上限/重复/过大时忽略。
    @discardableResult
    func recordClipboard(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.utf8.count <= Self.maxClipboardItemBytes else { return false }
        if clipboard.first?.text == text { return false }
        clipboard.removeAll { $0.text == text }
        clipboard.insert(ClipboardItem(text: text, createdAt: Date()), at: 0)
        if clipboard.count > Self.maxClipboardItems {
            clipboard.removeLast(clipboard.count - Self.maxClipboardItems)
        }
        markClipboardDirty()
        return true
    }

    func clearClipboard() {
        guard !clipboard.isEmpty else { return }
        clipboard = []
        markClipboardDirty()
    }

    func removeClipboard(_ item: ClipboardItem) {
        let before = clipboard.count
        clipboard.removeAll { $0 == item }
        if clipboard.count != before {
            markClipboardDirty()
        }
    }

    // MARK: - 落盘（防抖 + 原子写）

    func markDirty() {
        payloadDirty = true
        scheduleSave()
    }

    /// 剪切板变化：只标记剪切板档，不碰用户词 / 账本。
    private func markClipboardDirty() {
        clipboardDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        guard keyAvailable else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushAsync() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// 同步落盘：自检 / 备份 / 退出前用，调用返回时文件已写好。
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        // 串行队列上执行：既保证等前面的异步写盘跑完，也避免和它抢同一个文件
        if let job = takePendingWrites() {
            saveQueue.sync(execute: job)
        } else {
            saveQueue.sync {}
        }
    }

    /// 异步落盘：主线程只做快照，JSON 编码 + 加密 + 写盘（用户词上万条时可达上百毫秒）
    /// 全部挪到串行后台队列，避免打字时卡一下。
    func flushAsync() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let job = takePendingWrites() else { return }
        saveQueue.async(execute: job)
    }

    /// 取出待写内容并清标记：主线程快照，后台只碰快照，不读可变属性。
    private func takePendingWrites() -> (() -> Void)? {
        guard let key, keyAvailable, clipboardDirty || payloadDirty else { return nil }
        let clip = clipboardDirty ? clipboard : nil
        let payload = payloadDirty
            ? Payload(
                schemaVersion: 4,
                userModelTsv: userModelTsv,
                evolutionTsv: evolutionTsv,
                nutritionTsv: nutritionTsv,
                clipboard: []
            )
            : nil
        clipboardDirty = false
        payloadDirty = false
        return { [weak self] in
            guard let self else { return }
            if let clip { self.writeClipboard(clip, key: key) }
            if let payload { self.writePayload(payload, key: key) }
        }
    }

    private func writePayload(_ payload: Payload, key: SymmetricKey) {
        do {
            let plaintext = try JSONEncoder().encode(payload)
            let sealed = try Self.seal(plaintext, key: key)
            try sealed.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Liana: 用户数据落盘失败（\(error.localizedDescription)）")
        }
    }

    private func writeClipboard(_ items: [ClipboardItem], key: SymmetricKey) {
        do {
            let plaintext = try JSONEncoder().encode(items)
            let sealed = try Self.seal(plaintext, key: key)
            try sealed.write(to: clipboardURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clipboardURL.path)
        } catch {
            NSLog("Liana: 剪切板落盘失败（\(error.localizedDescription)）")
        }
    }

    private func loadClipboard(key: SymmetricKey) {
        guard let data = try? Data(contentsOf: clipboardURL), !data.isEmpty else { return }
        do {
            let plaintext = try Self.open(data, key: key)
            clipboard = try JSONDecoder().decode([ClipboardItem].self, from: plaintext)
        } catch {
            NSLog("Liana: 剪切板档解析失败（\(error.localizedDescription)），按空历史处理")
        }
    }

    // MARK: - 加密

    private static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: header)
        return header + box.combined
    }

    private static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.count > header.count, data.prefix(header.count) == header else {
            throw NSError(domain: "Liana.Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件头不匹配"])
        }
        let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(header.count))
        return try ChaChaPoly.open(box, using: key, authenticating: header)
    }

    // MARK: - TSV 工具
    //
    // 账本可达 5 MB / 5 万行。旧实现 split + map(String.new) 建 [String: [String]]，
    // 每次合并要 600 ms（大半花在 String 的 Unicode 哈希与排序上）；
    // 现在按 UTF-8 字节扫一遍、键用 FNV-1a 预哈希、不排序——同样的账本约 50 ms。
    // 顺序对内核导入与备份都没有意义，只要求内容完整。

    /// 键 = 除次数外的全部字段（用制表符连接），值 = 次数。
    private static func parseTsv(_ tsv: String, into records: inout [TSVKey: Int]) {
        guard !tsv.isEmpty else { return }
        var text = tsv
        text.withUTF8 { buf in
            guard let base = buf.baseAddress else { return }
            let end = buf.count
            var start = 0
            while start < end {
                var lineEnd = start
                while lineEnd < end && base[lineEnd] != 10 { lineEnd += 1 }
                // 最后一个 tab 分隔「键」与「次数」
                var lastTab = -1
                var i = lineEnd - 1
                while i > start {
                    if base[i] == 9 { lastTab = i; break }
                    i -= 1
                }
                if lastTab > start, let count = asciiInt(buf, lastTab + 1, lineEnd) {
                    let key = makeString(base, start, lastTab)
                    records[TSVKey(text: key, hash: fnv1a(buf, start, lastTab))] = count
                }
                start = lineEnd + 1
            }
        }
    }

    private static func renderTsv(_ records: [TSVKey: Int]) -> String {
        var out = ""
        out.reserveCapacity(records.count * 32)
        for (key, count) in records {
            out += key.text
            out += "\t"
            out += String(count)
            out.append("\n")
        }
        return out
    }

    /// 五列带时间戳的行（知你账本 / 营养库共用）：末列是 Unix 秒，
    /// 键 = 前两列；已有同键行时间不早于新行时不覆盖。有实际变化时返回 true。
    private static func mergeDatedRows(
        _ tsv: String,
        into rows: inout [TSVKey: DatedRow],
        requiresAffinity: Bool
    ) -> Bool {
        guard !tsv.isEmpty else { return false }
        var changed = false
        var text = tsv
        text.withUTF8 { buf in
            guard let base = buf.baseAddress else { return }
            let end = buf.count
            var start = 0
            while start < end {
                var lineEnd = start
                while lineEnd < end && base[lineEnd] != 10 { lineEnd += 1 }
                var t1 = -1, t2 = -1, t3 = -1, tabs = 0, i = start
                var tooMany = false
                while i < lineEnd {
                    if base[i] == 9 {
                        tabs += 1
                        if tabs == 2 { t1 = i } else if tabs == 3 { t2 = i } else if tabs == 4 { t3 = i }
                        else if tabs == 5 { tooMany = true; break }
                    }
                    i += 1
                }
                if !tooMany, tabs == 4, t1 > start, t2 > t1 + 1,
                   !requiresAffinity || isAsciiFloat(buf, t1 + 1, t2),
                   asciiInt(buf, t2 + 1, t3) != nil,
                   let last = asciiInt(buf, t3 + 1, lineEnd), last >= 0 {
                    let k = TSVKey(text: makeString(base, start, t1), hash: fnv1a(buf, start, t1))
                    let newer = rows[k].map { $0.last < UInt64(last) } ?? true
                    if newer {
                        // 只有真正要写入时才拷整行：第二次合并里绝大多数行都没变。
                        rows[k] = DatedRow(line: makeString(base, start, lineEnd), last: UInt64(last))
                        changed = true
                    }
                }
                start = lineEnd + 1
            }
        }
        return changed
    }

    private static func renderDatedRows(_ rows: [TSVKey: DatedRow]) -> String {
        var out = ""
        out.reserveCapacity(rows.count * 96)
        for row in rows.values {
            out += row.line
            out.append("\n")
        }
        return out
    }

    // MARK: - 字节级小工具

    /// FNV-1a：对 UTF-8 字节做常量时间哈希（中文键也不用走 Unicode 规范化）。
    @inline(__always)
    private static func fnv1a(_ buf: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var i = from
        while i < to {
            hash = (hash ^ UInt64(buf[i])) &* 0x100000001b3
            i += 1
        }
        return hash
    }

    @inline(__always)
    private static func makeString(_ base: UnsafePointer<UInt8>, _ from: Int, _ to: Int) -> String {
        let count = to - from
        guard count > 0 else { return "" }
        return String(unsafeUninitializedCapacity: count) { dst in
            dst.baseAddress!.update(from: base + from, count: count)
            return count
        }
    }

    /// 只认 ASCII 十进制（可带负号）；越界/非法返回 nil。
    @inline(__always)
    private static func asciiInt(_ buf: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> Int? {
        guard from < to else { return nil }
        var i = from
        var negative = false
        if buf[i] == 45 {
            negative = true
            i += 1
            if i == to { return nil }
        }
        var value = 0
        while i < to {
            let digit = Int(buf[i]) - 48
            if digit < 0 || digit > 9 { return nil }
            if value > (Int.max - digit) / 10 { return nil }
            value = value * 10 + digit
            i += 1
        }
        return negative ? -value : value
    }

    /// 宽松的 ASCII 浮点校验：只用于「这一行看起来像账本行」的判断。
    @inline(__always)
    private static func isAsciiFloat(_ buf: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> Bool {
        guard from < to else { return false }
        var digits = 0
        var i = from
        while i < to {
            let c = buf[i]
            if c >= 48 && c <= 57 {
                digits += 1
            } else if c != 43 && c != 45 && c != 46 && c != 101 && c != 69 {
                return false
            }
            i += 1
        }
        return digits > 0
    }

    // MARK: - 钥匙串

    private static func keychainLoadOrCreate(service: String, account: String) -> SymmetricKey? {
        if let existing = keychainLoad(service: service, account: account) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return keychainLoad(service: service, account: account)
        }
        return status == errSecSuccess ? SymmetricKey(data: data) : nil
    }

    private static func keychainLoad(service: String, account: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}

// MARK: - 自检（`Liana --store-smoke`）

extension EncryptedStore {
    /// 加密存储往返自检：临时文件 + 随机密钥，不触碰真实钥匙串与用户文件。
    static func smokeTest() -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("liana-store-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("userdata.enc")
        let key = SymmetricKey(size: .bits256)
        var ok = true

        let a = EncryptedStore(fileURL: url, key: key)
        a.setUserModel("你好\t3\n@pair\t你好\t世界\t2\n")
        a.setEvolution("你好\tapp:com.apple.Notes\t0.5250\t2\t1000\n")
        a.recordClipboard("第一段文本")
        a.recordClipboard("第一段文本") // 连续重复应忽略
        a.recordClipboard("第二段文本")
        a.flush()

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let raw = try? Data(contentsOf: url)
        ok = ok && (perms & 0o777) == 0o600
        ok = ok && (raw?.count ?? 0) > 32
        ok = ok && !(raw?.range(of: Data("你好".utf8)) != nil)

        let b = EncryptedStore(fileURL: url, key: key)
        ok = ok && b.load()
        ok = ok && b.userModelTsv.contains("你好\t3")
        ok = ok && b.evolutionTsv.contains("你好\tapp:com.apple.Notes\t0.5250\t2\t1000")
        ok = ok && b.clipboard.count == 2
        ok = ok && b.clipboard.first?.text == "第二段文本"

        // 换错密钥必须读不出来
        let wrong = EncryptedStore(fileURL: url, key: SymmetricKey(size: .bits256))
        let wrongLoaded = wrong.load()
        ok = ok && !wrongLoaded

        // 合并：按计数取大，不覆盖对方独有的条目
        let merged = EncryptedStore(fileURL: dir.appendingPathComponent("merge.enc"), key: key)
        merged.setUserModel("你好\t3\n@pair\t你好\t世界\t2\n")
        merged.mergeUserModel(
            tsv: "你好\t1\n世界\t5\n@pair\t你好\t世界\t4\n@pair\t世界\t你好\t1\n"
                + "@phrase\tnihaoshijie\t你好世界\t3\n")
        ok = ok && merged.userModelTsv.contains("你好\t3")
        ok = ok && merged.userModelTsv.contains("世界\t5")
        ok = ok && merged.userModelTsv.contains("@pair\t你好\t世界\t4")
        ok = ok && merged.userModelTsv.contains("@pair\t世界\t你好\t1")
        ok = ok && merged.userModelTsv.contains("@phrase\tnihaoshijie\t你好世界\t3")

        // 知你账本合并：同键取「最后触摸」较新的整行，坏行跳过
        merged.mergeEvolution(tsv: "你好\tapp:old\t0.1000\t1\t500\n你好\tapp:new\t0.3500\t2\t2000\n坏行\n")
        ok = ok && merged.evolutionTsv.contains("你好\tapp:old\t0.1000\t1\t500")
        // 新行「最后触摸」更晚（800 > 500）：按设计整行覆盖——亲和度与观察数是一体的
        merged.mergeEvolution(tsv: "你好\tapp:old\t0.9000\t3\t800\n")
        ok = ok && merged.evolutionTsv.contains("你好\tapp:old\t0.9000\t3\t800")
        ok = ok && !merged.evolutionTsv.contains("你好\tapp:old\t0.1000\t1\t500")
        ok = ok && merged.evolutionTsv.contains("你好\tapp:new\t0.3500\t2\t2000")

        // 营养库合并：同词取「加入时间」较新的整行
        merged.setNutrition("")
        merged.mergeNutrition(tsv: "张江高科\tzhangjianggaoke\t旧文档\t2\t500\n")
        merged.mergeNutrition(tsv: "张江高科\tzhangjianggaoke\t新文档\t5\t2000\n坏行\n缺\t列\t1\n")
        ok = ok && merged.nutritionTsv.contains("张江高科\tzhangjianggaoke\t新文档\t5\t2000")
        ok = ok && !merged.nutritionTsv.contains("旧文档")
        merged.mergeNutrition(tsv: "张江高科\tzhangjianggaoke\t更老\t1\t100\n")
        ok = ok && merged.nutritionTsv.contains("新文档\t5\t2000")

        // v3 旧档迁移：剪切板原本写在主档里，加载后应拆到独立档，
        // 之后上屏只重写主档（几十 KB），不再加密整份剪切板历史。
        let legacyURL = dir.appendingPathComponent("legacy.enc")
        let legacyPayload = Payload(
            schemaVersion: 3,
            userModelTsv: "旧词\t2\n",
            evolutionTsv: nil,
            nutritionTsv: nil,
            clipboard: [ClipboardItem(text: "旧剪切板", createdAt: Date())]
        )
        if let plain = try? JSONEncoder().encode(legacyPayload),
           let sealed = try? Self.seal(plain, key: key) {
            try? sealed.write(to: legacyURL)
        }
        let legacy = EncryptedStore(fileURL: legacyURL, key: key)
        ok = ok && legacy.load()
        ok = ok && legacy.clipboard.first?.text == "旧剪切板"
        legacy.flush()
        ok = ok && FileManager.default.fileExists(atPath: legacy.clipboardURL.path)
        if let data = try? Data(contentsOf: legacyURL),
           let plain = try? Self.open(data, key: key),
           let migrated = try? JSONDecoder().decode(Payload.self, from: plain) {
            ok = ok && migrated.clipboard.isEmpty
            ok = ok && migrated.userModelTsv.contains("旧词\t2")
        } else {
            ok = false
        }

        // 损坏文件应被隔离为 .corrupt
        try? Data("garbage".utf8).write(to: url)
        let c = EncryptedStore(fileURL: url, key: key)
        ok = ok && !c.load()
        ok = ok && FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path)

        print("store-smoke: \(ok ? "通过" : "失败")")
        print("钥匙串可用: \(EncryptedStore.shared.keyAvailable)")
        return ok
    }
}
