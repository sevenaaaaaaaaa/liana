import AVFoundation
import Speech
import QuartzCore

/// Audio capture belongs to the containing app. The extension never records.
///
/// Recognition always runs on the device: `requiresOnDeviceRecognition` stays
/// true, so Liana never falls back to Apple's server recognizer. When a
/// language pack is missing the session reports an explicit `Issue` so the
/// host page can show the install path instead of failing silently.
final class LocalVoiceSession {
    enum State { case idle, requesting, recording, finishing }

    enum Issue: Equatable {
        case speechPermissionDenied
        case microphonePermissionDenied
        case recognizerUnavailable(VoiceLanguage)
        case onDeviceModelMissing(VoiceLanguage)
        case failed(String)
    }

    var onText: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onState: ((State) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Fired once per recording when the final transcript arrived or the
    /// finishing fallback expired; the host uses it to flush the last
    /// translation.
    var onComplete: (() -> Void)?
    var onIssue: ((Issue) -> Void)?

    /// Recognition language selected on the voice page. Changing it only takes
    /// effect for the next recording.
    var language: VoiceLanguage = VoiceLanguageSettings.recognition()

    private(set) var state: State = .idle
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var installedTap = false
    private var generation = 0
    private func transition(_ state: State) { self.state = state; onState?(state) }
    func start() {
        stop(); generation += 1; let token = generation; transition(.requesting)
        SFSpeechRecognizer.requestAuthorization { [weak self] permission in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                guard permission == .authorized else {
                    self.transition(.idle); self.onIssue?(.speechPermissionDenied)
                    self.onStatus?("请在系统设置中允许语音识别。"); return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self, token == self.generation else { return }
                        guard allowed else {
                            self.transition(.idle); self.onIssue?(.microphonePermissionDenied)
                            self.onStatus?("请在系统设置中允许麦克风。"); return
                        }
                        self.record()
                    }
                }
            }
        }
    }
    private func record() {
        let language = self.language
        guard let recognizer = SFSpeechRecognizer(locale: language.locale) else {
            transition(.idle); onIssue?(.recognizerUnavailable(language))
            onStatus?("系统不支持\(language.chineseName)语音识别。")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            transition(.idle); onIssue?(.onDeviceModelMissing(language))
            onStatus?("本机还没有\(language.chineseName)离线语音包，请到设置 → 通用 → 键盘 → 听写语言下载。松萝不会改用云端识别。")
            return
        }
        do {
            let session=AVAudioSession.sharedInstance(); try session.setCategory(.record,mode:.measurement,options:[.duckOthers]); try session.setActive(true)
            let request=SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition=true; request.shouldReportPartialResults=true; request.taskHint = .dictation; self.request=request
            if #available(iOS 16.0, *) { request.addsPunctuation = true }
            let input=engine.inputNode; let format=input.outputFormat(forBus:0)
            guard format.sampleRate > 0 else { throw MobileImportError.message("麦克风尚未就绪，请稍后重试。") }
            var lastMeter: CFTimeInterval=0
            input.installTap(onBus:0,bufferSize:1024,format:format) { [weak request, weak self] buffer,_ in
                request?.append(buffer)
                let now=CACurrentMediaTime()
                guard now-lastMeter > 0.08,let samples=buffer.floatChannelData?[0] else { return }; lastMeter=now
                let count=Int(buffer.frameLength); let strideSize=max(1,count/128); var power:Float=0; var measured=0
                for i in stride(from:0,to:count,by:strideSize) { power += samples[i]*samples[i]; measured += 1 }
                let level=min(1,sqrt(power/Float(max(1,measured)))*7)
                DispatchQueue.main.async { [weak self] in if self?.state == .recording { self?.onLevel?(level) } }
            }; installedTap=true
            let token=generation
            task=recognizer.recognitionTask(with:request) { [weak self] result,error in
                DispatchQueue.main.async {
                    guard let self,self.generation==token else { return }
                    if let result { self.onText?(result.bestTranscription.formattedString) }
                    if result?.isFinal==true { self.stop(); self.onStatus?("识别完成。可以编辑，再复制到输入框。"); self.onComplete?() }
                    else if let error { self.stop(); self.onIssue?(.failed(error.localizedDescription)); self.onStatus?(error.localizedDescription) }
                }
            }
            engine.prepare(); try engine.start(); transition(.recording); onStatus?("正在本机识别\(language.chineseName)。说完后点停止。")
        } catch { stop(); onIssue?(.failed(error.localizedDescription)); onStatus?(error.localizedDescription) }
    }
    /// Let the recognizer consume the last audio buffer before enabling Copy.
    func finish() {
        guard state == .recording else { return }
        stopCapture(); transition(.finishing); request?.endAudio(); task?.finish(); onStatus?("正在整理最后一句…")
        let token=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
            guard let self,self.generation==token,self.state == .finishing else { return }
            self.stop(); self.onStatus?("录音已结束。可以编辑，再复制到输入框。"); self.onComplete?()
        }
    }
    private func stopCapture() {
        engine.stop(); if installedTap { engine.inputNode.removeTap(onBus:0); installedTap=false }
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
    func stop() {
        generation += 1; stopCapture(); request?.endAudio(); task?.cancel(); task=nil; request=nil
        if state != .idle { transition(.idle) }
    }
    deinit { stop() }
}
