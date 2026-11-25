import Foundation

/// 内核注册表里的一门输入方案——`liana_languages()` 返回的一项。
struct LianaLanguage: Equatable {
    let id: String
    let label: String
    let policy: String
}

/// 键盘菜单的语言清单只有一个来源：内核的 `liana_languages()`。
///
/// 各端自己维护一份枚举的时代到此为止——「加一门语言」只要在内核注册一个包，
/// 菜单自动跟上。本文件故意不 import 任何 C 头：取字符串的调用由调用方以闭包
/// 注入，于是 `scripts/test-logic.sh` 只编译这一个文件就能测解析与回退，
/// 不需要链接 libliana。
enum LanguageCatalog {
    /// 内核符号缺失 / 返回空 / JSON 坏掉时的清单。
    /// 与 `builtin_languages()` 的 9 项、顺序、policy 一一对应：
    /// 菜单可以少一项，不能变空——空菜单等于键盘不能用。
    static let fallback: [LianaLanguage] = [
        LianaLanguage(id: "pinyin", label: "拼音", policy: "ascii"),
        LianaLanguage(id: "flypy", label: "小鹤双拼", policy: "ascii"),
        LianaLanguage(id: "mspy", label: "微软双拼", policy: "ascii"),
        LianaLanguage(id: "zrm", label: "自然码", policy: "ascii"),
        LianaLanguage(id: "emoji", label: "表情", policy: "ascii"),
        LianaLanguage(id: "en", label: "English", policy: "ascii"),
        LianaLanguage(id: "es", label: "Español", policy: "unicode"),
        LianaLanguage(id: "ja", label: "日本語", policy: "ascii"),
        LianaLanguage(id: "ko", label: "한국어", policy: "ascii"),
    ]

    /// 解析 `[{"id","label","policy"}]`。
    ///
    /// 规则写死在这里，三端别再各写一套：缺 id 的项丢弃、重复 id 保留第一个、
    /// 缺 label 用 id 顶、未知字段忽略、坏输入返回空数组（由 `load` 兜底）。
    static func parse(_ json: String?) -> [LianaLanguage] {
        guard let text = json?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        var out: [LianaLanguage] = []
        for row in rows {
            guard let raw = row["id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let policy = row["policy"] as? String ?? ""
            out.append(LianaLanguage(id: id, label: label.isEmpty ? id : label, policy: policy))
        }
        return out
    }

    /// 拿清单：内核给不出可用结果就回退到内置 9 项。
    static func load(fetch: () -> String?) -> [LianaLanguage] {
        let parsed = parse(fetch())
        return parsed.isEmpty ? fallback : parsed
    }

    /// 菜单顺序：内核顺序在前，平台自有方案（九宫格／五笔／手写）殿后，重复 id 去掉。
    /// 内核将来加了本键盘没有界面的 id（如 emoji），由调用方按自己的枚举过滤。
    static func menuOrder(kernel: [LianaLanguage], platformIDs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for language in kernel where seen.insert(language.id).inserted {
            out.append(language.id)
        }
        for id in platformIDs where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
}
