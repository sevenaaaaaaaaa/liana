import Foundation

/// Values stay in the keyboard's own sandbox; ordinary typing needs no shared group.
struct KeyboardPreferences: Codable, Equatable {
    var keyHeight: Double = 46
    var width: Double = 1
    var alignment: Double = 0.5
    var candidateFont: Double = 17
    var bottomPadding: Double = 0
    var entryPosition: Double = 1

    mutating func normalize() {
        keyHeight = Self.clamp(keyHeight, 44...64, fallback: 46)
        width = Self.clamp(width, 0.78...1, fallback: 1)
        alignment = Self.clamp(alignment, 0...1, fallback: 0.5)
        candidateFont = Self.clamp(candidateFont, 14...24, fallback: 17)
        bottomPadding = Self.clamp(bottomPadding, 0...24, fallback: 0)
        entryPosition = Self.clamp(entryPosition, 0...1, fallback: 1)
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
