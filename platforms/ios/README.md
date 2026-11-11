# 松萝 iOS

iOS 15+，UIKit 宿主 App + 本地 Rust 键盘扩展。已通过 iPhone arm64 编译、IPA 结构检查和模拟器键盘行为测试，尚未完成实体 iPhone 验收。

## 构建与安装

需要 Xcode、Rust、XcodeGen、Python 3。设备构建需要 Rust target `aarch64-apple-ios`，Apple Silicon 模拟器需要 `aarch64-apple-ios-sim`（Intel 使用 `x86_64-apple-ios`）。

```bash
./platforms/ios/build.sh device       # 默认；dist/Liana-iOS-<版本>-build<构建号>-unsigned.ipa
./platforms/ios/build.sh simulator   # 仅当前主机架构的模拟器 App
./platforms/ios/build.sh all
python3 platforms/ios/validate_ipa.py dist/Liana-iOS-0.8.0-build6-unsigned.ipa
```

IPA 未签名。用自己的签名安装工具签名主 App 和 `PlugIns/LianaKeyboard.appex`，保留嵌入扩展，确保各自 Bundle ID 与描述文件一致。默认 ID 分别是 `dev.liana.ime.ios` 与 `dev.liana.ime.ios.keyboard`。

安装后打开 App 查看引导，再到「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」添加松萝，输入时长按地球键切换。候选与学习在键盘自己的沙盒中完成，不需要允许完全访问。

### iOS 27 启动要求

使用 iOS 27 SDK 构建的 UIKit App 必须采用 Scene 生命周期，否则 iOS 27 会拒绝启动。build 4 及更早版本缺少此声明；请使用 build 5 或更新版本。宿主通过 `UIApplicationSceneManifest`、`AppDelegate.configurationForConnecting` 与 `SceneDelegate` 创建窗口，文件打开也经场景路由。参见 [Apple 的生命周期迁移说明](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)。

## 比例与入口

- 主题只有黑色、白色，默认跟随系统；在比例设置顶部可手动选择。恢复默认也会恢复跟随系统。
- 顶部四向箭头上下拖动调键高（44–64pt），左右拖动移动整组入口；VoiceOver 提供增高/降低动作。
- 滑块图标打开设置：键高、目标宽度（78–100%，手机最小可用宽度 320pt）、左右位置、候选字号（14–24pt）、额外底部留白（0–24pt，另有固定 8pt 安全间距）、入口位置。
- 滑块之外提供加减按钮与恢复默认。调节不清除组合串；设置保存在键盘自己的沙盒，退出或重新调出键盘后保留。
- 宽度与左右位置用于手机单手布局；iPad 分体继续使用屏幕两侧，高度与字号仍可调。

## 输入方案与移动工具（build 6）

- 长按底部「中／EN」或点顶部四格 → 输入方案：全拼、九宫格、小鹤／微软／自然码双拼、五笔 86、离线手写。点按中／EN 仍切换中英文。
- 微软双拼的 ing 使用底部 `;` 键。五笔使用 Rime 86 字词表；九宫格按完整拼音的数字序列匹配与补全，例如 `64426` → 你好。
- 全拼与英文支持字母间滑动，抬手后选词；这是本地几何轨迹匹配的首版，尚未加入个性化轨迹训练。当前不支持双拼或五笔滑行。
- 手写在画布内按笔顺写单字，候选栏选字；支持撤销一笔、清空、删除。识别器及模型随包携带，无需联网。
- 颜文字在顶部四格面板直接插入。主 App「语音 · 词库 · GIF · 剪贴板」选择本地 GIF，复制到键盘后点四格 → 接收 App 内容；键盘中点缩略图复制，再在支持图片的 App 粘贴。最多保存 12 个，每个不超过 4MB；可清空。不提供在线 GIF 搜索或跨 App 直接发图。
- 语音在主 App 点击开始录音，只使用设备端中文 Speech 识别；停止后可编辑、复制，回键盘四格面板接收并插入。需要麦克风和语音识别权限，以及系统中文离线资源。键盘扩展本身没有麦克风权限；不在后台录音。

### 词库导入

主 App 可选择本地 UTF-8 TXT／TSV／Rime dict.yaml，也可粘贴 GitHub 文件链接（github.com 的 blob 链接或 raw.githubusercontent.com）。选择拼音／五笔类型，后台解析，再「复制已解析词库到键盘」，回到键盘四格 → 接收 App 内容。每次最多 20,000 条、文件最多 20MB；TXT 一行一词会自动转拼音，多音字可用显式拼音纠正。

TSV 格式：`词语<Tab>song luo<Tab>1000`，五笔第二列填五笔码。仅解析词条，不执行 YAML 或远程代码。系统词库在键盘四格 → 导入系统补充词库，使用公开 UILexicon（联系人姓名、文本替换、常用补充词），不包含苹果私有的完整词库与词频模型。

