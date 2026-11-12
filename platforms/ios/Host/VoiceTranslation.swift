import Foundation
import UIKit
import SwiftUI
import Translation
import Combine

/// Result of one debounced partial translation.
struct VoiceTranslationResult: Equatable {
    let sourceText: String
    let translatedText: String
    let source: VoiceLanguage
    let target: VoiceLanguage
}

/// On-device state of the requested language pair.
enum VoiceTranslationAvailability: Equatable {
    case checking
    case ready
    case needsDownload
    case unsupported
    case requiresNewerOS
    case failed(String)
}

/// Drives Apple's local Translation framework for simultaneous interpretation.
///
/// The framework is iOS 18+, so the controller exposes a clear
/// `requiresNewerOS` state instead of silently falling back to a network
/// service. Every callback is delivered on the main queue.
@MainActor
final class VoiceTranslationController {
    static let minimumSystemDescription = "同声传译需要 iOS 18 或更新版本（Apple 本地翻译框架）。"

    static var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Text translated, delivered on the main queue while recording.
    var onResult: ((VoiceTranslationResult) -> Void)?
    /// Availability of the currently requested pair.
    var onAvailability: ((VoiceTranslationAvailability) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Called once per language pair before the system download prompt appears.
    var onPreparing: (() -> Void)?

    private struct Pair: Equatable {
        let source: VoiceLanguage
        let target: VoiceLanguage
    }

    private var bridge: AnyObject?
    private var hosting: UIViewController?
    private var checkedPair: Pair?

    /// Hidden SwiftUI host that owns the TranslationSession. The caller adds it
    /// as a child so `.translationTask` stays alive while the page is visible.
    var hostingViewController: UIViewController? {
        guard #available(iOS 18.0, *) else { return nil }
        ensureBridge()
        return hosting
    }

    func checkAvailability(source: VoiceLanguage, target: VoiceLanguage) {
        guard #available(iOS 18.0, *) else {
            onAvailability?(.requiresNewerOS)
            return
        }
        let pair = Pair(source: source, target: target)
        checkedPair = pair
        onAvailability?(.checking)
        Task { [weak self] in
            let status = await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage)
            let availability: VoiceTranslationAvailability
            switch status {
            case .installed: availability = .ready
            case .supported: availability = .needsDownload
            case .unsupported: availability = .unsupported
            @unknown default: availability = .unsupported
            }
            await MainActor.run {
                guard let self, self.checkedPair == pair else { return }
                self.onAvailability?(availability)
            }
        }
    }

    func translate(_ text: String, source: VoiceLanguage, target: VoiceLanguage) {
        let normalized = VoiceTranscriptComposer.normalized(text)
        guard !normalized.isEmpty else { return }
        guard #available(iOS 18.0, *) else {
            onFailure?(Self.minimumSystemDescription)
            return
        }
        ensureBridge()
        guard let bridge = bridge as? AppleTranslationBridge else {
            onFailure?("本机翻译组件暂时不可用，请稍后重试。")
            return
        }
        bridge.enqueue(normalized, source: source, target: target)
    }

    /// Starts the system language-pack download before the first phrase when
    /// possible, so recording is not interrupted by a download prompt.
    func prepare(source: VoiceLanguage, target: VoiceLanguage) {
        guard #available(iOS 18.0, *) else { return }
        ensureBridge()
        (bridge as? AppleTranslationBridge)?.enqueue(nil, source: source, target: target)
    }

    func cancel() {
        guard #available(iOS 18.0, *) else { return }
        (bridge as? AppleTranslationBridge)?.cancel()
    }

    private func ensureBridge() {
        guard #available(iOS 18.0, *) else { return }
        if bridge == nil {
            let translationBridge = AppleTranslationBridge()
            translationBridge.onResult = { [weak self] result in self?.onResult?(result) }
            translationBridge.onFailure = { [weak self] message in self?.onFailure?(message) }
            translationBridge.onPreparing = { [weak self] in self?.onPreparing?() }
            self.bridge = translationBridge
            self.hosting = UIHostingController(rootView: AppleTranslationHostView(bridge: translationBridge))
        }
    }
}

@available(iOS 18.0, *)
extension VoiceLanguage {
    /// Translation.framework prefers BCP-47 language tags; zh-CN maps to
    /// zh-Hans because Apple lists Mandarin by script.
    var localeLanguage: Locale.Language {
        Locale(identifier: translationIdentifier).language
    }
}

/// Retains the only surface that can produce a `TranslationSession`.
@available(iOS 18.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    struct Job: Equatable {
        let id: UUID
        /// `nil` means prepare the language pack only.
        let text: String?
        let source: VoiceLanguage
        let target: VoiceLanguage
    }

    @Published private(set) var configuration: TranslationSession.Configuration?

    var onResult: ((VoiceTranslationResult) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPreparing: (() -> Void)?

    private var queue: [Job] = []
    private var running = false
    private var prepared: Set<String> = []

    /// Keeps at most the in-flight job plus the newest partial. Translating
    /// every queued partial would lag behind speech by seconds.
    func enqueue(_ text: String?, source: VoiceLanguage, target: VoiceLanguage) {
        let job = Job(id: UUID(), text: text, source: source, target: target)
        if running {
            if queue.count > 1 { queue.removeSubrange(1..<queue.count) }
        } else {
            queue.removeAll()
        }
        queue.append(job)
        startIfNeeded()
    }

    func cancel() {
        queue.removeAll()
        running = false
        configuration = nil
        prepared.removeAll()
    }

    private func startIfNeeded() {
        guard !running, let job = queue.first else { return }
        running = true
        var newConfiguration = TranslationSession.Configuration(
            source: job.source.localeLanguage,
            target: job.target.localeLanguage
        )
        newConfiguration.invalidate()
        configuration = newConfiguration
    }

    private func matches(_ job: Job, session: TranslationSession) -> Bool {
        if let source = session.sourceLanguage, source != job.source.localeLanguage { return false }
        if let target = session.targetLanguage, target != job.target.localeLanguage { return false }
        return true
    }

    /// Runs inside `.translationTask`; the session is only valid here, so the
    /// queued jobs are translated in this scope.
    func run(session: TranslationSession) async {
        while let job = queue.first, matches(job, session: session) {
            let key = job.source.identifier + ">" + job.target.identifier
            if !prepared.contains(key) {
                onPreparing?()
                do {
                    try await session.prepareTranslation()
                    prepared.insert(key)
                } catch {
                    queue.removeFirst()
                    onFailure?("无法准备\(job.source.nativeName)→\(job.target.nativeName)的本地语言包：\(error.localizedDescription)")
                    continue
                }
            }
            guard let text = job.text else {
                queue.removeFirst()
                continue
            }
            do {
                let response = try await session.translate(text)
                queue.removeFirst()
                onResult?(VoiceTranslationResult(
                    sourceText: text,
                    translatedText: response.targetText,
                    source: job.source,
                    target: job.target
                ))
            } catch {
                queue.removeFirst()
                onFailure?("本机翻译暂时不可用：\(error.localizedDescription)")
            }
        }
        running = false
        if !queue.isEmpty { startIfNeeded() }
    }
}

@available(iOS 18.0, *)
struct AppleTranslationHostView: View {
    @ObservedObject var bridge: AppleTranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session: session)
            }
    }
}
