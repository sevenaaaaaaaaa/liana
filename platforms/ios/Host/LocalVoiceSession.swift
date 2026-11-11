import AVFoundation
import Speech

/// Recording only lives in the containing app, never in the keyboard extension.
final class LocalVoiceSession {
    var onText: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var installedTap = false
    private var generation = 0
    func start() {
        stop(); generation += 1; let token = generation
        SFSpeechRecognizer.requestAuthorization { [weak self] permission in
            guard permission == .authorized else { DispatchQueue.main.async { self?.onStatus?("请在系统设置中允许语音识别。") }; return }
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    guard allowed else { self.onStatus?("请在系统设置中允许麦克风。"); return }
                    self.record()
                }
            }
        }
    }
    private func record() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { onStatus?("当前设备的离线中文识别不可用，请先在系统设置下载中文语音资源。"); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers]); try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; self.request = request
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw MobileImportError.message("麦克风尚未就绪。") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in request?.append(buffer) }; installedTap = true
            let token = generation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if let result { self.onText?(result.bestTranscription.formattedString) }
                    if result?.isFinal == true { self.stop(); self.onStatus?("识别结束，可编辑后复制回键盘。") }
                    else if let error { self.stop(); self.onStatus?(error.localizedDescription) }
                }
            }
            engine.prepare(); try engine.start(); onStatus?("正在本机识别，请说话。完成后点停止。")
        } catch { stop(); onStatus?(error.localizedDescription) }
    }
    func stop() {
        generation += 1
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    deinit { stop() }
}
