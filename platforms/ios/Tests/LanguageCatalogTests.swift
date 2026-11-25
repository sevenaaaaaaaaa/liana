import Foundation

@main
struct LanguageCatalogTests {
    /// 内核真实输出（顺序 = builtin_languages()：四个中文在前，其余按 id 字典序）。
    static let kernelJSON = #"[{"id":"pinyin","label":"拼音","policy":"ascii"},{"id":"flypy","label":"小鹤双拼","policy":"ascii"},{"id":"mspy","label":"微软双拼","policy":"ascii"},{"id":"zrm","label":"自然码","policy":"ascii"},{"id":"emoji","label":"表情","policy":"ascii"},{"id":"en","label":"English","policy":"ascii"},{"id":"es","label":"Español","policy":"unicode"},{"id":"ja","label":"日本語","policy":"ascii"},{"id":"ko","label":"한국어","policy":"ascii"}]"#

    static func main() {
        parsing()
        fallback()
        ordering()
        print("iOS 语言清单：内核 JSON 解析 / 回退 / 菜单顺序 passed")
    }

    static func parsing() {
        let parsed = LanguageCatalog.parse(kernelJSON)
        precondition(parsed.count == 9, "应解析出 9 项，实际 \(parsed.count)")
        precondition(parsed.map(\.id) == ["pinyin", "flypy", "mspy", "zrm", "emoji", "en", "es", "ja", "ko"],
                     "内核顺序被改写：\(parsed.map(\.id))")
        precondition(parsed[7].label == "日本語" && parsed[8].label == "한국어")
        precondition(parsed[6].policy == "unicode", "重音语言必须是 unicode 闸门")

        // 坏输入一律返回空数组，交给 load 兜底——不许返回半截清单。
        for bad in [nil, "", "   ", "[]", "{}", "not json", "<html>", #"[{"label":"缺 id"}]"#] as [String?] {
            precondition(LanguageCatalog.parse(bad).isEmpty, "坏输入应返回空：\(bad ?? "nil")")
        }

        // 缺 label 用 id 顶；重复 id 保留第一个；未知字段忽略。
        let messy = #"[{"id":"ja","policy":"ascii"},{"id":"ja","label":"重复"},{"id":"ko","label":"","policy":"x"},{"id":"es","label":"Español","extra":1}]"#
        let rows = LanguageCatalog.parse(messy)
        precondition(rows.map(\.id) == ["ja", "ko", "es"], "去重/保序不对：\(rows.map(\.id))")
        precondition(rows[0].label == "ja", "缺 label 应用 id 顶上")
        precondition(rows[1].label == "ko", "空 label 应用 id 顶上")
        precondition(rows[2].label == "Español")
    }

    static func fallback() {
        let nilFetch = LanguageCatalog.load { nil }
        precondition(nilFetch == LanguageCatalog.fallback, "内核没给清单时必须回退")
        precondition(nilFetch.count == 9)

        let broken = LanguageCatalog.load { "garbage" }
        precondition(broken == LanguageCatalog.fallback, "坏 JSON 必须回退")

        let live = LanguageCatalog.load { kernelJSON }
        precondition(live.map(\.id) == LanguageCatalog.fallback.map(\.id),
                     "回退清单与内核清单的 id/顺序必须一致，否则两边菜单不一样")

        // 回退清单本身要覆盖内核 9 项，不能少一门。
        let ids = Set(LanguageCatalog.fallback.map(\.id))
        for required in ["pinyin", "flypy", "mspy", "zrm", "emoji", "en", "es", "ja", "ko"] {
            precondition(ids.contains(required), "回退清单缺 \(required)")
        }
    }

    static func ordering() {
        let kernel = LanguageCatalog.parse(kernelJSON)
        let order = LanguageCatalog.menuOrder(kernel: kernel, platformIDs: ["t9", "wubi", "handwriting"])
        precondition(order == ["pinyin", "flypy", "mspy", "zrm", "emoji", "en", "es", "ja", "ko",
                               "t9", "wubi", "handwriting"],
                     "菜单顺序不对：\(order)")

        // 平台方案与内核 id 撞名时不许出现两次（否则菜单里点「拼音」切到别的会话）。
        let clash = LanguageCatalog.menuOrder(kernel: kernel, platformIDs: ["ja", "t9"])
        precondition(clash.filter { $0 == "ja" }.count == 1, "重复 id 应只留内核那一个")
        precondition(clash.last == "t9")
    }
}
