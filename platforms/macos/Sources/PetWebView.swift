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
    /// 页面事件（台词 / 特效 / 溜达）是否转给桌面上的桌宠；形象工坊预览关掉。
    var routesToPet = true

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
    /// 通用触发器（milestone / break …），纸偶渲染器支持；其他渲染器没有该函数时静默忽略。
    func trigger(_ name: String) { eval("window.petTrigger && window.petTrigger('\(Self.jsSafe(name))')") }
    /// 说话口型（纸偶渲染器）：嘴巴开合若干秒。
    func speak(seconds: Double) { eval("window.petSpeak && window.petSpeak(\(seconds))") }
    /// 直接播放某个动作（形象工坊「试试动作」）。
    func play(_ actionId: String) { eval("window.petPlay && window.petPlay('\(Self.jsSafe(actionId))')") }

    /// 播放一个临时动作（动作编辑器预览）。参数是 JSON 对象，本身就是合法的 JS 字面量。
    func playInline(_ action: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: action),
              var json = String(data: data, encoding: .utf8) else { return }
        // JSON 合法但 JS 字符串里不允许的两个行分隔符
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        eval("window.petPlayInline && window.petPlayInline(\(json))")
    }

    /// 动作 id / 触发器名只允许字母数字下划线连字符，杜绝拼进 JS 的注入。
    private static func jsSafe(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
    }

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
        guard routesToPet else { return }
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
        if body["sparks"] as? Bool == true {
            DispatchQueue.main.async {
                PetWindowController.shared.celebrate(hearts: false)
            }
        }
        if let emote = body["emote"] as? String {
            DispatchQueue.main.async {
                PetWindowController.shared.showEmote(emote)
            }
        }
        if let widths = body["walk"] as? Double {
            let duration = body["duration"] as? Double ?? 2
            DispatchQueue.main.async {
                PetWindowController.shared.walk(byWidths: widths, duration: duration)
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
