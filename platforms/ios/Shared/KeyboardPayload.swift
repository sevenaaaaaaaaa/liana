import Foundation
import UIKit

struct MobileWord: Codable, Equatable {
    var word: String
    var code: String
    var frequency: Int = 1000
    var kind: String = "pinyin"
    var reading: String? = nil
}

/// Explicit, short-lived host/extension handoff without provisioning-only App Groups.
struct KeyboardPayload: Codable {
    static let pasteboardType = "dev.liana.keyboard.payload"
    var version = 1
    var kind: String
    var text: String? = nil
    var words: [MobileWord]? = nil
    var gif: Data? = nil
    func pasteboardItem() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 12_000_000 else { throw MobileImportError.message("内容过大，请拆分导入。") }
        if kind == "text", (text?.count ?? 0) > 20_000 { throw MobileImportError.message("文字超过两万字，请分段复制。") }
        var item: [String: Any] = [Self.pasteboardType: data]
        if kind == "text", let text { item["public.utf8-plain-text"] = text }
        if kind == "gif", let gif { item["com.compuserve.gif"] = gif }
        return item
    }
    func copy() throws {
        UIPasteboard.general.setItems([try pasteboardItem()], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
    }
    static func read() throws -> Self? {
        guard let data = UIPasteboard.general.data(forPasteboardType: pasteboardType) else { return nil }
        guard data.count <= 12_000_000 else { throw MobileImportError.message("内容超过 12MB。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, (value.words?.count ?? 0) <= 20_000, (value.gif?.count ?? 0) <= 4_000_000, (value.text?.count ?? 0) <= 20_000 else { throw MobileImportError.message("数据版本或大小不受支持。") }
        return value
    }
}
enum MobileImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum MobileDictionaryImport {
    static func reading(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? text
        return latin.lowercased().split(whereSeparator: { !$0.isLetter || !$0.isASCII }).joined(separator: " ")
    }
    static func parse(_ data: Data, wubi: Bool) throws -> [MobileWord] {
        guard data.count <= 20_000_000, let text = String(data: data, encoding: .utf8) else { throw MobileImportError.message("请使用不超过 20MB 的 UTF-8 TXT、TSV 或 Rime dict.yaml 文件。") }
        var result: [MobileWord] = []
        let yaml = text.contains("\n...")
        var body = !yaml
        for source in text.split(whereSeparator: \.isNewline) {
            let line = source.trimmingCharacters(in: .whitespaces)
            if line == "..." { body = true; continue }
            guard body, !line.isEmpty, !line.hasPrefix("#") else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let word = columns[0].trimmingCharacters(in: .whitespaces)
            guard word.count <= 64 else { continue }
            let code = columns.count > 1 && !columns[1].isEmpty ? columns[1].lowercased() : (wubi ? "" : reading(word))
            guard !code.isEmpty, code.count <= 128, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " " || $0 == "'") }) else { continue }
            if wubi && (code.count > 4 || code.contains(" ")) { continue }
            let frequency = columns.count > 2 ? Int(columns[2].replacingOccurrences(of: "%", with: "")) ?? 1000 : 1000
            result.append(MobileWord(word: word, code: code, frequency: frequency, kind: wubi ? "wubi" : "pinyin", reading: code))
            if result.count >= 20_000 { break }
        }
        guard !result.isEmpty else { throw MobileImportError.message("未找到可导入词条。格式：词语〔Tab〕拼音／五笔码〔Tab〕词频。") }
        return result
    }
    static func githubURL(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil else { throw MobileImportError.message("请输入 GitHub 文件的 HTTPS 地址。") }
        if parts.host == "github.com" {
            let fields = parts.path.split(separator: "/").map(String.init)
            guard fields.count >= 5, fields[2] == "blob" else { throw MobileImportError.message("请打开具体词库文件，复制其链接。") }
            parts.host = "raw.githubusercontent.com"; parts.path = "/" + ([fields[0], fields[1]] + fields.dropFirst(3)).joined(separator: "/")
        }
        guard parts.host == "raw.githubusercontent.com", let url = parts.url else { throw MobileImportError.message("仅支持 github.com 文件链接或 raw.githubusercontent.com 原始文件链接。") }
        parts.query = nil; parts.fragment = nil
        return parts.url ?? url
    }
}
