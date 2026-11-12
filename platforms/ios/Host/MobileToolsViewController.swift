import UIKit
import UniformTypeIdentifiers
import ImageIO
import Speech

final class MobileToolsViewController:UIViewController,UIDocumentPickerDelegate,UITextViewDelegate {
    private enum Section:Int { case voice,dictionary,media,sync }
    private let tabs=LianaUI.segment(["语音","词库","表情","同步"])
    private let content=LianaUI.vertical(spacing:16)
    private weak var scroll: UIScrollView?
    private let status=LianaUI.label("",size:13,muted:true)
    private let editor=LianaEditorView()
    private let placeholder=LianaUI.label("说点什么，或在这里编辑文字…",size:16,muted:true)
    private let format=LianaUI.segment(["拼音词库","五笔 86"])
    private let meter=VoiceMeterView()
    private let voice=LocalVoiceSession()
    private let translation=VoiceTranslationController()
    private let languageButton=LianaPressButton(frame:.zero)
    private let targetButton=LianaPressButton(frame:.zero)
    private let translateSwitch=UISwitch()
    private let editorCaption=LianaUI.label("",size:12,weight:.medium,muted:true)
    private let translationCaption=LianaUI.label("",size:12,weight:.medium,muted:true)
    private let translationText=LianaUI.label("",size:16)
    private let translationHint=LianaUI.label("",size:12,muted:true)
    private let voiceHint=LianaUI.label("",size:12,muted:true)
    private lazy var settingsButton=LianaUI.button("打开设置",icon:"gearshape",role:.utility,id:"voice.settings") { [weak self] in self?.openSettings() }
    private var recognitionLanguage=VoiceLanguageSettings.recognition()
    private var translationTarget=VoiceLanguageSettings.translationTarget(source:VoiceLanguageSettings.recognition())
    private var translateOn=VoiceLanguageSettings.translationEnabled() && VoiceTranslationController.isSupported
    private var translationEpoch=0
    private var translationThrottle=VoiceTranslationThrottle()
    private var translationWork:DispatchWorkItem?
    private var latestTranslation:String?
    private var latestTranslationSource:String?
    private var translationStatus:String?
    private var lastRecognizedText=""
    private var translationHost:UIViewController?
    private var importingGIF=false
    private var fetcher:BoundedDictionaryDownload?
    private var words:[MobileWord]=[]
    private var importGeneration=0
    private var importingDictionary=false
    private var phrases:[String]=MobilePhraseBookSettings.load()
    private var phraseSaveWork:DispatchWorkItem?
    private let phrasesEditor=LianaEditorView()
    private let phraseCount=LianaUI.label("",size:12,muted:true)
    private let phraseHint=LianaUI.label("每行一条，最多 20 条、每条 50 字；空行和重复行会自动合并。复制后在键盘工具 → 词库接收，九键长按数字键下滑也能用。",size:13,muted:true)
    private lazy var phrasesCopy=LianaUI.button("复制常用短语到键盘",icon:"tray.and.arrow.up",role:.primary,id:"dict.phrases.copy") { [weak self] in self?.copyPhrases() }
    private var voicePrefix=""
    private var lastClearedDraft:String?
    private var draftWrite:DispatchWorkItem?
    static let draftKey="mobile.voice.draft"
    private var section:Section = .voice
    private var statuses:[Section:String]=[:]
    private lazy var recordButton=LianaUI.button("开始录音",icon:"mic.fill",role:.primary,id:"voice.start") { [weak self] in
        guard let self else { return }; self.editor.resignFirstResponder()
        if self.voice.state == .recording { self.voice.finish(); self.flushTranslation() }
        else { self.voicePrefix=self.editor.text; self.lastClearedDraft=nil; self.beginVoiceSession(); self.voice.start() }
    }
    private lazy var voiceCopy=LianaUI.button("复制文字",icon:"doc.on.doc",role:.utility,id:"voice.copy") { [weak self] in
        guard let self else { return }; self.copy(KeyboardPayload(kind:"text",text:self.copyText),in:.voice)
    }
    private lazy var clearDraft=LianaUI.button("清空",role:.plain,id:"voice.clear") { [weak self] in
        guard let self,self.voice.state == .idle else { return }
        self.editor.resignFirstResponder(); self.lastClearedDraft=self.editor.text; self.editor.text=""; self.clearTranslation(); self.saveDraft(); self.updateVoiceControls()
        self.setStatus("草稿已清空，可以撤销。",in:.voice)
    }
    private lazy var undoClear=LianaUI.button("撤销清空",icon:"arrow.uturn.backward",role:.plain,id:"voice.undo") { [weak self] in
        guard let self,let draft=self.lastClearedDraft else { return }
        self.editor.text=draft; self.lastClearedDraft=nil; self.saveDraft(); self.updateVoiceControls(); self.setStatus("草稿已恢复。",in:.voice)
    }
    private lazy var dictionaryCopy=LianaUI.button("复制词库到键盘",icon:"tray.and.arrow.up",role:.primary,id:"dict.copy") { [weak self] in
        guard let self,!self.words.isEmpty else { return }; self.copy(KeyboardPayload(kind:"words",words:self.words),in:.dictionary)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); title="输入工具"; LianaUI.navigation(self)
        navigationItem.rightBarButtonItem=LianaUI.closeItem(id:"mobile.done") { [weak self] in self?.done() }
        navigationItem.rightBarButtonItem?.accessibilityIdentifier="mobile.done"
        tabs.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(tabs)
        let width=tabs.widthAnchor.constraint(equalTo:view.safeAreaLayoutGuide.widthAnchor,constant:-40); width.priority = .defaultHigh
        NSLayoutConstraint.activate([tabs.centerXAnchor.constraint(equalTo:view.safeAreaLayoutGuide.centerXAnchor),tabs.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),tabs.widthAnchor.constraint(lessThanOrEqualToConstant:620),width])
        let stack=LianaUI.scrollStack(in:self,below:tabs,spacing:20); scroll=stack.superview as? UIScrollView
        tabs.selectedSegmentIndex=0; tabs.accessibilityIdentifier="mobile.section"; tabs.accessibilityLabel="输入工具分类"
        tabs.addAction(UIAction { [weak self] _ in self?.changeSection() },for:.valueChanged)
        stack.addArrangedSubview(content)
        status.accessibilityIdentifier="mobile.status"; stack.addArrangedSubview(LianaUI.card([status]))
        editor.delegate=self; editor.font=LianaPalette.font(17); editor.adjustsFontForContentSizeCategory=true; editor.backgroundColor=LianaPalette.soft; editor.textColor=LianaPalette.ink; editor.tintColor=LianaPalette.ink
        editor.layer.cornerRadius=12; editor.textContainerInset=UIEdgeInsets(top:14,left:10,bottom:14,right:10); editor.minimumHeight=166; editor.visibleLines=5
        editor.text=UserDefaults.standard.string(forKey:Self.draftKey) ?? ""
        editor.accessibilityIdentifier="voice.text"; editor.accessibilityLabel="语音文字，可编辑"
        placeholder.isUserInteractionEnabled=false; placeholder.translatesAutoresizingMaskIntoConstraints=false; editor.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo:editor.leadingAnchor,constant:14),placeholder.trailingAnchor.constraint(lessThanOrEqualTo:editor.trailingAnchor,constant:-14),placeholder.topAnchor.constraint(equalTo:editor.topAnchor,constant:14)])
        clearDraft.contentEdgeInsets=UIEdgeInsets(top:8,left:8,bottom:8,right:8); clearDraft.titleLabel?.font=LianaPalette.font(13,maximum:19)
        clearDraft.widthAnchor.constraint(equalToConstant:64).isActive=true
        format.selectedSegmentIndex=0; format.accessibilityIdentifier="dict.format"; format.accessibilityLabel="词库类型"
        phrasesEditor.delegate=self; phrasesEditor.font=LianaPalette.font(15); phrasesEditor.adjustsFontForContentSizeCategory=true
        phrasesEditor.backgroundColor=LianaPalette.soft; phrasesEditor.textColor=LianaPalette.ink; phrasesEditor.tintColor=LianaPalette.ink
        phrasesEditor.layer.cornerRadius=12; phrasesEditor.textContainerInset=UIEdgeInsets(top:12,left:8,bottom:12,right:8); phrasesEditor.minimumHeight=132; phrasesEditor.visibleLines=4
        phrasesEditor.text=MobilePhraseBook.text(from:phrases)
        phrasesEditor.accessibilityIdentifier="dict.phrases.editor"; phrasesEditor.accessibilityLabel="常用短语，每行一条"
        phraseCount.accessibilityIdentifier="dict.phrases.count"
        updatePhraseControls()
        voice.onText={ [weak self] text in
            guard let self else { return }
            self.lastRecognizedText=text
            self.editor.text=self.voicePrefix + (self.voicePrefix.isEmpty || self.voicePrefix.hasSuffix("\n") ? "" : "\n") + text
            self.updateVoiceControls(); self.scheduleDraftSave(); self.scheduleTranslation(for:text)
        }
        voice.onStatus={ [weak self] in self?.setStatus($0,in:.voice); self?.updateVoiceControls() }
        voice.onState={ [weak self] _ in self?.updateVoiceControls() }
        voice.onLevel={ [weak self] in self?.meter.setLevel($0) }
        voice.onComplete={ [weak self] in self?.flushTranslation() }
        voice.onIssue={ [weak self] issue in self?.handleVoiceIssue(issue) }
        voice.language=recognitionLanguage
        configureVoiceControls()
        configureTranslationCallbacks()
        if translateOn { attachTranslationHost(); checkTranslationAvailability() }
        NotificationCenter.default.addObserver(self,selector:#selector(stopVoice),name:UIApplication.didEnterBackgroundNotification,object:nil)
        render(); updateVoiceControls()
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated); if isViewLoaded && section == .sync { render() } }
    deinit { NotificationCenter.default.removeObserver(self); draftWrite?.cancel(); phraseSaveWork?.cancel(); fetcher?.cancel(); translationWork?.cancel(); voice.stop() }
    @objc private func stopVoice() { voice.stop(); endTranslationSession(); saveDraft() }
    @objc private func done() { voice.stop(); endTranslationSession(); saveDraft(); savePhrases(); importGeneration += 1; fetcher?.cancel(); dismiss(animated:true) }
    override func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { voice.stop(); endTranslationSession() }
        saveDraft(); savePhrases()
    }
    private func scheduleDraftSave() {
        draftWrite?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.saveDraft() }; draftWrite=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }
    private func saveDraft() {
        draftWrite?.cancel()
        if editor.text.isEmpty { UserDefaults.standard.removeObject(forKey:Self.draftKey) }
        else { UserDefaults.standard.set(editor.text,forKey:Self.draftKey) }
    }
    private func changeSection() {
        editor.resignFirstResponder(); savePhrases()
        if voice.state == .recording { voice.finish() } else if voice.state == .requesting { voice.stop() }
        section=Section(rawValue:tabs.selectedSegmentIndex) ?? .voice; render(); scroll?.setContentOffset(.zero,animated:false); LianaMotion.reveal(content)
    }
    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch section {
        case .voice:
            content.addArrangedSubview(LianaUI.label("把想说的，变成文字。",size:24,weight:.semibold))
            content.addArrangedSubview(LianaUI.card([languageRow(),editorHeaderRow(),meter,undoClear,editor,voiceHint,settingsButton,translationRow(),translationCaption,translationText,translationHint,recordButton,voiceCopy],spacing:12))
            content.addArrangedSubview(LianaUI.label("识别与译文都留在本机。复制后直接粘贴，也可回松萝接收。",size:13,muted:true))
            refreshOnDeviceStatus(); updateTranslationViews(); updateVoiceControls()
        case .dictionary:
            content.addArrangedSubview(LianaUI.label("添加你的常用词。",size:24,weight:.semibold))
            content.addArrangedSubview(LianaUI.card([LianaUI.label("常用短语",size:16,weight:.semibold),phraseHint,phrasesEditor,phraseCount,phrasesCopy],spacing:10))
            content.addArrangedSubview(format)
            content.addArrangedSubview(LianaActionRow(title:"本地文件",subtitle:"TXT、TSV 或 Rime 词库",icon:"folder",id:"dict.local") { [weak self] in self?.choose(gif:false) })
            content.addArrangedSubview(LianaActionRow(title:"GitHub 链接",subtitle:"粘贴具体词库文件的地址",icon:"link",id:"dict.github") { [weak self] in self?.github() })
            dictionaryCopy.isEnabled = !words.isEmpty && !importingDictionary; content.addArrangedSubview(dictionaryCopy)
            content.addArrangedSubview(LianaUI.card([LianaUI.label("文件怎么写？",size:15,weight:.semibold),LianaUI.label("一行一词，或「词语 Tab 拼音 Tab 词频」。每次最多 2 万条，UTF-8 文件不超过 20MB。",size:13,muted:true),LianaUI.label("系统补充词库在键盘 → 工具 → 词库中添加，包括姓名、文本替换等。",size:13,muted:true)]))
        case .media:
            content.addArrangedSubview(LianaUI.label("表情，也要顺手。",size:24,weight:.semibold))
            content.addArrangedSubview(LianaUI.label("点选颜文字，复制后直接粘贴。",size:13,muted:true))
            let faces=["(｡･ω･｡)","(≧▽≦)","(๑•̀ㅂ•́)و✧","(づ｡◕‿‿◕｡)づ"]
            for i in stride(from:0,to:faces.count,by:2) {
                let row=UIStackView(); row.spacing=8; row.distribution = .fillEqually
                for index in i..<i+2 { row.addArrangedSubview(LianaUI.button(faces[index],role:.utility,id:"mobile.face.\(index)") { [weak self] in self?.copy(KeyboardPayload(kind:"text",text:faces[index]),in:.media) }) }; content.addArrangedSubview(row)
            }
            content.addArrangedSubview(LianaActionRow(title:"导入 GIF",subtitle:"从文件选一张，复制后粘贴发送",icon:"photo.on.rectangle",id:"gif.import") { [weak self] in self?.choose(gif:true) })
            content.addArrangedSubview(LianaUI.card([LianaUI.label("也可以收藏到键盘",size:15,weight:.semibold),LianaUI.label("选择 GIF 后，回到松萝工具 → 表情 → 接收。键盘最多收藏 12 个，每个不超过 4MB。",size:13,muted:true)]))
        case .sync:
            content.addArrangedSubview(LianaUI.label("和 Mac，保持默契。",size:24,weight:.semibold))
            let profile=PetLink.load(account:"mac")
            content.addArrangedSubview(LianaUI.card([LianaUI.label(profile?.name ?? "尚未配对 Mac",size:19,weight:.semibold),LianaUI.label(profile == nil ? "扫码一次，之后轻松连接。" : "同一局域网内，可发送文件与同步文字。",size:13,muted:true),LianaUI.button("连接 Mac 桌宠",icon:"laptopcomputer",role:.primary,id:"mobile.mac") { [weak self] in self?.present(UINavigationController(rootViewController:PetLinkViewController()),animated:true) }]))
            let pairing=LianaUI.button("将配对复制给键盘",icon:"link",role:.utility,id:"mobile.pairing") { [weak self] in
                guard let self,let profile=PetLink.load(account:"mac") else { return }; self.copy(KeyboardPayload(kind:"pairing",text:profile.pairingCode),in:.sync)
            }; pairing.isEnabled=profile != nil; content.addArrangedSubview(pairing)
            content.addArrangedSubview(LianaUI.label("键盘工具 → 同步 → 接收配对。Mac 收件箱开启剪贴板许可后，即可按需双向同步文字。",size:13,muted:true))
            content.addArrangedSubview(LianaActionRow(title:"外接语音与编码设备",subtitle:"了解蓝牙 HID 与 BLE 的连接方式",icon:"waveform",id:"mobile.devices") { [weak self] in self?.present(UINavigationController(rootViewController:LianaGuideViewController()),animated:true) })
            content.addArrangedSubview(LianaUI.button("开源代码与许可",role:.plain,id:"mobile.licenses") { UIApplication.shared.open(URL(string:"https://github.com/sevenaaaaaaaaa/liana/tree/main/platforms/ios/Vendor")!) })
        }
        updateStatus()
    }
    private func updateVoiceControls() {
        placeholder.isHidden = !editor.text.isEmpty
        let recording=voice.state == .recording
        recordButton.setTitle(recording ? "停止录音" : (voice.state == .finishing ? "整理中…" : "开始录音"),for:.normal)
        recordButton.setImage(UIImage(systemName:recording ? "stop.fill" : "mic.fill"),for:.normal)
        recordButton.isEnabled=voice.state == .idle || recording
        voiceCopy.isEnabled=voice.state == .idle && !editor.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        editor.isEditable=voice.state == .idle; editor.isSelectable=voice.state == .idle
        clearDraft.isEnabled=voice.state == .idle && !editor.text.isEmpty
        undoClear.isHidden=lastClearedDraft == nil || voice.state != .idle
        languageButton.isEnabled=voice.state == .idle
        meter.setRunning(recording)
        updateTranslationViews()
    }
    func textViewDidChange(_ textView:UITextView) {
        if textView === phrasesEditor { schedulePhraseSave(); updatePhraseControls(); return }
        if voice.state == .idle, translateOn, latestTranslation != nil { clearTranslation() }
        updateVoiceControls(); scheduleDraftSave()
    }
    func textViewDidBeginEditing(_ textView:UITextView) {
        DispatchQueue.main.async { [weak self] in guard let self,let scroll=self.scroll else { return }; self.view.layoutIfNeeded(); scroll.scrollRectToVisible(self.editor.convert(self.editor.bounds,to:scroll).insetBy(dx:0,dy:-16),animated:LianaMotion.enabled) }
    }
    private func setStatus(_ text:String,in target:Section) { statuses[target]=text; if section == target { updateStatus() } }
    private func updateStatus() {
        let defaults:[Section:String]=[.voice:"首次录音会请求麦克风与语音识别权限，录音留在本机。",.dictionary:"选择文件或链接，解析完成后再复制到键盘。",.media:"复制内容在本机保留 10 分钟，可直接粘贴或回键盘接收。",.sync:"连接由你主动发起，不在后台监听剪贴板。"]
        status.text=statuses[section] ?? defaults[section]
    }
    private var copyText:String {
        VoiceTranscriptComposer.compose(original:editor.text,translation:translateOn ? latestTranslation : nil,target:translateOn ? translationTarget : nil)
    }
    private func languageRow() -> UIStackView {
        let row=UIStackView(arrangedSubviews:[LianaUI.label("识别语言",size:13,weight:.medium,muted:true),UIView(),languageButton]); row.alignment = .center; row.spacing = 8
        return row
    }
    private func editorHeaderRow() -> UIStackView {
        let row=UIStackView(arrangedSubviews:[editorCaption,UIView(),clearDraft]); row.alignment = .center; row.spacing = 8
        return row
    }
    private func translationRow() -> UIStackView {
        let row=UIStackView(arrangedSubviews:[LianaUI.label("同声传译",size:14,weight:.medium),targetButton,UIView(),translateSwitch]); row.alignment = .center; row.spacing = 8
        return row
    }
    private func configureVoiceControls() {
        languageButton.surface = .tile; languageButton.rounded = 13
        languageButton.accessibilityIdentifier="voice.language"; languageButton.accessibilityLabel="识别语言"
        languageButton.showsMenuAsPrimaryAction=true
        languageButton.contentEdgeInsets=UIEdgeInsets(top:10,left:14,bottom:10,right:14)
        languageButton.titleLabel?.font=LianaPalette.font(14,weight:.medium,maximum:20)
        languageButton.setImage(UIImage(systemName:"globe"),for:.normal)
        languageButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize:15,weight:.medium),forImageIn:.normal)
        languageButton.imageEdgeInsets=UIEdgeInsets(top:0,left:-6,bottom:0,right:6)
        languageButton.setContentHuggingPriority(.required,for:.horizontal)
        languageButton.heightAnchor.constraint(greaterThanOrEqualToConstant:38).isActive=true

        targetButton.surface = .tile; targetButton.rounded = 13
        targetButton.accessibilityIdentifier="voice.target"; targetButton.accessibilityLabel="译文目标语言"
        targetButton.showsMenuAsPrimaryAction=true
        targetButton.contentEdgeInsets=UIEdgeInsets(top:8,left:12,bottom:8,right:12)
        targetButton.titleLabel?.font=LianaPalette.font(13,weight:.medium,maximum:19)
        targetButton.setContentHuggingPriority(.required,for:.horizontal)
        targetButton.heightAnchor.constraint(greaterThanOrEqualToConstant:34).isActive=true

        translateSwitch.accessibilityIdentifier="voice.translate"; translateSwitch.accessibilityLabel="同声传译"
        translateSwitch.onTintColor=LianaPalette.primary
        translateSwitch.isOn=translateOn
        translateSwitch.addTarget(self,action:#selector(toggleTranslation),for:.valueChanged)

        voiceHint.accessibilityIdentifier="voice.hint"
        translationHint.accessibilityIdentifier="voice.translation.hint"
        translationText.accessibilityIdentifier="voice.translation"
        translationText.accessibilityLabel="本机译文"
        translationCaption.accessibilityIdentifier="voice.translation.caption"
        voiceHint.isHidden=true; settingsButton.isHidden=true
        refreshLanguageMenus(); refreshOnDeviceStatus(); updateTranslationViews()
    }
    private func refreshLanguageMenus() {
        languageButton.setTitle(recognitionLanguage.nativeName,for:.normal)
        languageButton.accessibilityValue=recognitionLanguage.menuTitle
        languageButton.menu=UIMenu(title:"识别语言",children:VoiceLanguage.allCases.map { language in
            UIAction(title:language.menuTitle,state:language == recognitionLanguage ? .on : .off) { [weak self] _ in self?.selectRecognition(language) }
        })
        targetButton.setTitle("译为 \(translationTarget.nativeName)",for:.normal)
        targetButton.accessibilityValue=translationTarget.menuTitle
        targetButton.menu=UIMenu(title:"译文语言",children:VoiceLanguage.allCases.filter { $0 != recognitionLanguage }.map { language in
            UIAction(title:language.menuTitle,state:language == translationTarget ? .on : .off) { [weak self] _ in self?.selectTranslationTarget(language) }
        })
        editorCaption.text="\(recognitionLanguage.nativeName) · 本机识别"
    }
    private func selectRecognition(_ language:VoiceLanguage) {
        guard voice.state == .idle,language != recognitionLanguage else { return }
        recognitionLanguage=language; VoiceLanguageSettings.saveRecognition(language); voice.language=language
        if translationTarget == language {
            translationTarget=VoiceLanguageSettings.saveTranslationTarget(VoiceLanguageSettings.translationTarget(source:language))
        }
        refreshLanguageMenus(); refreshOnDeviceStatus(); updateVoiceControls()
        if translateOn { clearTranslation(); configureTranslationCallbacks(); checkTranslationAvailability() }
        setStatus("已切换到\(language.nativeName)；识别只在本机进行。",in:.voice)
    }
    private func selectTranslationTarget(_ language:VoiceLanguage) {
        guard voice.state == .idle,language != recognitionLanguage,language != translationTarget else { return }
        translationTarget=VoiceLanguageSettings.saveTranslationTarget(language)
        refreshLanguageMenus()
        if translateOn { clearTranslation(); configureTranslationCallbacks(); checkTranslationAvailability() }
        updateTranslationViews(); updateVoiceControls()
    }
    private func refreshOnDeviceStatus() {
        guard let recognizer=SFSpeechRecognizer(locale:recognitionLanguage.locale) else {
            showVoiceHint("系统不支持\(recognitionLanguage.nativeName)语音识别，请换一种语言。",settings:false); return
        }
        if recognizer.supportsOnDeviceRecognition { hideVoiceHint() }
        else { showVoiceHint("本机还没有\(recognitionLanguage.nativeName)离线语音包。到「设置 → 通用 → 键盘 → 听写语言」下载后再试；松萝不会改用云端识别。") }
    }
    private func showVoiceHint(_ text:String,settings:Bool = false) {
        voiceHint.text=text; voiceHint.isHidden=false; settingsButton.isHidden = !settings
    }
    private func hideVoiceHint() { voiceHint.isHidden=true; settingsButton.isHidden=true }
    private func handleVoiceIssue(_ issue:LocalVoiceSession.Issue) {
        switch issue {
        case .speechPermissionDenied:
            showVoiceHint("需要「语音识别」权限。请在系统设置中允许松萝后重试；音频不会离开设备。",settings:true)
        case .microphonePermissionDenied:
            showVoiceHint("需要麦克风权限。请在系统设置中允许松萝后重试；录音只在本机转换。",settings:true)
        case .recognizerUnavailable(let language):
            showVoiceHint("系统不支持\(language.nativeName)语音识别，请换一种语言。",settings:false)
        case .onDeviceModelMissing(let language):
            showVoiceHint("本机还没有\(language.nativeName)离线语音包。到「设置 → 通用 → 键盘 → 听写语言」下载后再试；松萝不会改用云端识别。")
        case .failed(let message):
            showVoiceHint(message,settings:false)
        }
    }
    private func openSettings() {
        guard let url=URL(string:UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    @objc private func toggleTranslation() {
        guard voice.state == .idle else { return }
        translateOn=translateSwitch.isOn
        VoiceLanguageSettings.saveTranslationEnabled(translateOn)
        if translateOn {
            configureTranslationCallbacks(); attachTranslationHost(); checkTranslationAvailability()
        } else {
            clearTranslation(); setStatus("已关闭同声传译，仍可复制识别文字。",in:.voice)
        }
        updateTranslationViews(); updateVoiceControls()
    }
    private func configureTranslationCallbacks() {
        let epoch=translationEpoch
        translation.onResult={ [weak self] result in
            guard let self,self.translationEpoch == epoch,self.translateOn else { return }
            self.latestTranslation=result.translatedText; self.latestTranslationSource=result.sourceText; self.translationStatus=nil
            self.updateVoiceControls()
        }
        translation.onFailure={ [weak self] message in
            guard let self,self.translationEpoch == epoch else { return }
            self.translationStatus=message; self.updateTranslationViews(); self.setStatus(message,in:.voice)
        }
        translation.onPreparing={ [weak self] in
            guard let self,self.translationEpoch == epoch else { return }
            self.translationStatus="正在准备本机语言包，请在系统提示中确认…"; self.updateTranslationViews()
        }
        translation.onAvailability={ [weak self] availability in
            guard let self,self.translationEpoch == epoch else { return }
            self.apply(availability)
        }
    }
    private func checkTranslationAvailability() {
        guard translateOn else { return }
        guard VoiceTranslationController.isSupported else {
            translationStatus=VoiceTranslationController.minimumSystemDescription + "当前仅识别文字。"
            translateOn=false; translateSwitch.setOn(false,animated:true); VoiceLanguageSettings.saveTranslationEnabled(false)
            translation.cancel(); updateTranslationViews(); updateVoiceControls(); return
        }
        translation.checkAvailability(source:recognitionLanguage,target:translationTarget)
        updateTranslationViews()
    }
    private func apply(_ availability:VoiceTranslationAvailability) {
        switch availability {
        case .checking:
            translationStatus="正在检查本机翻译语言包…"
        case .ready:
            translationStatus="本机翻译已就绪，边识别边出译文。"
        case .needsDownload:
            translationStatus="正在准备\(translationTarget.nativeName)语言包，请在系统弹窗中确认；译文只在本机生成。"
            translation.prepare(source:recognitionLanguage,target:translationTarget)
        case .unsupported:
            translationStatus="系统暂不支持\(recognitionLanguage.nativeName) → \(translationTarget.nativeName)的本地翻译，请换一个目标语言。"
            disableTranslation()
            setStatus(translationStatus ?? "",in:.voice)
        case .requiresNewerOS:
            translationStatus=VoiceTranslationController.minimumSystemDescription + "当前仅识别文字。"
            disableTranslation()
            setStatus(translationStatus ?? "",in:.voice)
        case .failed(let message):
            translationStatus=message
        }
        updateTranslationViews(); updateVoiceControls()
    }
    private func disableTranslation() {
        translateOn=false; translateSwitch.setOn(false,animated:true); VoiceLanguageSettings.saveTranslationEnabled(false)
        translation.cancel()
    }
    private func beginVoiceSession() {
        translationEpoch += 1
        translationWork?.cancel(); translationWork=nil
        translationThrottle.reset()
        latestTranslation=nil; latestTranslationSource=nil; translationStatus=nil; lastRecognizedText=""
        translation.cancel()
        voice.language=recognitionLanguage
        if translateOn { configureTranslationCallbacks(); attachTranslationHost(); checkTranslationAvailability() }
        updateTranslationViews()
    }
    private func endTranslationSession() {
        translationEpoch += 1
        translationWork?.cancel(); translationWork=nil
        translation.cancel()
    }
    private func clearTranslation() {
        endTranslationSession()
        translationThrottle.reset()
        latestTranslation=nil; latestTranslationSource=nil; translationStatus=nil; lastRecognizedText=""
        updateTranslationViews(); updateVoiceControls()
    }
    private func scheduleTranslation(for text:String,immediate:Bool = false) {
        guard translateOn,VoiceTranslationController.isSupported else { return }
        let accepted=translationThrottle.offer(text,at:CACurrentMediaTime())
        guard immediate || accepted || translationThrottle.hasPending else { return }
        translationWork?.cancel()
        let delay=immediate ? 0.12 : VoiceTranslationThrottle.defaultDebounce
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.translateOn else { return }
            guard let pending=self.translationThrottle.take(at:CACurrentMediaTime(),tolerance:0.15,force:immediate) else { return }
            self.translation.translate(pending,source:self.recognitionLanguage,target:self.translationTarget)
        }
        translationWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func flushTranslation() {
        guard translateOn,!lastRecognizedText.isEmpty else { return }
        scheduleTranslation(for:lastRecognizedText,immediate:true)
    }
    private func attachTranslationHost() {
        guard translationHost == nil,let host=translation.hostingViewController else { return }
        addChild(host)
        host.view.backgroundColor = .clear; host.view.isUserInteractionEnabled=false; host.view.translatesAutoresizingMaskIntoConstraints=false; host.view.alpha=0
        view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.widthAnchor.constraint(equalToConstant:1),host.view.heightAnchor.constraint(equalToConstant:1),host.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),host.view.topAnchor.constraint(equalTo:view.topAnchor)])
        host.didMove(toParent:self); translationHost=host
    }
    private func updateTranslationViews() {
        let supported=VoiceTranslationController.isSupported
        translateSwitch.isOn=translateOn
        translateSwitch.isEnabled=voice.state == .idle && supported
        targetButton.isHidden = !supported
        targetButton.isEnabled=voice.state == .idle && supported
        translationCaption.isHidden = !translateOn
        translationCaption.text="译文 · \(translationTarget.nativeName)"
        let translated=latestTranslation?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        translationText.text=latestTranslation
        translationText.isHidden = !translateOn || translated.isEmpty
        if !supported {
            translationHint.text=VoiceTranslationController.minimumSystemDescription + "当前仅识别文字。"
        } else if !translateOn {
            translationHint.text=translationStatus ?? "开启后边识别边翻译；译文只在本机生成，不联网。"
        } else {
            translationHint.text=translationStatus ?? "说到哪里，译到哪里。译文只在本机生成。"
        }
        translationHint.isHidden=false
    }
    private func schedulePhraseSave() {
        phraseSaveWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.savePhrases() }
        phraseSaveWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:work)
    }
    private func savePhrases() {
        phraseSaveWork?.cancel()
        let result=MobilePhraseBookSettings.save(phrasesEditor.text)
        phrases=result.phrases
        if result.truncated {
            phrasesEditor.text=MobilePhraseBook.text(from:phrases)
            setStatus("最多 20 条、每条 50 字，已截断到上限。",in:.dictionary)
        }
        updatePhraseControls()
    }
    private func updatePhraseControls() {
        let result=MobilePhraseBook.normalize(phrasesEditor.text)
        phraseCount.text="\(result.phrases.count)/\(MobilePhraseBook.maximumCount) 条 · 每条最多 \(MobilePhraseBook.maximumLength) 字"
        phrasesCopy.isEnabled = !result.phrases.isEmpty
    }
    private func copyPhrases() {
        savePhrases()
        guard !phrases.isEmpty else { setStatus("先写一条常用短语，再复制到键盘。",in:.dictionary); return }
        copy(KeyboardPayload(kind:"phrases",text:MobilePhraseBook.text(from:phrases)),in:.dictionary)
    }
    private func copy(_ payload:KeyboardPayload,in target:Section) {
        do {
            try payload.copy()
            let text:String
            switch payload.kind {
            case "words":text="词库已复制。回到松萝工具 → 词库 → 接收。"
            case "phrases":text="常用短语已复制。回到键盘 → 工具 → 词库 → 接收常用短语（或长按九键数字下滑）。"
            case "pairing":text="配对已复制。回到松萝工具 → 同步 → 接收配对。"
            case "gif":text="GIF 已复制，可在支持图片的聊天框粘贴，也可回松萝接收收藏。"
            default:text="文字已复制，可以直接粘贴，也可回松萝接收。"
            }
            setStatus(text,in:target); UISelectionFeedbackGenerator().selectionChanged()
        } catch { setStatus(error.localizedDescription,in:target) }
    }
    private func choose(gif:Bool) { importingGIF=gif; let picker=UIDocumentPickerViewController(forOpeningContentTypes:gif ? [.gif] : [.item],asCopy:true); picker.delegate=self; present(picker,animated:true) }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let url=urls.first else { return }; let gif=importingGIF; let wubi=format.selectedSegmentIndex==1; let target:Section=gif ? .media : .dictionary
        setStatus("正在读取文件…",in:target)
        if !gif { importGeneration += 1; fetcher?.cancel(); fetcher=nil; setImportBusy(true) }
        let generation=importGeneration
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size <= (gif ? 4_000_000 : 20_000_000) else { throw MobileImportError.message("文件超过大小上限。") }
                let data=try Data(contentsOf:url)
                if gif {
                    guard let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { throw MobileImportError.message("请选择有效 GIF 文件。") }
                    DispatchQueue.main.async { self?.copy(KeyboardPayload(kind:"gif",gif:data),in:.media) }
                } else {
                    let words=try MobileDictionaryImport.parse(data,wubi:wubi)
                    DispatchQueue.main.async { guard let self,self.importGeneration==generation else { return }; self.accept(words) }
                }
            } catch { DispatchQueue.main.async {
                guard let self,gif || self.importGeneration==generation else { return }
                if !gif { self.setImportBusy(false) }; self.setStatus(error.localizedDescription,in:target)
            } }
        }
    }
    private func setImportBusy(_ busy:Bool) {
        importingDictionary=busy; format.isEnabled = !busy; dictionaryCopy.isEnabled = !busy && !words.isEmpty
        dictionaryCopy.setTitle(busy ? "正在解析…" : (words.isEmpty ? "复制词库到键盘" : "复制 \(words.count) 条词语到键盘"),for:.normal)
    }
    private func accept(_ values:[MobileWord]) {
        words=values; setImportBusy(false)
        setStatus("已解析 \(values.count) 条词语。复制后回键盘接收。",in:.dictionary)
    }
    private func github() {
        let alert=UIAlertController(title:"GitHub 词库文件",message:"粘贴具体 .txt、.tsv 或 .dict.yaml 文件链接。",preferredStyle:.alert)
        alert.addTextField { $0.placeholder="https://github.com/…/blob/…/词库.dict.yaml"; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"下载并解析",style:.default) { [weak self,weak alert] _ in
            guard let self else { return }
            self.importGeneration += 1; let generation=self.importGeneration
            self.fetcher?.cancel(); self.fetcher=nil; self.setImportBusy(false)
            do {
                let url=try MobileDictionaryImport.githubURL(alert?.textFields?.first?.text ?? ""); let wubi=self.format.selectedSegmentIndex==1
                self.setStatus("正在下载词库…",in:.dictionary); self.setImportBusy(true)
                self.fetcher=BoundedDictionaryDownload(url:url) { [weak self] result in
                    DispatchQueue.global(qos:.userInitiated).async {
                        let parsed=result.flatMap { data in Result { try MobileDictionaryImport.parse(data,wubi:wubi) } }
                        DispatchQueue.main.async {
                            guard let self,self.importGeneration==generation else { return }
                            switch parsed { case .success(let words):self.accept(words); case .failure(let error):self.setImportBusy(false); self.setStatus(error.localizedDescription,in:.dictionary) }
                            self.fetcher=nil
                        }
                    }
                }
            } catch { self.setImportBusy(false); self.setStatus(error.localizedDescription,in:.dictionary) }
        }); present(alert,animated:true)
    }
}
private final class BoundedDictionaryDownload:NSObject,URLSessionDataDelegate {
    private var session:URLSession!
    private var bytes=Data()
    private var completion:((Result<Data,Error>)->Void)?
    init(url:URL,completion:@escaping(Result<Data,Error>)->Void) { super.init(); self.completion=completion; let c=URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest=30; session=URLSession(configuration:c,delegate:self,delegateQueue:nil); session.dataTask(with:url).resume() }
    func cancel() { session?.invalidateAndCancel() }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) { guard (response as? HTTPURLResponse)?.statusCode==200,response.expectedContentLength<=20_000_000 else { completionHandler(.cancel); finish(.failure(MobileImportError.message("词库下载失败或超过 20MB。"))); return }; completionHandler(.allow) }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) { guard bytes.count+data.count<=20_000_000 else { finish(.failure(MobileImportError.message("词库超过 20MB。"))); return }; bytes.append(data) }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(request.url?.host=="raw.githubusercontent.com" && request.url?.scheme=="https" ? request : nil) }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) { if let error { finish(.failure(error)) } else { finish(.success(bytes)) } }
    private func finish(_ result:Result<Data,Error>) { let callback=completion; completion=nil; session.invalidateAndCancel(); callback?(result) }
}