主 App 与键盘通过用户主动操作的本地剪贴板交接，不依赖需要专用描述文件的 App Group，以兼容自行重签。交接内容仅本机保留 10 分钟，不加入通用剪贴板；接收操作需要允许键盘完全访问。学习记录和个人 SQLite 词库在键盘自己的沙盒中持久保存，覆盖升级保留，卸载会清除。

### Mac 文字剪贴板

两端升级，先在主 App 配对 Mac；移动工具 → 复制 Mac 配对给键盘 → 键盘四格 → 接收 App 内容。键盘会将配对保存在自己的钥匙串中。Mac 桌宠收件箱开启接收并勾选「允许已配对设备发送／读取文字剪贴板」（默认关闭）。随后点键盘四格的发送／接收按钮，同一局域网通过已配对 TLS 连接传输最多 4KB 文字。收到 Mac 文字写入 iPhone 剪贴板后，由用户粘贴；不自动插入当前输入框。

这是前台按需同步，不监听系统剪贴板、不进行后台轮询，不同步图片或剪贴板历史。忘记／撤销时可在 Mac 撤销配对并换码。

## Mac 桌宠收件箱

主 App 的「连接 Mac 桌宠 · 发送文件」支持扫码或粘贴配对码，首次在 Mac 允许，后续可直接连接。使用文件选择器发送单个文件，或在文件 App 选择用松萝打开；Mac 校验保存后桌宠提示收到文件。收件箱位于 Mac 下载目录下的「松萝收件箱」，单文件上限 200MiB。发送期间保持 iPhone App 前台。

此功能使用主 App 的本地网络权限，不要求键盘完全访问，不同步输入内容。两端都需要升级。配对、撤销、保存规则与实机验证边界见 [桌宠收件箱](../../docs/pet-link.md)。

## 蓝牙设备（实验）

波形图标打开设备面板。普通输入和布局调节不需要完全访问；BLE 扫描/连接单独要求用户允许完全访问与蓝牙权限。仅点击连接时创建蓝牙管理器，不联网，不发送输入框上下文，不自动执行收到的文本。

HID 设备由 iOS「设置 → 蓝牙」配对并直接输入当前 App。键盘不能代替系统配对、读取系统已配对 HID 列表或截获 HID 事件。

BLE 流程：扫描（15 秒）→ 手选设备 → 选择设备文档指定的 Notify／Indicate 通道 → 接收并预览 → 点击插入。成功订阅后记住设备和通道，可点击「连接上次」。关闭面板、切换输入框或隐藏键盘时停止连接；不承诺后台驻留或自动唤醒。

在「HID 配对说明与 BLE 协议」中选择文字格式：

```text
# UTF-8 行：每条最终识别文字以 LF 结尾，支持通知包拆开 UTF-8 字符
你好\n

# JSON Lines：JSON 对象后跟实际 LF，type 为 partial 或 final
{"type":"partial","text":"你"}
{"type":"final","id":"utterance-1","text":"你好"}
```

JSON 的 `id` 用于单次连接内去重，保留最近 32 个 final ID；partial 只预览。每帧最大 16KiB，待组包缓冲最大 64KiB，待插入文字最大 32KiB；错误或溢出会提示并停止接收。设备必须自行识别语音并提供兼容文字通道；不支持直接传音频、专有二进制协议或自动触发录音命令。设备侧若要求写入启动命令，需要按其协议另行适配。

已验证协议解码和键盘面板行为；实体 iPhone 的蓝牙授权、系统沙盒访问与硬件连接仍待验收，不能将模拟器通过视为设备兼容保证。

## 移动端取舍

构建时从主词库选择约 5 万条高频词和常用单字读音，保留常用简拼先验，不打包桌面神经模型。这样降低键盘扩展的内存开销，但生僻词、低频成语的覆盖少于桌面版。实体设备内存、不同 App 中的切换与长期使用仍需验证。

## 验证

```bash
swiftc platforms/ios/Keyboard/FoldLayout.swift platforms/ios/Tests/FoldLayoutTests.swift -o /tmp/liana-ios-layout
/tmp/liana-ios-layout

# 先完成 simulator 构建，再替换设备名称运行真实键盘控制器的行为测试
xcodebuild -project platforms/ios/Liana.xcodeproj -scheme LianaKeyboardTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath platforms/ios/build CODE_SIGNING_ALLOWED=NO test

# 验证实际 App 进程的冷启动、重启与页面入口，不能用控制器单测代替
xcodebuild -project platforms/ios/Liana.xcodeproj -scheme LianaAppLaunchTests \
  -configuration Release -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' \
  -derivedDataPath platforms/ios/build CODE_SIGNING_ALLOWED=NO test
```

行为测试覆盖后台解码与快速连点、过期候选保留新输入、双拼／九宫格／五笔／手写／滑行、导入解析与匹配优先级、底部安全间距，以及候选选择、标点顺序、中英文切换、数字符号与大写、退格取消、宽度变化时保留组合串，以及布局调节/拖动/恢复、窄屏和深色模式、权限隔离、BLE 分包/去重/限长、预览确认插入；包含候选显示尺寸检查与截图附件。测试目标不会嵌入分发 IPA。
