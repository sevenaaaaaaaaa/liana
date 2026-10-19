import Foundation

/// 长句 AI 重排：打长句停顿时，用本机小模型给前几条整句候选打分，明显更通顺的那条提到第一位。
///
/// - 只在本机：模型跑在用户自己装的 llama-server 上（127.0.0.1），句子不出设备；
/// - 只管长句：首选是 6 个字以上的整句、且有 2 条以上整句候选时才触发，停顿 0.25 秒后异步进行，不拖慢打字；
/// - 宁少勿错：模型分数比当前首选高出 `margin` 才换；结果回来时输入已经变了就作废。
///
/// 打分方式与评测见 ADR-0012 的「后续」与 `TranslateClient.score`（Qwen2.5 0.5B：日常整句首选 81% → 86%，困难集不退步）。
enum SentenceRerank {
    private static let key = "LianaAIRerank"
    /// 引导语：给模型一个「接下来是日常中文」的上下文（Qwen 没有开头标记，空提示词算不出分）
    static let prefix = "下面是一句日常的中文："
    /// 至少几个字的整句才重排
    static let minChars = 6
    /// 模型 log 概率要比当前首选高出多少才换（实测 2 时偶尔会把对的改错）
    static let margin = 3.0
    static let timeout: TimeInterval = 1.5

    /// 设置开关：默认开（只有装了合适的本机模型和 llama-server 才真正生效）
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 能不能用：开关开着、有 llama-server、有合格的模型。
    static var available: Bool {
        enabled && TranslateClient.findRuntime() != nil && TranslateClient.rerankModelPath() != nil
    }

    /// 给几条整句打分，返回应当排第一的下标（0 = 保持原样）；不可用或出错时返回 nil。
    static func pick(_ sentences: [String], completion: @escaping (Int?) -> Void) {
        guard sentences.count >= 2, available else { return completion(nil) }
        TranslateClient.rerank.score(sentences, prefix: prefix, timeout: timeout) { scores in
            guard let scores, scores.count == sentences.count,
                  let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return completion(nil) }
            completion(best != 0 && scores[best] - scores[0] > margin ? best : 0)
        }
    }
}
