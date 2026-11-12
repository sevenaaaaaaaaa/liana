import UIKit

/// 长按滑动手势的默认时序（集中定义，便于后续做成偏好）。
enum KeyboardGestureDefaults {
    /// 删除键：按住 3 秒后上滑清空。
    static let clearHold: TimeInterval = 3
    /// 回车 / 九键数字键：按住 1 秒后滑动。
    static let hold: TimeInterval = 1
    /// armed 之后需要的最小位移。
    static let swipeThreshold: CGFloat = 28
}

enum HoldSwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// 纯逻辑：给定按住时长与位移，判定是否 armed / 触发哪个方向。
/// 控制器只负责把触摸时间与位移喂进来。
struct HoldSwipePolicy: Equatable {
    var holdDuration: TimeInterval
    var threshold: CGFloat

    init(holdDuration: TimeInterval = KeyboardGestureDefaults.hold,
         threshold: CGFloat = KeyboardGestureDefaults.swipeThreshold) {
        self.holdDuration = max(0, holdDuration)
        self.threshold = max(0, threshold)
    }

    enum Outcome: Equatable {
        case none
        case armed
        case fire(HoldSwipeDirection)
        case cancelled
    }

    /// 主方向：位移达到阈值且取绝对值更大的轴；对角线等值按竖向处理。
    func direction(for translation: CGPoint) -> HoldSwipeDirection? {
        let x = translation.x
        let y = translation.y
        guard abs(x) >= threshold || abs(y) >= threshold else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .down : .up
    }

    func outcome(elapsed: TimeInterval,
                 translation: CGPoint,
                 armed: Bool,
                 cancelled: Bool = false) -> Outcome {
        if cancelled { return .cancelled }
        if !armed {
            // 时间差用 1ms 容差，避免定时器先到、moved 后到的边界误判。
            return elapsed + 0.001 >= holdDuration ? .armed : .none
        }
        return direction(for: translation).map(Outcome.fire) ?? .none
    }
}

/// 有状态的判定器：识别器内部使用；测试也可直接驱动。
struct HoldSwipeTracker {
    var policy: HoldSwipePolicy
    private(set) var armed = false
    private(set) var fired = false

    init(policy: HoldSwipePolicy = HoldSwipePolicy()) {
        self.policy = policy
    }

    mutating func begin() {
        armed = false
        fired = false
    }

    /// 定时器到期 / moved 时调用；达到时长返回 true（只 arm 一次）。
    @discardableResult
    mutating func armIfDue(elapsed: TimeInterval) -> Bool {
        guard !armed, !fired, elapsed + 0.001 >= policy.holdDuration else { return false }
        armed = true
        return true
    }

    /// armed 之后调用；返回方向即触发一次（只触发一次）。
    mutating func swipe(translation: CGPoint) -> HoldSwipeDirection? {
        guard armed, !fired, let direction = policy.direction(for: translation) else { return nil }
        fired = true
        return direction
    }

    mutating func finish() {
        armed = false
        fired = false
    }

    /// 取消（松手/被打断）：之后不再触发。
    mutating func cancel() {
        armed = false
        fired = false
    }
}

/// 可复用的「按住 N 秒后滑动」识别器。
///
/// - 未达到时长就松手：不识别，按钮自己的点按行为照旧；
/// - 达到时长：进入 armed（回调通知上层给触觉/提示）；
/// - armed 后位移达到阈值：识别一次并触发回调；cancelsTouchesInView
///   会取消按钮本身的触摸，避免「清空」和「删除」同时发生。
final class HoldSwipeGestureRecognizer: UIGestureRecognizer {
    let policy: HoldSwipePolicy
    var onArmed: (() -> Void)?
    var onFire: ((HoldSwipeDirection) -> Void)?
    private var armed = false
    private var fired = false
    private var startTime: TimeInterval = 0
    private var startPoint: CGPoint = .zero
    private var holdTimer: Timer?

    init(policy: HoldSwipePolicy = HoldSwipePolicy()) {
        self.policy = policy
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
        delaysTouchesEnded = false
    }

    // MARK: - 真实触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        begin(at: touches.first?.location(in: view) ?? .zero)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        update(elapsed: CACurrentMediaTime() - startTime,
               translation: CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y),
               fromTouch: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        cancel()
    }

    override func reset() {
        super.reset()
        holdTimer?.invalidate()
        holdTimer = nil
        armed = false
        fired = false
    }

    deinit { holdTimer?.invalidate() }

    // MARK: - 测试/复用入口（与真实触摸共用同一状态机）

    func begin(at point: CGPoint = .zero) {
        armed = false
        fired = false
        startPoint = point
        startTime = CACurrentMediaTime()
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: policy.holdDuration, repeats: false) { [weak self] _ in
            guard let self, !self.armed, !self.fired else { return }
            self.arm()
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func update(elapsed: TimeInterval, translation: CGPoint, fromTouch: Bool = false) {
        switch policy.outcome(elapsed: elapsed, translation: translation, armed: armed) {
        case .armed:
            arm()
        case .fire(let direction):
            guard !fired else { return }
            fired = true
            holdTimer?.invalidate()
            if fromTouch { state = .recognized }
            onFire?(direction)
        case .none, .cancelled:
            break
        }
    }

    func finish() {
        holdTimer?.invalidate()
        holdTimer = nil
        armed = false
        fired = false
    }

    func cancel() {
        holdTimer?.invalidate()
        holdTimer = nil
        armed = false
        fired = false
    }

    private func arm() {
        guard !armed, !fired else { return }
        armed = true
        holdTimer?.invalidate()
        onArmed?()
    }
}
