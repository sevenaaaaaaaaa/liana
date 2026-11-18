import Foundation

@main
struct CandidateNoiseFilterTests {
    static func main() {
        // 混排候选：中文夹拉丁/数字一律丢弃（「看1080P」「2K一」）。
        precondition(CandidateNoiseFilter.isMixedScript("看1080P"), "中文+拉丁应判为混排")
        precondition(CandidateNoiseFilter.isMixedScript("2K一"), "数字+中文应判为混排")
        precondition(CandidateNoiseFilter.isMixedScript("Hello你好"), "拉丁+中文应判为混排")
        precondition(!CandidateNoiseFilter.isMixedScript("可以"), "纯中文不是混排")
        precondition(!CandidateNoiseFilter.isMixedScript("Wi-Fi"), "纯拉丁不是混排")
        precondition(!CandidateNoiseFilter.isMixedScript("5G"), "数字+拉丁不是混排")
        precondition(!CandidateNoiseFilter.isMixedScript(""), "空串不是混排")

        // 九宫格漏按一位：想打「可以」keyi = 5 3 9 4，漏了 3 只剩 5 9 4，
        // 补一位必须能补出 5394，词库才能查到「可以」。
        let missing = CandidateNoiseFilter.digitVariants("594")
        let insertOnly = CandidateNoiseFilter.digitVariants("594", includeDeletions: false)
        precondition(insertOnly.contains("5394"), "只补位时也要补出 5394")
        precondition(insertOnly.allSatisfy { $0.count == 4 }, "只补位不应产生更短的变体")
        precondition(missing.contains("5394"), "漏按一位应补出 5394")
        precondition(Set(missing).count == missing.count, "变体不应重复")
        precondition(missing.count <= 48, "变体数量必须有上限")
        precondition(!missing.contains("594"), "变体不应包含原串")

        // 多按一位：删掉一位也要能找回目标串。
        let extra = CandidateNoiseFilter.digitVariants("53994")
        precondition(extra.contains("5394"), "多按一位应删出 5394")

        // 单键与非法输入不纠错，避免一次按键就触发大量查询。
        precondition(CandidateNoiseFilter.digitVariants("5").isEmpty, "单键不纠错")
        precondition(CandidateNoiseFilter.digitVariants("abc").isEmpty, "非数字不纠错")
        precondition(CandidateNoiseFilter.digitVariants("").isEmpty, "空串不纠错")

        print("候选噪声过滤与九宫格漏键容错：混排过滤 / 补一位 / 删一位 / 边界 全部通过")
    }
}
