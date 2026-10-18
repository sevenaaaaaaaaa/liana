import AppKit
import WebKit

/// 弱引用转发：避免 WKUserContentController 强持有 handler 造成 retain cycle
/// （否则旧的 WKWebView 永不释放，切换形象时上一个形象可能残留）。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// 桌宠 WebKit 渲染基类：透明 WKWebView + JS 桥（`window.pet*`）。
/// VRM（`pet.js`）与 Live2D（`pet-live2d.js`）共用同一套桥，子类只负责装配页面与读取根目录。
class PetWebView: WKWebView, WKScriptMessageHandler, WKNavigationDelegate {
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    /// 运行时/依赖缺失（Live2D 的 Cubism Core、vendor 未就绪）——用于显示引导。
    var onNeedsRuntime: (() -> Void)?

    private var pendingState = "idle"

    init(frame: NSRect, pageURL: URL, readRoot: URL) {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // file:// 下允许加载本地资源（three.js/three-vrm 或 pixi/Live2D 必需）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        config.userContentController = controller
        super.init(frame: frame, configuration: config)
        controller.add(WeakScriptMessageHandler(target: self), name: "pet")

        setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            underPageBackgroundColor = .clear
        }
        navigationDelegate = self
        setValue(false, forKey: "allowsMagnification")
        loadFileURL(pageURL, allowingReadAccessTo: readRoot)
    }

    required init?(coder: NSCoder) { nil }

    /// 鼠标事件穿透给父视图（桌宠的点击/拖动/悬停都靠父视图处理）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - 看板娘式互动（全部转发到页面内状态机）

    func setState(_ state: String) {
        pendingState = state
        eval("window.petSetState && window.petSetState('\(state)')")
    }

    func petted() { eval("window.petPetted && window.petPetted()") }
    func poke() { eval("window.petPoke && window.petPoke()") }
    func setHover(_ on: Bool) { eval("window.petHover && window.petHover(\(on))") }
    func setDragging(_ on: Bool) { eval("window.petSetDrag && window.petSetDrag(\(on))") }
    func setSleepy(_ on: Bool) { eval("window.petSetSleepy && window.petSetSleepy(\(on))") }
    func setMood(_ level: Int) { eval("window.petSetMood && window.petSetMood(\(level))") }
    func greet(_ period: String) { eval("window.petGreet && window.petGreet('\(period)')") }
    func setGaze(dx: Double, dy: Double) { eval("window.petSetGaze && window.petSetGaze(\(dx), \(dy))") }

    private func eval(_ js: String) {
        evaluateJavaScript(js) { _, _ in }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["ready"] as? Bool == true {
            setState(pendingState)
            onReady?()
        }
        if let error = body["error"] as? String {
            onError?(error)
        }
        if body["needsRuntime"] as? Bool == true {
            onNeedsRuntime?()
        }
        if let line = body["say"] as? String {
            DispatchQueue.main.async {
                PetWindowController.shared.pageSays(line)
            }
        }
        if body["hearts"] as? Bool == true {
            DispatchQueue.main.async {
                PetWindowController.shared.celebrate()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setState(pendingState)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?("导航失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onError?("页面加载失败: \(error.localizedDescription)")
    }

    /// 抓取当前 WebGL 画面（canvas.toDataURL），返回 PNG 数据。
    func capturePNG(_ completion: @escaping (Data?) -> Void) {
        evaluateJavaScript("window.petCapture && window.petCapture()") { value, _ in
            guard
                let string = value as? String,
                let comma = string.firstIndex(of: ","),
                let data = Data(base64Encoded: String(string[string.index(after: comma)...]))
            else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    /// 开发用：取回页面内状态（是否 ready / 报错信息 / 绘制统计）。
    func debugState(_ completion: @escaping (String) -> Void) {
        evaluateJavaScript("JSON.stringify({ready: !!window.__petReady, err: window.__petErr || '', info: (window.petInfo ? JSON.parse(window.petInfo()) : null)})") { value, error in
            if let error {
                completion("evaluate-error: \(error.localizedDescription)")
            } else {
                completion(String(describing: value ?? "nil"))
            }
        }
    }
}
