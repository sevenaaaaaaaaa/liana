import Foundation

/// 九键（九宫格）布局形态。
/// - sidebar：中间标准 3x3，左右窄列放符号与功能键（默认，拇指移动距离更短）。
/// - classic：中间 3x3，每行右侧一个附加键（⌫/清空/工具）。
enum NineKeyLayout: String, Codable, CaseIterable {
    case sidebar
    case classic

    var title: String {
        switch self {
        case .sidebar: return "九键 · 侧栏"
        case .classic: return "九键 · 经典"
        }
    }
}

/// Values stay in the keyboard's own sandbox; ordinary typing needs no shared group.
struct KeyboardPreferences: Codable, Equatable {
    var keyHeight: Double = 46
    var width: Double = 1
    var alignment: Double = 0.5
    var candidateFont: Double = 17
    var bottomPadding: Double = 0
    var entryPosition: Double = 1
    /// 九键布局形态。旧版本保存的数据里没有这个字段，解码时回落为新默认（侧栏）。
    var nineKeyLayout: NineKeyLayout = .sidebar
    /// 九键数字键 / 回车键的长按滑动手势前置时长（秒）。删除键的清空手势固定 3 秒。
    var gestureHold: Double = KeyboardGestureDefaults.hold

    init() {}

    private enum CodingKeys: String, CodingKey {
        case keyHeight, width, alignment, candidateFont, bottomPadding, entryPosition, nineKeyLayout, gestureHold
    }

    // 手写 init(from:)：新增字段只做 decodeIfPresent，旧快照仍能恢复其余手感设置。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyHeight = try values.decodeIfPresent(Double.self, forKey: .keyHeight) ?? 46
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 1
        alignment = try values.decodeIfPresent(Double.self, forKey: .alignment) ?? 0.5
        candidateFont = try values.decodeIfPresent(Double.self, forKey: .candidateFont) ?? 17
        bottomPadding = try values.decodeIfPresent(Double.self, forKey: .bottomPadding) ?? 0
        entryPosition = try values.decodeIfPresent(Double.self, forKey: .entryPosition) ?? 1
        nineKeyLayout = try values.decodeIfPresent(NineKeyLayout.self, forKey: .nineKeyLayout) ?? .sidebar
        gestureHold = try values.decodeIfPresent(Double.self, forKey: .gestureHold) ?? KeyboardGestureDefaults.hold
    }

    mutating func normalize() {
        keyHeight = Self.clamp(keyHeight, 44...64, fallback: 46)
        width = Self.clamp(width, 0.78...1, fallback: 1)
        alignment = Self.clamp(alignment, 0...1, fallback: 0.5)
        candidateFont = Self.clamp(candidateFont, 14...24, fallback: 17)
        bottomPadding = Self.clamp(bottomPadding, 0...24, fallback: 0)
        entryPosition = Self.clamp(entryPosition, 0...1, fallback: 1)
        gestureHold = Self.clamp(gestureHold, 0.5...2, fallback: KeyboardGestureDefaults.hold)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    func contentWidth(in available: CGFloat) -> CGFloat {
        min(available, max(320, available * CGFloat(width)))
    }

    static func load(from defaults: UserDefaults = .standard) -> KeyboardPreferences {
        guard let data = defaults.data(forKey: "keyboard.layout.v1"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.normalize()
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        var value = self
        value.normalize()
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "keyboard.layout.v1") }
    }
}
