import Foundation

/// 桌宠注视（gaze）推送闸门。
///
/// 为什么要有这个类型：PetWindow.followTick 跑在 30Hz 的 shakeTimer 上，
/// 每隔一帧就往 WKWebView 里 evaluateJavaScript("petSetGaze(...)") 一次。
/// WebKit 对每一次 runJavaScriptInFrameInScriptWorld 都会创建并立刻销毁一个
/// foreground ProcessThrottler::Activity，而 activity 的 create / invalidate
/// 各触发一次 updateThrottleStateIfNeeded。于是「鼠标一动不动」的桌宠在空闲时
/// 也在以 15 次/秒 = 30 次状态切换/秒 的速度敲 WebContent 的门。
///
/// 息屏 / 锁屏 / 窗口被遮挡时 NSWindow 依然 isVisible，这条 30Hz 循环照跑：
/// WebKit 想把 WebContent 降级或挂起，每 33ms 又被一个 foreground activity
/// 拽回来 → powerd 反复 Sleep revert → 2026-11-23 的整机冻结。
///
/// 页面侧本来就会自己做平滑，所以这里只回答一个问题：
/// 这一帧的姿态和上一帧真的不一样吗？不一样才值得发一次 JS。
///
/// 纯逻辑、零 AppKit 依赖，好让 scripts/test-logic.sh 在没有窗口、没有 WebKit
/// 的机器上把它钉住（platforms/macos/tests/PetGazeGateTests.swift）。
struct PetGazeSample: Equatable {
    /// 归一化后的光标方向，[-1, 1]
    var dx: Double
    var dy: Double
    /// 光标靠近程度，[0, 1]
    var near: Double
}

struct PetGazeGate {
    /// 小于这个量就不推：手静止时的坐标抖动、以及页面自己会插值掉的变化。
    static let epsilon = 0.02

    private var last: PetGazeSample?

    /// 从「暂停」恢复时调用：下一帧无条件推一次，保证页面不是旧姿态。
    mutating func reset() { last = nil }

    /// 返回 true 表示这一帧值得发一次 evaluateJavaScript。
    mutating func shouldEmit(_ sample: PetGazeSample) -> Bool {
        let clamped = PetGazeSample(
            dx: min(max(sample.dx, -1), 1),
            dy: min(max(sample.dy, -1), 1),
            near: min(max(sample.near, 0), 1)
        )
        if let last,
           abs(clamped.dx - last.dx) < Self.epsilon,
           abs(clamped.dy - last.dy) < Self.epsilon,
           abs(clamped.near - last.near) < Self.epsilon {
            return false
        }
        last = clamped
        return true
    }
}
