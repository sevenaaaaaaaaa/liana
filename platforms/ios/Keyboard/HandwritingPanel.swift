import UIKit

final class HandwritingPanel: UIView {
    var onStrokes: (([[[Double]]]) -> Void)?
    private var strokes: [[CGPoint]] = []
    private var current: [CGPoint] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = LianaTheme.key
        layer.cornerRadius = 10
        accessibilityLabel = "手写区域，按笔顺书写单个汉字"
        accessibilityIdentifier = "handwriting.canvas"
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func clear() { strokes = []; current = []; setNeedsDisplay() }
    func undo() { if !strokes.isEmpty { strokes.removeLast() }; setNeedsDisplay(); recognize() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { current = touches.first.map { [$0.location(in: self)] } ?? [] }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { current += (event?.coalescedTouches(for: touch) ?? [touch]).map { $0.location(in: self) } }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let point = touches.first?.location(in: self) { current.append(point) }
        if current.count > 1 { strokes.append(current) }
        current = []; setNeedsDisplay(); recognize()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { current = []; setNeedsDisplay() }
    private func recognize() {
        let scale = max(1, max(bounds.width, bounds.height))
        onStrokes?(strokes.map { $0.map { [Double($0.x/scale*256),Double($0.y/scale*256)] } })
    }
    override func draw(_ rect: CGRect) {
        UIColor.separator.setStroke()
        let guides = UIBezierPath(); guides.lineWidth = 1
        guides.move(to: CGPoint(x: bounds.midX,y: 0)); guides.addLine(to: CGPoint(x: bounds.midX,y: bounds.height))
        guides.move(to: CGPoint(x: 0,y: bounds.midY)); guides.addLine(to: CGPoint(x: bounds.width,y: bounds.midY))
        guides.setLineDash([4,4], count: 2, phase: 0); guides.stroke()
        LianaTheme.text.setStroke()
        for stroke in strokes + [current] where stroke.count > 1 {
            let path = UIBezierPath(); path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: stroke[0]); stroke.dropFirst().forEach { path.addLine(to: $0) }; path.stroke()
        }
    }
}
