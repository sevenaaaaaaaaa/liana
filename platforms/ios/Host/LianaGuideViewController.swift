import UIKit

final class LianaGuideViewController:UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); title="使用指南"; LianaUI.navigation(self)
        navigationItem.rightBarButtonItem=LianaUI.closeItem(id:"guide.done") { [weak self] in self?.done() }
        let stack=LianaUI.scrollStack(in:self)
        stack.addArrangedSubview(LianaUI.label("三步，开始顺手输入。",size:26,weight:.semibold))
        for (number,title,body) in [
            ("01","添加键盘","系统设置 → 通用 → 键盘 → 键盘 → 添加新键盘，选择松萝。"),
            ("02","切换到松萝","在输入框长按地球键，选择松萝键盘。普通输入无需完全访问。"),
            ("03","调到自己顺手","键盘顶部滑块图标可选标准、单手或宽松布局；精细调节可改高度、位置、字号与留白。拖动顶部工具组也能调整高度和入口位置。"),
        ] {
            stack.addArrangedSubview(LianaUI.card([LianaUI.label(number,size:12,weight:.semibold,muted:true),LianaUI.label(title,size:19,weight:.semibold),LianaUI.label(body,size:15,muted:true)]))
        }
        stack.addArrangedSubview(LianaUI.button("打开系统设置",icon:"gearshape",role:.primary,id:"guide.settings") { UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) })
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("每个入口，都有明确用途",size:18,weight:.semibold),LianaUI.label("四格：输入方案、表情、同步与词库。\n波形：外接 BLE 设备，预览文字后插入。\n滑块：主题、布局与触感。",size:15,muted:true)]))
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("外接设备",size:18,weight:.semibold),LianaUI.label("蓝牙 HID 设备在系统蓝牙设置中配对，直接输入当前 App。BLE 在键盘波形入口连接，接收设备已识别的文字；设备需要提供兼容的文字通道。",size:15,muted:true)]))
        stack.addArrangedSubview(LianaUI.card([LianaUI.label("权限，只在需要时开启",size:18,weight:.semibold),LianaUI.label("普通输入与布局留在本机。接收 App 内容、蓝牙与 Mac 同步需要允许键盘完全访问；语音在主 App 请求麦克风与识别权限。Mac 同步另外需要配对与许可。",size:15,muted:true)]))
    }
    @objc private func done() { dismiss(animated:true) }
}
