import UIKit

final class ViewController: UIViewController, UITextViewDelegate {
    private let testInput = LianaEditorView()
    private let placeholder = LianaUI.label("点这里，试着输入 nihao…", size: 16, muted: true)
    private weak var scroll: UIScrollView?
    private weak var previewControl: UISegmentedControl?
    private weak var previewKeyboard: KeyboardPreviewView?
    private var didChoosePreviewTheme=false
    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = LianaUI.scrollStack(in: self, spacing: 20); scroll = stack.superview as? UIScrollView
        let heading = LianaUI.vertical([LianaUI.label("松萝输入法", size: 32, weight: .semibold),LianaUI.label("让输入回到顺手的节奏。", size: 14, muted: true)],spacing:8)
        let help = LianaUI.button("", icon:"questionmark.circle", role:.plain,id:"home.guide") { [weak self] in self?.showGuide() }
        help.accessibilityLabel = "启用与使用指南"; help.widthAnchor.constraint(equalToConstant:44).isActive = true
        let header = UIStackView(arrangedSubviews:[heading,help]); header.alignment = .center; stack.addArrangedSubview(header)

        let preview = KeyboardPreviewView(); previewKeyboard=preview; preview.heightAnchor.constraint(equalToConstant:176).isActive = true
        let theme = LianaUI.segment(["雾白","石墨黑"]); previewControl=theme; theme.widthAnchor.constraint(equalToConstant:148).isActive = true
        theme.selectedSegmentIndex = traitCollection.userInterfaceStyle == .dark ? 1 : 0
        theme.accessibilityIdentifier = "home.preview.theme"; theme.accessibilityLabel = "预览键盘主题"
        preview.overrideUserInterfaceStyle = theme.selectedSegmentIndex == 0 ? .light : .dark
        theme.addAction(UIAction { [weak self, weak theme, weak preview] _ in
            self?.didChoosePreviewTheme=true
            guard let theme, let preview else { return }
            let change = { preview.overrideUserInterfaceStyle = theme.selectedSegmentIndex == 0 ? .light : .dark }
            if LianaMotion.enabled { UIView.transition(with:preview,duration:0.16,options:[.transitionCrossDissolve,.allowUserInteraction],animations:change) } else { change() }
        },for:.valueChanged)
        let caption = LianaUI.label("键盘预览",size:13,weight:.medium,muted:true)
        let previewTop = UIStackView(arrangedSubviews:[caption,theme]); previewTop.alignment = .center; previewTop.spacing = 12
        stack.addArrangedSubview(LianaUI.card([previewTop,preview],spacing:12))

        let setup = LianaUI.vertical([LianaUI.label("添加一次，随时输入",size:16,weight:.semibold),LianaUI.label("设置 → 键盘 → 添加松萝",size:12,muted:true)],spacing:5)
        let settings = LianaUI.button("去设置",role:.primary,id:"home.settings") { [weak self] in self?.openAppSettings() }
        settings.widthAnchor.constraint(equalToConstant:98).isActive = true
        let setupRow = UIStackView(arrangedSubviews:[setup,settings]); setupRow.spacing = 12; setupRow.alignment = .center
        stack.addArrangedSubview(LianaUI.card([setupRow]))

        let tools = LianaActionTile(title:"输入工具",subtitle:"语音 · 词库 · 表情",icon:"square.grid.2x2",primary:true,id:"mobile.tools") { [weak self] in self?.showTools() }
        let mac = LianaActionTile(title:"连接 Mac",subtitle:"文件与文字，轻松互传",icon:"laptopcomputer",id:"mac.open") { [weak self] in self?.showMacLink() }
        let actions = UIStackView(arrangedSubviews:[tools,mac]); actions.distribution = .fillEqually; actions.spacing = 12
        stack.addArrangedSubview(actions)

        testInput.delegate = self; testInput.accessibilityIdentifier = "typing-test"; testInput.accessibilityLabel = "松萝试打输入框"
        testInput.font = LianaPalette.font(17); testInput.adjustsFontForContentSizeCategory = true
        testInput.backgroundColor = LianaPalette.soft; testInput.textColor = LianaPalette.ink; testInput.tintColor = LianaPalette.ink
        testInput.layer.cornerRadius = 12; testInput.textContainerInset = UIEdgeInsets(top:14,left:10,bottom:14,right:10)
        testInput.autocorrectionType = .no; testInput.smartQuotesType = .no
        placeholder.isUserInteractionEnabled = false; placeholder.translatesAutoresizingMaskIntoConstraints = false; testInput.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo:testInput.leadingAnchor,constant:14),placeholder.trailingAnchor.constraint(lessThanOrEqualTo:testInput.trailingAnchor,constant:-14),placeholder.topAnchor.constraint(equalTo:testInput.topAnchor,constant:14)])
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("试试真实输入",size:17,weight:.semibold),LianaUI.label("点输入框，长按地球键切换到松萝。",size:13,muted:true),testInput]))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let foot = LianaUI.label("本地输入，本地学习。\nLiana \(version) (\(build))",size:12,muted:true); foot.textAlignment = .center; stack.addArrangedSubview(foot)
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated); updatePreviewForEnvironment() }
    override func traitCollectionDidChange(_ previousTraitCollection:UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); updatePreviewForEnvironment() }
    private func updatePreviewForEnvironment() {
        guard !didChoosePreviewTheme,let previewControl,let previewKeyboard else { return }
        let dark=traitCollection.userInterfaceStyle == .dark
        previewControl.selectedSegmentIndex=dark ? 1 : 0; previewKeyboard.overrideUserInterfaceStyle=dark ? .dark : .light
    }
    func textViewDidChange(_ textView:UITextView) { placeholder.isHidden = !textView.text.isEmpty }
    func textViewDidBeginEditing(_ textView:UITextView) { DispatchQueue.main.async { [weak self] in guard let self,let scroll=self.scroll else { return }; self.view.layoutIfNeeded(); scroll.scrollRectToVisible(self.testInput.convert(self.testInput.bounds,to:scroll).insetBy(dx:0,dy:-16),animated:LianaMotion.enabled) } }
    private func openAppSettings() { UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) }
    private func showGuide() { presentSheet(LianaGuideViewController()) }
    private func showTools() { presentSheet(MobileToolsViewController()) }
    private func presentSheet(_ controller:UIViewController) {
        let navigation = UINavigationController(rootViewController:controller)
        navigation.sheetPresentationController?.detents = [.large()]; navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation,animated:true)
    }
    func showMacLink(file: URL? = nil) {
        if let navigation=presentedViewController as? UINavigationController,let existing=navigation.viewControllers.first as? PetLinkViewController {
            if let file { existing.receiveFile(file) }; return
        }
        let show = { [weak self] in
            guard let self else { return }; let link=PetLinkViewController(); if let file { link.receiveFile(file) }; self.presentSheet(link)
        }
        if presentedViewController != nil { dismiss(animated:false,completion:show) } else { show() }
    }
}
