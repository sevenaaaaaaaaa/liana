import Foundation

@main
struct FoldLayoutTests {
    static func main() {
        for width in [320.0, 360, 375, 390, 430, 568, 599] {
            let layout = FoldLayout.derive(width: width, regularWidth: false, rememberedSoloPitch: nil)
            let row = 10 * layout.pitch + 9 * layout.gap + 2 * layout.margin
            precondition(row <= width + 0.01, "Letter row exceeds screen width: \(width)")
            let available = width - 2 * layout.margin
            let function = min(50, (available - 72 - 5 * layout.gap) / 5)
            let space = available - 5 * function - 5 * layout.gap
            precondition(space >= 72 && function >= 44)
            let third = layout.thirdRowGeometry(keyCount: 7)
            precondition(third.sideWidth >= 44)
            precondition(2 * third.sideWidth + 7 * third.keyWidth + 8 * layout.gap <= available + 0.01)
        }
        for width in [600.0, 768, 834, 1024, 1366] {
            let layout = FoldLayout.derive(width: width, regularWidth: true, rememberedSoloPitch: 34)
            precondition(layout.mode == .split)
            precondition(layout.clusterWidth * 2 + layout.gutterWidth + layout.margin * 2 <= width + 0.01)
        }
        print("iOS keyboard layout: 320–599pt phone rows, function keys and 600–1366pt split geometry passed")
    }
}
