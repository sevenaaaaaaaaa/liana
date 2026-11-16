import UIKit
import WebKit

/// 把卡片 HTML 变成可以分享的文件：优先出 PDF，出不来就退回 HTML 文件。
///
/// 不往工程里塞渲染代码——排版在 Rust 那边，这里只负责「把网页面板印成纸」。
@MainActor
final class CardExporter: NSObject, WKNavigationDelegate {

    static let shared = CardExporter()

    private var webView: WKWebView?
    private var finish: ((URL?) -> Void)?
    private var htmlURL: URL?

    /// 生成卡片文件并弹出分享面板。调用方负责给出合适的宿主控制器。
    func export(html: String, from host: UIViewController) {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("liana-card-\(UUID().uuidString).html")
        guard (try? html.write(to: file, atomically: true, encoding: .utf8)) != nil else {
            share(fallback: nil, htmlFile: nil, from: host)
            return
        }
        htmlURL = file
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 1200))
        view.navigationDelegate = self
        webView = view
        finish = { [weak self] pdf in
            guard let self else { return }
            self.share(fallback: pdf, htmlFile: file, from: host)
        }
        view.loadFileURL(file, allowingReadAccessTo: directory)
    }

    private func share(fallback pdf: URL?, htmlFile: URL?, from host: UIViewController) {
        let item: URL? = pdf ?? htmlFile
        guard let item else { return }
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
        }
        host.present(activity, animated: true)
        webView = nil
        finish = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKPDFConfiguration()
        webView.createPDF(configuration: configuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, let finish = self.finish else { return }
                switch result {
                case .success(let data):
                    let name = "松萝卡片-\(Self.fileStamp()).pdf"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    if (try? data.write(to: url)) != nil {
                        finish(url)
                    } else {
                        finish(nil)
                    }
                case .failure:
                    finish(nil)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish?(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish?(nil)
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
