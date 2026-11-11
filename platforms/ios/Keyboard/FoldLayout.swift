import Foundation

/// 折叠屏布局策略（唯一事实源：docs/design/FOLDABLE-ADAPTATION.md §4）。
///
/// 核心不变量：
/// - 键距由**外屏（窄屏）宽度**决定，内屏复用同一 dp 值，漂移上限 +10%；
/// - 键高 / 键距 / 行数 / 字符位置在两种形态下恒定；
/// - 屏宽多出来的部分只喂「中缝」，由工作台吸收，绝不摊给按键。
struct FoldLayout {

    enum Mode: String {
        case solo   // 单块键盘（外屏 / 手机）
        case split  // 左右分体 + 中缝工作台（内屏 / Pad）
    }

    let mode: Mode
    let pitch: CGFloat       // 键距（含间隙），dp
    let gap: CGFloat         // 键间隙，dp
    let margin: CGFloat      // 键组到屏边，dp
    let keyHeight: CGFloat   // 键高，dp
    let clusterWidth: CGFloat // 单侧键组宽（split 有效；solo 为整块宽）
    let gutterWidth: CGFloat  // 中缝宽（split 有效）

    // ---- 常量（两形态恒等） ----
    static let gapConst: CGFloat = 4
    static let marginConst: CGFloat = 4
    static let keyHeightConst: CGFloat = 46
    static let minPitch: CGFloat = 34
    static let maxSoloPitch: CGFloat = 46
    static let maxSplitPitch: CGFloat = 48
    static let minGutter: CGFloat = 56
    static let splitMinWidth: CGFloat = 600
    /// 单侧 5 列（qwertyuiop / asdfghjkl / zxcvbnm 的首行均取 5 列）。
    static let columnsPerHalf = 5

    static func soloPitch(for width: CGFloat) -> CGFloat {
        let raw = (width - 2 * marginConst - 9 * gapConst) / 10
        return max(1, min(raw, maxSoloPitch))
    }

    func thirdRowGeometry(keyCount: Int) -> (keyWidth: CGFloat, sideWidth: CGFloat) {
        let count = CGFloat(max(1, keyCount))
        let keyWidth = min(pitch, (clusterWidth - 88 - (count + 1) * gap) / count)
        return (keyWidth, (clusterWidth - count * keyWidth - (count + 1) * gap) / 2)
    }

    /// - Parameters:
    ///   - width: 当前键盘可用宽度（pt）
    ///   - regularWidth: horizontalSizeClass == .regular
    ///   - rememberedSoloPitch: 该设备最近一次窄屏（<600pt）的键距；无则 nil
    static func derive(width: CGFloat, regularWidth: Bool, rememberedSoloPitch: CGFloat?, keyHeight: CGFloat = keyHeightConst) -> FoldLayout {
        let split = regularWidth && width >= splitMinWidth
        guard split else {
            let p = soloPitch(for: width)
            return FoldLayout(mode: .solo, pitch: p, gap: gapConst, margin: marginConst,
                              keyHeight: keyHeight,
                              clusterWidth: width - 2 * marginConst, gutterWidth: 0)
        }
        let base = rememberedSoloPitch ?? 44
        let pitch = min(max(base * 1.10, minPitch), maxSplitPitch)
        let cluster = CGFloat(columnsPerHalf) * pitch + CGFloat(columnsPerHalf - 1) * gapConst
        let gutter = max(minGutter, width - 2 * cluster - 2 * marginConst)
        return FoldLayout(mode: .split, pitch: pitch, gap: gapConst, margin: marginConst,
                          keyHeight: keyHeight, clusterWidth: cluster, gutterWidth: gutter)
    }

    /// 布局签名：只有它变化才重建视图（避免逐帧重排）。
    var signature: String {
        "\(mode.rawValue)-\(pitch)-\(clusterWidth)-\(keyHeight)"
    }
}

/// 每设备布局记忆保存在键盘自身容器，不要求 App Group 或完全访问。
enum FoldLayoutMemory {
    private static let soloPitchKey = "layout.pitchSolo"
    private static let soloWidthKey = "layout.soloWidth"

    private static var defaults: UserDefaults? { .standard }

    static var rememberedSoloPitch: CGFloat? {
        guard let v = defaults?.object(forKey: soloPitchKey) as? Double, v >= 24, v <= 46 else { return nil }
        return CGFloat(v)
    }

    /// 记录窄屏键距（只在 solo 形态下调用）。
    static func rememberSolo(pitch: CGFloat, width: CGFloat) {
        guard width >= 300, width < FoldLayout.splitMinWidth else { return }
        defaults?.set(Double(pitch), forKey: soloPitchKey)
        defaults?.set(Double(width), forKey: soloWidthKey)
    }

    static var rememberedSoloWidth: CGFloat? {
        guard let v = defaults?.object(forKey: soloWidthKey) as? Double else { return nil }
        return CGFloat(v)
    }
}
