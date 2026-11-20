import Foundation
import UIKit
import WatchConnectivity

/// iPhone 端：接收手表发来的文字，直接放进剪贴板，并在前台时给一条提示。
/// 只接受「文本」这一种载荷，别的字段一律忽略。
final class WatchReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchReceiver()
    /// 与手表端约定的载荷键。两端各写一份，避免把 watchOS 代码拖进 iOS target。
    private static let textKey = "text"

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let text = userInfo[Self.textKey] as? String, !text.isEmpty else { return }
        DispatchQueue.main.async {
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
