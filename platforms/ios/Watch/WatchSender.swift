import Foundation
import WatchConnectivity

/// 手表端的发送通道。
///
/// 语音识别在 watchOS 上没有 Speech 框架可用（SDK 里只有 AVFoundation），
/// 所以手表端不做识别：用系统的听写（键盘上的麦克风）把话变成文字，
/// 这里只负责把它递给 iPhone。
@MainActor
final class WatchSender: NSObject, ObservableObject {
    enum Phase { case idle, sending, sent }

    @Published private(set) var phase: Phase = .idle
    @Published var note = "点输入框，用键盘上的麦克风说一句。"

    private static let textKey = "text"
    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session, session.activationState == .activated else {
            note = "iPhone 暂时不可达，稍后再试。"
            return
        }
        phase = .sending
        session.transferUserInfo([Self.textKey: trimmed])
        phase = .sent
        note = "已发到 iPhone，在任意输入框粘贴即可。"
    }

    func reset() { phase = .idle }
}

extension WatchSender: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}
