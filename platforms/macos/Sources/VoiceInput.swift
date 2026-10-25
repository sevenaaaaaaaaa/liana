import AVFoundation
import Speech

/// 语音输入：macOS 端上语音识别，绝不回退云端。
///
/// macOS 26+ 走新 SpeechAnalyzer / SpeechTranscriber（识别质量与中英混说
/// 显著更好，自带标点）；旧系统回落 SFSpeechRecognizer（强制端上识别）。
/// 新引擎路径任何一步失败都自动回落旧识别，功能不缺席。
///
/// 权限：首次使用时系统弹窗请求「麦克风 + 语音识别」，均为用户显式操作触发。
/// 音频只在内存中流转到系统端上识别器，不落盘、不联网。识别语言资产
/// （首次可能需要系统下载）由系统资产管理，下载完成后即可永久离线。
final class VoiceInputController {
    static let shared = VoiceInputController()

    private let engine = AVAudioEngine()
    // 旧路径（SFSpeechRecognizer）
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    // 新路径（macOS 26+）：AnalyzerVoiceSession 以 AnyObject 持有——
    // 存储属性类型不能窄于类型的部署目标，只能在 #available 块内取用
    private var analyzerSession: AnyObject?
    private var usingAnalyzer = false

    private var tapInstalled = false

    private(set) var isListening = false
    /// 手动 stop（Esc/上屏）不算错误，抑制随之而来的 cancel toast。
    private var cancelled = false

    /// 实时文本（partial）与最终文本。
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// 状态/错误提示（用于气泡）。
    var onStatus: ((String) -> Void)?

    private init() {}

    /// 端上识别可用性 + 授权状态（不触发弹窗）。
    static func availability(locale: String = "zh-CN") -> (onDevice: Bool, authorized: SFSpeechRecognizerAuthorizationStatus) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        return (recognizer?.supportsOnDeviceRecognition ?? false, SFSpeechRecognizer.authorizationStatus())
    }

    /// 开始听写：先请求权限，再启动端上识别。
    func start(locale: String = "zh-CN") {
        guard !isListening else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self?.onStatus?("语音识别未授权（系统设置 → 隐私与安全性 → 语音识别）")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else {
                    DispatchQueue.main.async { self?.onStatus?("麦克风未授权（系统设置 → 隐私与安全性 → 麦克风）") }
                    return
                }
                DispatchQueue.main.async { self?.begin(locale: locale) }
            }
        }
    }

    func stop() {
        cancelled = true
        guard isListening || request != nil || tapInstalled || analyzerSession != nil else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if usingAnalyzer {
            // 流式收尾：已识别文本作为最终结果交回（标点确认流程接手）
            var text = ""
            if #available(macOS 26.0, *) {
                let session = analyzerSession as? AnalyzerVoiceSession
                text = session?.rollingText ?? ""
                session?.teardown()
            }
            analyzerSession = nil
            isListening = false
            if !text.isEmpty {
                onFinal?(text)
            }
            return
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }

    private func begin(locale: String) {
        cancelled = false
        if #available(macOS 26.0, *) {
            beginAnalyzer(locale: locale)
        } else {
            beginLegacy(locale: locale)
        }
    }

    // MARK: - 新引擎（macOS 26+ SpeechAnalyzer）

    @available(macOS 26.0, *)
    private func beginAnalyzer(locale id: String) {
        usingAnalyzer = true
        Task {
            do {
                guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                    // 该语言不在新引擎支持列表 → 回落旧识别
                    await MainActor.run { self.fallbackToLegacy(locale: id) }
                    return
                }
                let transcriber = SpeechTranscriber(
                    locale: loc,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: []
                )
                let modules: [any SpeechModule] = [transcriber]
                let status = await AssetInventory.status(forModules: modules)
                if status != .installed,
                   let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    await MainActor.run {
                        self.onStatus?("正在准备语音识别资产（仅首次，完成后即可离线）…")
                    }
                    try await request.downloadAndInstall()
                }
                let session = AnalyzerVoiceSession()
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                session.continuation = continuation
                let analyzer = SpeechAnalyzer(modules: modules)
                session.analyzer = analyzer
                session.transcriber = transcriber
                self.analyzerSession = session

                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    // tap 生命周期覆盖会话期（stop 时先移除 tap 再 finish 流）
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
                tapInstalled = true
                engine.prepare()
                try engine.start()

                try await analyzer.start(inputSequence: stream)
                isListening = true
                onStatus?("聆听中…（Esc 取消）")

                session.resultsTask = Task { [weak self, weak session] in
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            guard !text.isEmpty else { continue }
                            await MainActor.run {
                                guard let self, self.isListening, let session else { return }
                                session.rollingText = text
                                self.onPartial?(text)
                            }
                        }
                    } catch is CancellationError {
                        // 主动停止，不报错
                    } catch {
                        await MainActor.run {
                            guard let self, !self.cancelled else { return }
                            self.onStatus?("语音识别结束/出错")
                            self.stop()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    // 新引擎任何失败（资产/启动/不支持）→ 回落旧识别，功能不缺席
                    self.fallbackToLegacy(locale: id)
                }
            }
        }
    }

    private func fallbackToLegacy(locale: String) {
        guard !cancelled else { return }
        usingAnalyzer = false
        if #available(macOS 26.0, *) {
            (analyzerSession as? AnalyzerVoiceSession)?.teardown()
        }
        analyzerSession = nil
        beginLegacy(locale: locale)
    }

    // MARK: - 旧引擎（SFSpeechRecognizer）

    private func beginLegacy(locale: String) {
        usingAnalyzer = false
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else {
            onStatus?("当前系统语音识别不可用")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // 关键边界：不支持端上就直接拒绝，绝不回退到云端识别
            onStatus?("该语言不支持端上识别，已取消（不会回退云端）")
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true      // 端上执行
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    if result.isFinal {
                        self.onFinal?(text)
                        self.stop()
                    } else {
                        self.onPartial?(text)
                    }
                }
                return
            }
            if error != nil {
                DispatchQueue.main.async {
                    if !self.cancelled {
                        self.onStatus?("语音识别结束/出错")
                    }
                    self.stop()
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isListening = true
            onStatus?("聆听中…（Esc 取消）")
        } catch {
            stop()
            onStatus?("无法启动麦克风：\(error.localizedDescription)")
        }
    }
}

/// 新引擎会话状态：全部 macOS 26+ 类型集中在此，宿主以 AnyObject 持有。
@available(macOS 26.0, *)
private final class AnalyzerVoiceSession {
    var analyzer: SpeechAnalyzer?
    var transcriber: SpeechTranscriber?
    var continuation: AsyncStream<AnalyzerInput>.Continuation?
    var resultsTask: Task<Void, Never>?
    /// 最新一次结果的全量文本（流式更新；停止时作为最终结果交回）。
    var rollingText = ""

    func teardown() {
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        rollingText = ""
    }
}
