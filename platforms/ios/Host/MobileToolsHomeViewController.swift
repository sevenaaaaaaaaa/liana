import UIKit

/// 输入工具的一级页：只回答「你要做什么」，具体操作进各自的二级页。
///
/// 过去是四个分类挤在一条 segmented control 里，每页把编辑器、导入、帮助全摊在一屏；
/// 第一次进来的人分不清哪件常用、哪件一年碰一次。现在一级只给四个入口 + 一行状态摘要，
/// 想做什么点进去，页面里只剩那一件事。
final class MobileToolsHomeViewController: UIViewController {
    private let rows = LianaUI.vertical(spacing:10)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "输入工具"
        LianaUI.navigation(self)
        navigationItem.rightBarButtonItem = LianaUI.closeItem(id:"tools.done") { [weak self] in
            self?.dismiss(animated:true)
        }

        let stack = LianaUI.scrollStack(in:self, spacing:18)
        stack.addArrangedSubview(LianaUI.label("你要做什么？", size:24, weight:.semibold))
        stack.addArrangedSubview(LianaUI.label("常用的放前面，偶尔才用的收在各自页面里。", size:13, muted:true))

        for section in [MobileToolsViewController.Section.voice, .dictionary, .media, .sync] {
            rows.addArrangedSubview(entry(section))
        }
        stack.addArrangedSubview(LianaUI.card([rows], spacing:8))

        stack.addArrangedSubview(LianaActionRow(
            title:"配色方案",
            subtitle:"十套色卡，含浅色与深色两版",
            icon:"paintpalette",
            id:"tools.colorways"
        ) { [weak self] in self?.presentSheet(ColorwayGalleryViewController()) })

        stack.addArrangedSubview(LianaActionRow(
            title:"外接语音与编码设备",
            subtitle:"了解蓝牙 HID 与 BLE 的连接方式",
            icon:"waveform",
            id:"tools.devices"
        ) { [weak self] in self?.presentSheet(LianaGuideViewController()) })

        let licenses = LianaUI.button("开源代码与许可", role:.plain, id:"tools.licenses") {
            UIApplication.shared.open(URL(string:"https://github.com/sevenaaaaaaaaa/liana/tree/main/platforms/ios/Vendor")!)
        }
        stack.addArrangedSubview(licenses)

        stack.addArrangedSubview(LianaUI.label("所有识别、学习与短语都留在本机；联网只在你说可以的时候发生。", size:12, muted:true))
    }

    private func entry(_ section: MobileToolsViewController.Section) -> UIView {
        LianaActionRow(title:section.title, subtitle:summary(section), icon:section.icon, id:"tools.\(section)") { [weak self] in
            self?.open(section)
        }
    }

    /// 一行摘要：让用户不点进去也知道里面是什么状态。
    private func summary(_ section: MobileToolsViewController.Section) -> String {
        switch section {
        case .voice:
            let draft = UserDefaults.standard.string(forKey:MobileToolsViewController.draftKey)?
                .trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            if draft.isEmpty { return "说一句，变成文字；可开同声传译" }
            return "草稿：\(draft.prefix(18))\(draft.count > 18 ? "…" : "")"
        case .dictionary:
            let phrases = MobilePhraseBookSettings.load()
            if phrases.isEmpty { return "常用短语、自定义词库、导入导出" }
            return "\(phrases.count) 条常用短语，可再导入词库"
        case .media:
            return "颜文字，收藏 GIF 到键盘"
        case .sync:
            return PetLink.load(account:"mac") == nil ? "未配对：扫码一次，之后互传文件与文字" : "已配对 Mac"
        }
    }

    private func open(_ section: MobileToolsViewController.Section) {
        presentSheet(MobileToolsViewController(section:section))
    }

    private func presentSheet(_ controller: UIViewController) {
        let nav = UINavigationController(rootViewController:controller)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated:true)
    }
}
