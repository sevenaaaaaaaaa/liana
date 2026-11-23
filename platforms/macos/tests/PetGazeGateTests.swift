import Foundation

// PetGazeGate 回归：2026-11-23「空闲整机冻结」事故的最小可验单元。
//
// 事故链：PetWindow.followTick 以 15Hz 无条件 evaluateJavaScript("petSetGaze")，
// WebKit 为每一次 runJavaScriptInFrameInScriptWorld 创建并立刻销毁一个 foreground
// ProcessThrottler activity；空闲/息屏时这 30 次状态切换/秒 把 WebContent 拖进
// throttle 死循环，powerd 反复 Sleep revert，最终整机冻结（现场 2700 行 / 90 秒）。
//
// 这里只钉死一件事：鼠标没动（或几乎没动）时，一次推送都不许发生。
@main
struct PetGazeGateTests {
    static func main() {
        // 1. 第一帧必须推（页面要知道初始姿态）
        var gate = PetGazeGate()
        precondition(gate.shouldEmit(PetGazeSample(dx: 0.1, dy: 0.2, near: 0.3)), "first sample must emit")

        // 2. 同一姿态重复 900 次（= 30 秒空闲），一次都不许再推
        var emitted = 0
        for _ in 0..<900 {
            if gate.shouldEmit(PetGazeSample(dx: 0.1, dy: 0.2, near: 0.3)) { emitted += 1 }
        }
        precondition(emitted == 0, "same sample repeated 900x emitted \(emitted) times, expected 0")

        // 3. 亚 epsilon 抖动（手静止时的浮点噪声）不推
        precondition(!gate.shouldEmit(PetGazeSample(dx: 0.101, dy: 0.199, near: 0.301)),
                     "sub-epsilon jitter must be suppressed")

        // 4. 真的移动了要推
        precondition(gate.shouldEmit(PetGazeSample(dx: 0.5, dy: 0.2, near: 0.3)), "real move must emit")

        // 5. 从暂停恢复（息屏 / 遮挡结束）后 reset，同一姿态也要补一帧
        gate.reset()
        precondition(gate.shouldEmit(PetGazeSample(dx: 0.5, dy: 0.2, near: 0.3)), "reset must force one frame")

        // 6. 超范围输入夹紧到 [-1,1] / [0,1]：夹紧后与上一帧等价 → 不推
        var clampGate = PetGazeGate()
        precondition(clampGate.shouldEmit(PetGazeSample(dx: 2, dy: -3, near: 9)), "first clamped sample emits")
        precondition(!clampGate.shouldEmit(PetGazeSample(dx: 5, dy: -9, near: 42)),
                     "clamped-to-same-value sample must be suppressed")

        // 7. 夹紧之外的真差异照样推
        precondition(clampGate.shouldEmit(PetGazeSample(dx: 0, dy: 0, near: 0)),
                     "different clamped value must emit")

        print("Pet gaze gate: idle suppression, epsilon, reset and clamping passed")
    }
}
