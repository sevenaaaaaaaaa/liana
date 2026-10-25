import Foundation

/// 代码模式口述：语音识别原文 → 代码风格文本（可选功能，默认关）。
///
/// - 符号词：说「点」落 `.`、「箭头」落 `->`、「井号」落 `#`……中文正文照常上屏
/// - 命名模式口令：「驼峰」「下划线模式」「常量模式」切换后续连续英文词的拼接方式
///   （说 “驼峰 get user” 落 `getUser`），跨语句保持，说「普通模式」还原
/// - 「大写」让下一个词首字母大写
///
/// 纯字符串处理：状态显式传入不藏全局，逐 token 精确匹配（正文里提到“点”字
/// 不会被替换，只有独立的“点” token 才是符号词）。
struct DevDictationState {
    enum Naming { case none, camel, snake, constant }
    var naming: Naming = .none
}

enum DevDictation {
    static let enabledKey = "LianaVoiceCodeMode"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 符号词表：识别原文 token（整词精确匹配）→ 代码符号
    static let symbols: [String: String] = [
        "点": ".", "句号": ".", "点号": ".",
        "逗号": ",", "顿号": ",",
        "冒号": ":", "分号": ";",
        "等于": "=", "等于等于": "==", "三等于": "===",
        "大于": ">", "小于": "<", "大于等于": ">=", "小于等于": "<=", "不等于": "!=",
        "箭头": "->", "下划线": "_", "连字符": "-", "横杠": "-",
        "斜杠": "/", "反斜杠": "\\", "井号": "#", "星号": "*",
        "加号": "+", "百分号": "%", "美元": "$", "艾特": "@",
        "感叹号": "!", "问号": "?",
        "左括号": "(", "开括号": "(", "右括号": ")", "闭括号": ")",
        "左花括号": "{", "右花括号": "}", "大括号": "{}",
        "左方括号": "[", "右方括号": "]", "中括号": "[]",
        "双引号": "\"", "单引号": "'", "空格": " ",
    ]

    /// 处理一句识别原文；state 跨语句保持（命名模式），每次开听重置。
    static func process(_ text: String, state: inout DevDictationState) -> String {
        var out: [String] = []
        var latinRun: [String] = []   // 命名模式下积攒的连续英文词
        var capitalizeNext = false

        func cap(_ word: String) -> String {
            guard let f = word.first else { return word }
            return String(f).uppercased() + word.dropFirst()
        }
        func applyCase(_ word: String) -> String {
            if capitalizeNext {
                capitalizeNext = false
                return cap(word)
            }
            return word
        }
        func flushRun() {
            guard !latinRun.isEmpty else { return }
            let words = latinRun
            latinRun = []
            switch state.naming {
            case .camel:
                out.append(words.enumerated().map { i, w in
                    let lower = w.lowercased()
                    return i == 0 ? applyCase(lower) : cap(lower)
                }.joined())
            case .snake:
                out.append(words.map { applyCase($0.lowercased()) }.joined(separator: "_"))
            case .constant:
                out.append(words.map { $0.uppercased() }.joined(separator: "_"))
            case .none:
                out.append(words.map { applyCase($0) }.joined(separator: " "))
            }
        }
        let isLatin = { (t: String) in !t.isEmpty && t.allSatisfy { $0.isASCII && $0.isLetter } }

        for rawToken in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let token = String(rawToken)
            if let symbol = symbols[token] {
                flushRun()
                out.append(symbol)
                continue
            }
            switch token {
            case "驼峰", "驼峰模式":
                flushRun()
                state.naming = .camel
                continue
            case "下划线模式", "蛇形":
                flushRun()
                state.naming = .snake
                continue
            case "常量模式", "全大写模式":
                flushRun()
                state.naming = .constant
                continue
            case "普通模式", "取消命名":
                flushRun()
                state.naming = .none
                continue
            case "大写":
                capitalizeNext = true
                continue
            default:
                break
            }
            if isLatin(token) {
                latinRun.append(applyCase(token))
                continue
            }
            flushRun()
            out.append(token)
        }
        flushRun()
        return out.joined()
    }
}
