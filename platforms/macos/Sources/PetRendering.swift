import AppKit

/// 桌宠渲染器协议：原生纸偶（NativePuppetView）与 WebKit 渲染器（VRM / Live2D / 旧纸偶）
/// 共用同一套接口，PetWindow 只跟这个协议打交道。
///
/// 原生优先：默认的 .lianapet 纸偶走 NativePuppetView（零 WebKit）；
/// 只有 VRM / Live2D 这类确实需要 3D / Cubism 运行时的形象才落到 WKWebView。
protocol PetRendererView: AnyObject {
    var view: NSView { get }

    var onReady: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onNeedsRuntime: (() -> Void)? { get set }

    func setState(_ state: String)
    func petted()
    func poke()
    func setHover(_ on: Bool)
    func setDragging(_ on: Bool)
    func setSleepy(_ on: Bool)
    func setMood(_ level: Int)
    func greet(_ period: String)
    func setGaze(dx: Double, dy: Double, near: Double)
    func setScene(_ pose: String, completion: @escaping (Bool) -> Void)
    func face(_ dir: Int)
    func trigger(_ name: String, weights: [String: Double])
    func hitRegion(fx: Double, fy: Double, _ completion: @escaping (String) -> Void)
    func setHold(_ name: String)
    func speak(seconds: Double)
    func play(_ actionId: String)
    func playInline(_ action: [String: Any])
    func capturePNG(_ completion: @escaping (Data?) -> Void)
    /// 看不见时暂停渲染（隐藏 / 完全被遮挡 / 息屏锁屏）。
    func setPaused(_ paused: Bool)
}

extension PetRendererView {
    func trigger(_ name: String) { trigger(name, weights: [:]) }
    func setGaze(dx: Double, dy: Double) { setGaze(dx: dx, dy: dy, near: 0) }
    func setScene(_ pose: String) { setScene(pose, completion: { _ in }) }
    /// 原生渲染器没有持续重绘循环，默认不用处理。
    func setPaused(_ paused: Bool) {}
}
