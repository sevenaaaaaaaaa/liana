import UIKit

final class ViewController: UIViewController, UITextViewDelegate {
    private let testInput = LianaEditorView()
    private let placeholder = LianaUI.label("点这里，试着输入 nihao…", size: 16, muted: true)
    private weak var scroll: UIScrollView?
    private weak var previewControl: UISegmentedControl?
    private weak var previewKeyboard: KeyboardPreviewView?
    private var didChoosePreviewTheme=false
    private let guideSlot = UIStackView()
    private static let guideKeyboardKey = "home.onboard.keyboard"
    private static let guideTriedKey = "home.onboard.tried"
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
        // 首次上手：一条能走完的路径，而不是把所有卡片平铺在这里让人自己找
        guideSlot.axis = .vertical
        stack.addArrangedSubview(guideSlot)
        refreshGuide()

        testInput.delegate = self; testInput.accessibilityIdentifier = "typing-test"; testInput.accessibilityLabel = "松萝试打输入框"
        testInput.font = LianaPalette.font(17); testInput.adjustsFontForContentSizeCategory = true
        testInput.backgroundColor = LianaPalette.soft; testInput.textColor = LianaPalette.ink; testInput.tintColor = LianaPalette.ink
        testInput.layer.cornerRadius = 12; testInput.textContainerInset = UIEdgeInsets(top:14,left:10,bottom:14,right:10)
        testInput.autocorrectionType = .no; testInput.smartQuotesType = .no
        placeholder.isUserInteractionEnabled = false; placeholder.translatesAutoresizingMaskIntoConstraints = false; testInput.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo:testInput.leadingAnchor,constant:14),placeholder.trailingAnchor.constraint(lessThanOrEqualTo:testInput.trailingAnchor,constant:-14),placeholder.topAnchor.constraint(equalTo:testInput.topAnchor,constant:14)])
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("试试真实输入",size:17,weight:.semibold),LianaUI.label("点输入框，长按地球键切换到松萝。",size:13,muted:true),testInput]))

        let tools = LianaActionTile(title:"输入工具",subtitle:"语音 · 词库 · 表情",icon:"square.grid.2x2",primary:true,id:"mobile.tools") { [weak self] in self?.showTools() }
        let mac = LianaActionTile(title:"连接 Mac",subtitle:"文件与文字，轻松互传",icon:"laptopcomputer",id:"mac.open") { [weak self] in self?.showMacLink() }
        let actions = UIStackView(arrangedSubviews:[tools,mac]); actions.distribution = .fillEqually; actions.spacing = 12
        stack.addArrangedSubview(actions)

        // 键盘预览是「看看效果」，不是上手步骤：放到工具入口之后
        stack.addArrangedSubview(LianaUI.card([previewTop,preview],spacing:12))
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
    func textViewDidChange(_ textView:UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        // 真的打出一两个字就算完成第二步，不用让用户点「我学会了」
        if !textView.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
           !UserDefaults.standard.bool(forKey:Self.guideTriedKey) {
            UserDefaults.standard.set(true, forKey:Self.guideTriedKey)
            refreshGuide()
        }
    }

    /// 首次上手的三步：只在没走完时出现，走完就收成一句状态。
    private func refreshGuide() {
        guideSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let addedKeyboard = UserDefaults.standard.bool(forKey:Self.guideKeyboardKey)
        let tried = UserDefaults.standard.bool(forKey:Self.guideTriedKey)

        if addedKeyboard && tried {
            guideSlot.addArrangedSubview(LianaUI.card([
                LianaUI.label("已经可以用了", size:16, weight:.semibold),
                LianaUI.label("长按地球键切换松萝并开始输入。要调词库、短语或布局，去下面的「输入工具」。", size:13, muted:true)
            ], spacing:6))
            return
        }

        let title = LianaUI.label(addedKeyboard ? "还差一步：切到松萝打一句" : "三步开始用松萝", size:17, weight:.semibold)
        let detail = LianaUI.label(
            addedKeyboard
                ? "长按键盘左下角的地球键，选「松萝」，然后在下面的输入框里打一句。"
                : "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 松萝",
            size:13, muted:true)
        let progress = LianaUI.label(addedKeyboard ? "1 / 2 已完成" : "0 / 2 已完成", size:12, weight:.medium, muted:true)

        let action = LianaUI.button(addedKeyboard ? "去试打" : "去设置",
                                    icon: addedKeyboard ? "keyboard" : "gearshape",
                                    role: .primary, id: "home.guide.action") { [weak self] in
            guard let self else { return }
            if UserDefaults.standard.bool(forKey:Self.guideKeyboardKey) {
                self.testInput.becomeFirstResponder()
                if let scroll=self.scroll {
                    scroll.scrollRectToVisible(self.testInput.convert(self.testInput.bounds,to:scroll).insetBy(dx:0,dy:-16),animated:LianaMotion.enabled)
                }
            } else {
                self.openAppSettings()
            }
        }

        var cardViews: [UIView] = [title, detail, progress, action]
        if !addedKeyboard {
            cardViews.append(LianaUI.button("我已经添加好了", role:.plain, id:"home.guide.mark") { [weak self] in
                UserDefaults.standard.set(true, forKey:Self.guideKeyboardKey)
                self?.refreshGuide()
            })
        }
        guideSlot.addArrangedSubview(LianaUI.card(cardViews, spacing:8))
    }
    func textViewDidBeginEditing(_ textView:UITextView) { DispatchQueue.main.async { [weak self] in guard let self,let scroll=self.scroll else { return }; self.view.layoutIfNeeded(); scroll.scrollRectToVisible(self.testInput.convert(self.testInput.bounds,to:scroll).insetBy(dx:0,dy:-16),animated:LianaMotion.enabled) } }
    private func openAppSettings() { UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) }
    private func showGuide() { presentSheet(LianaGuideViewController()) }
    private func showTools() { presentSheet(MobileToolsHomeViewController()) }
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
