import Foundation

/// 用 swiftc 直接跑的纯逻辑测试，不需要模拟器：
///   swiftc platforms/ios/Keyboard/CommandCatalog.swift \
///          platforms/ios/Tests/CommandCatalogTests.swift -o /tmp/liana-command-catalog
///   /tmp/liana-command-catalog
@main
struct CommandCatalogTests {
    static func main() {
        // 1. 排序稳定：同一输入两次结果必须一致，否则面板每次刷新顺序都在变。
        for hasText in [true, false] {
            let a = CommandCatalog.ordered(hasText: hasText).map(\.id)
            let b = CommandCatalog.ordered(hasText: hasText).map(\.id)
            precondition(a == b, "排序不稳定: \(a) vs \(b)")
            precondition(a.count == CommandCatalog.catalog.count, "排序丢了算子: \(a)")
            precondition(Set(a) == Set(CommandCatalog.catalog.map(\.id)))
        }

        // 2. 有文字时，需要文字的算子必须排在最前；没文字时必须沉到后面。
        let withText = CommandCatalog.ordered(hasText: true)
        precondition(withText.first?.needsText == true, "有文字时首位应为依赖文字的算子")
        precondition(withText.first?.id == "copy", "有文字时首位应是「复制这段文字」")
        let withoutText = CommandCatalog.ordered(hasText: false)
        precondition(withoutText.first?.needsText == false, "没文字时首位不应依赖文字")
        precondition(withoutText.contains { $0.id == "copy" }, "没文字时复制仍应在列，只是沉后")
        precondition(withoutText.last?.needsText == true, "没文字时依赖文字的算子应在末尾")

        // 3. 摘录只取尾部，且首尾空白被去掉。
        let long = String(repeating: "甲", count: 80)
        let snippet = CommandCatalog.snippet(long, limit: 10)
        precondition(snippet.hasPrefix("…"), "长文本应带省略号")
        precondition(snippet.count == 11, "应保留 10 个字加一个省略号，实际 \(snippet.count)")
        precondition(CommandCatalog.snippet("  短文  ") == "短文", "首尾空白应去掉")
        precondition(CommandCatalog.snippet("") == "", "空串应返回空串")

        // 4. 每个算子都必须能被分发：id 唯一，且分发器认识的 id 与清单一致。
        let ids = CommandCatalog.catalog.map(\.id)
        precondition(Set(ids).count == ids.count, "算子 id 重复: \(ids)")
        let handled: Set<String> = ["copy", "traditional", "cursor.left", "cursor.right", "phrase", "receive", "coach", "feel", "toolbox"]
        precondition(Set(ids) == handled, "清单与分发器不一致: \(Set(ids).symmetricDifference(handled))")

        print("Command catalog: \(ids.count) operators, ordering stable, snippet tail-only, dispatcher in sync")
    }
}
