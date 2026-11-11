import UIKit

final class KeyboardInputView: UIInputView {
    var requestedHeight: CGFloat = 301 {
        didSet { if abs(oldValue - requestedHeight) > 0.5 { invalidateIntrinsicContentSize() } }
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: requestedHeight) }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: requestedHeight)
    }
}
