import UIKit
import UniformTypeIdentifiers
import ImageIO

final class MobileToolsViewController: UIViewController, UIDocumentPickerDelegate {
    private let stack = UIStackView()
    private let status = UILabel()
    private let editor = UITextView()
    private let format = UISegmentedControl(items: ["拼音／词语", "五笔 86"])
    private let voice = LocalVoiceSession()
    private var importingGIF = false
    private var fetcher: BoundedDictionaryDownload?
    private var words: [MobileWord] = []
    override func viewDidLoad() {
        super.viewDidLoad(); title = "移动输入工具"; view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target:self,action:#selector(done))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor),stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-20),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-40)])
        addLabel("语音转文字", heading:true)
        addLabel("在主 App 录音并离线识别，编辑后复制，回到松萝键盘点顶部四格 → 接收 App 内容。")
        editor.font = .preferredFont(forTextStyle:.body); editor.backgroundColor = .secondarySystemGroupedBackground; editor.layer.cornerRadius = 10; editor.heightAnchor.constraint(equalToConstant:120).isActive = true; editor.accessibilityIdentifier = "voice.text"; stack.addArrangedSubview(editor)
        addButton("开始语音识别", id:"voice.start") { [weak self] in self?.editor.resignFirstResponder(); self?.voice.start() }
        addButton("停止录音", id:"voice.stop") { [weak self] in self?.voice.stop(); self?.status.text = "已停止，可编辑后复制。" }
        addButton("复制文字到键盘", id:"voice.copy") { [weak self] in guard let self else { return }; self.copy(KeyboardPayload(kind:"text",text:self.editor.text)) }
        voice.onText = { [weak self] in self?.editor.text = $0 }; voice.onStatus = { [weak self] in self?.status.text = $0 }
        status.numberOfLines = 0; status.textColor = .secondaryLabel; status.accessibilityIdentifier = "mobile.status"; status.text = "所有接收操作由你主动触发；普通输入不需要完全访问。"; stack.addArrangedSubview(status)
        addLabel("导入本地／GitHub 词库",heading:true)
        addLabel("支持 UTF-8 TXT（一行一词）、TSV、Rime dict.yaml。TSV：词语 Tab 拼音或五笔码 Tab 词频。每次最多 20,000 条；未写拼音的词语自动转拼音。")
        format.selectedSegmentIndex = 0; stack.addArrangedSubview(format)
        addButton("选择本地词库文件",id:"dict.local") { [weak self] in self?.choose(gif:false) }
        addButton("从 GitHub 文件链接导入",id:"dict.github") { [weak self] in self?.github() }
        addButton("复制已解析词库到键盘",id:"dict.copy") { [weak self] in
            guard let self else { return }; guard !self.words.isEmpty else { self.status.text = "请先选择并解析词库。"; return }; self.copy(KeyboardPayload(kind:"words",words:self.words))
        }
        addLabel("系统词库：在键盘四格面板点「导入系统补充词库」，读取系统公开的联系人、文本替换等。苹果不提供完整系统词库导出。")
        addLabel("GIF 与颜文字",heading:true)
        addLabel("颜文字在键盘工具面板直接插入。GIF 可从文件导入，键盘中点缩略图复制，再粘贴到支持图片的聊天框。")
        addButton("选择 GIF 并复制到键盘",id:"gif.import") { [weak self] in self?.choose(gif:true) }
        addLabel("Mac 剪贴板",heading:true)
        addLabel("先在「连接 Mac 桌宠」完成配对，再把配对复制给键盘。Mac 开启接收并勾选允许剪贴板后，在键盘四格面板点发送／接收。仅同一局域网、前台按需同步文字。")
        addButton("复制 Mac 配对给键盘",id:"mobile.pairing") { [weak self] in
            guard let self else { return }; guard let profile = PetLink.load(account:"mac") else { self.status.text = "请先返回首页连接并配对 Mac。"; return }; self.copy(KeyboardPayload(kind:"pairing",text:profile.pairingCode))
        }
        addLabel("输入方案",heading:true)
        addLabel("长按键盘底部「中／EN」，或顶部四格 → 输入方案：全拼、九宫格、小鹤／微软／自然码双拼、五笔 86、手写。全拼和英文可在字母间滑动，抬手后选词。手写按笔顺写单字。")
        addLabel("第三方数据与许可",heading:true)
        addLabel("五笔：Rime rime-wubi（LGPL-3.0）；离线手写：HanziLookupJS（GPL-3.0），Make Me a Hanzi 数据（Arphic Public License）。完整许可随键盘资源和开源仓库提供。")
        addButton("查看开源代码与第三方许可", id:"mobile.licenses") {
            UIApplication.shared.open(URL(string:"https://github.com/sevenaaaaaaaaa/liana/tree/main/platforms/ios/Vendor")!)
        }
        NotificationCenter.default.addObserver(self,selector:#selector(stopVoice),name:UIApplication.didEnterBackgroundNotification,object:nil)
    }
    deinit { NotificationCenter.default.removeObserver(self); fetcher?.cancel(); voice.stop() }
    @objc private func stopVoice() { voice.stop() }
    @objc private func done() { voice.stop(); fetcher?.cancel(); dismiss(animated:true) }
    private func addLabel(_ text:String,heading:Bool=false) { let l=UILabel(); l.text=text; l.numberOfLines=0; l.font = .preferredFont(forTextStyle:heading ? .headline : .subheadline); stack.addArrangedSubview(l) }
    private func addButton(_ title:String,id:String,action:@escaping ()->Void) { var c=UIButton.Configuration.tinted(); c.title=title; let b=UIButton(configuration:c); b.accessibilityIdentifier=id; b.heightAnchor.constraint(greaterThanOrEqualToConstant:48).isActive=true; b.addAction(UIAction { _ in action() },for:.touchUpInside); stack.addArrangedSubview(b) }
    private func copy(_ payload:KeyboardPayload) { do { try payload.copy(); status.text="已复制。10 分钟内回到松萝键盘，点四格 → 接收 App 内容。需允许键盘完全访问。" } catch { status.text=error.localizedDescription } }
    private func choose(gif:Bool) { importingGIF=gif; let picker=UIDocumentPickerViewController(forOpeningContentTypes:gif ? [.gif] : [.item],asCopy:true); picker.delegate=self; present(picker,animated:true) }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let url=urls.first else { return }; let gif=importingGIF; let wubi=format.selectedSegmentIndex==1; status.text="正在读取文件…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size <= (gif ? 4_000_000 : 20_000_000) else { throw MobileImportError.message("文件超过大小上限。") }
                let data=try Data(contentsOf:url)
                if gif {
                    guard let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { throw MobileImportError.message("请选择有效 GIF 文件。") }
                    DispatchQueue.main.async { self?.copy(KeyboardPayload(kind:"gif",gif:data)) }
                } else { let words=try MobileDictionaryImport.parse(data,wubi:wubi); DispatchQueue.main.async { self?.accept(words) } }
            } catch { DispatchQueue.main.async { self?.status.text=error.localizedDescription } }
        }
    }
    private func accept(_ values:[MobileWord]) { words=values; status.text="已解析 \(values.count) 条词语。点「复制已解析词库到键盘」，再回键盘接收。" }
    private func github() {
        let alert=UIAlertController(title:"GitHub 词库文件",message:"粘贴具体 .txt／.tsv／.dict.yaml 文件链接。",preferredStyle:.alert)
        alert.addTextField { $0.placeholder="https://github.com/…/blob/…/词库.dict.yaml"; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"下载并解析",style:.default) { [weak self,weak alert] _ in
            guard let self else { return }
            do { let url=try MobileDictionaryImport.githubURL(alert?.textFields?.first?.text ?? ""); let wubi=self.format.selectedSegmentIndex==1
                self.status.text="正在下载词库…"; self.fetcher?.cancel()
                self.fetcher=BoundedDictionaryDownload(url:url) { [weak self] result in
                    DispatchQueue.global(qos:.userInitiated).async {
                        let parsed=result.flatMap { data in Result { try MobileDictionaryImport.parse(data,wubi:wubi) } }
                        DispatchQueue.main.async { switch parsed { case .success(let words):self?.accept(words); case .failure(let error):self?.status.text=error.localizedDescription }; self?.fetcher=nil }
                    }
                }
            } catch { self.status.text=error.localizedDescription }
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
