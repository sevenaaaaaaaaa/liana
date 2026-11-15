import Foundation

/// 命令台的算子清单与排序——**纯逻辑，不依赖 UIKit**。
///
/// 单独成文件只为一件事：能在没有模拟器的情况下用 swiftc 直接跑测试，
/// 和 FoldLayout.swift + FoldLayoutTests.swift 是同一条路。
/// 排序是面板的核心行为（谁该在第一位），它不该只能在真机上看。
enum CommandCatalog {

    /// 一个算子。只描述，不带闭包。
    struct Op: Equatable {
        let id: String
        let title: String
        let icon: String
        /// 是否需要「当前对象」才有意义（没文字时沉到后面）。
        let needsText: Bool
    }

    /// 面板里出现的全部算子。新增能力往这里加一行即可。
    static let catalog: [Op] = [
        Op(id: "copy", title: "复制这段文字", icon: "doc.on.doc", needsText: true),
        Op(id: "traditional", title: "切换简繁", icon: "character.book.closed", needsText: false),
        Op(id: "cursor.left", title: "光标左移", icon: "arrow.left", needsText: true),
        Op(id: "cursor.right", title: "光标右移", icon: "arrow.right", needsText: false),
        Op(id: "phrase", title: "常用短语", icon: "text.bubble", needsText: false),
        Op(id: "receive", title: "接收内容", icon: "tray.and.arrow.down", needsText: false),
        Op(id: "feel", title: "布局与手感", icon: "slider.horizontal.3", needsText: false),
        Op(id: "toolbox", title: "更多工具", icon: "square.grid.2x2", needsText: false),
    ]

    /// 有文字时「需要文字」的算子排前面，没文字时沉到后面。
    /// 排序保持稳定——同一组输入永远给出同一个顺序，测试才有意义。
    static func ordered(hasText: Bool) -> [Op] {
        let first = catalog.filter { $0.needsText == hasText }
        let second = catalog.filter { $0.needsText != hasText }
        return first + second
    }

    /// 只显示尾部一小段：光标前的文字可能很长，取末尾才有上下文价值。
    static func snippet(_ text: String, limit: Int = 48) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }
}
