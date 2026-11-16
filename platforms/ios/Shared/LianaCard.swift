import Foundation

/// 卡片渲染的唯一入口：直调 Rust 内核的排版树。
///
/// 这里刻意不写任何排版代码——HTML 和 Markdown 都由 liana-card 从同一棵树
/// 生成，Swift 侧只负责把字符串递过去、把结果接回来。
enum LianaCard {

    /// 生成自包含的卡片 HTML。文本为空或内核返回空指针时给 nil。
    static func html(from text: String, meta: String?) -> String? {
        take(render(text: text, meta: meta, markdown: false))
    }

    /// 同一棵树导出的 Markdown。
    static func markdown(from text: String, meta: String?) -> String? {
        take(render(text: text, meta: meta, markdown: true))
    }

    private static func render(text: String, meta: String?, markdown: Bool) -> UnsafeMutablePointer<CChar>? {
        let cleanMeta = meta?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanMeta, !cleanMeta.isEmpty {
            return text.withCString { raw in
                cleanMeta.withCString { metaPtr in
                    markdown ? liana_card_markdown(raw, metaPtr) : liana_card_html(raw, metaPtr)
                }
            }
        }
        return text.withCString { raw in
            markdown ? liana_card_markdown(raw, nil) : liana_card_html(raw, nil)
        }
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { liana_free_string(pointer) }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    /// 卡片页脚的固定格式：日期 · 来源。
    static func stamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) · 本机生成"
    }
}
