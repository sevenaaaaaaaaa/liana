# iPhone → Mac 桌宠收件箱

此功能只传输用户主动选择的文件。它与词库、偏好和剪贴板同步独立；不会同步按键流。iPhone 与 Mac 都需要升级到包含此功能的松萝版本。

## 使用

1. Mac 右键桌宠，或在输入法菜单中选择「连接 iPhone／接收文件…」。打开即开始接收并显示二维码。
2. iPhone 打开松萝主 App →「连接 Mac 桌宠 · 发送文件」→ 扫描二维码。也可在 Mac 复制配对码，再在 iPhone 点「粘贴配对码」。首次连接需要在 Mac 点击允许配对。
3. 配对保存在本机钥匙串。之后打开 iPhone 的 Mac 页面可直接连接，选择文件发送。也可以在文件 App 的「打开方式」中选择松萝，再确认发送。
4. Mac 校验并保存后，iPhone 才显示送达，桌宠会提示收到文件。文件位于 `~/Downloads/松萝收件箱/`，接收窗口可直接打开此文件夹。

两端需在同一局域网，并允许本地网络访问。扫码需要 iPhone 相机权限，粘贴配对码可跳过相机授权。配对和选文件在主 App 完成，不要求键盘完全访问权限。

关闭 Mac 接收窗口仍继续接收；「停止接收」才关闭服务，并保留配对。接收开启状态会在输入法下次启动时恢复，首次使用默认关闭。「撤销全部配对并换码」会更换密钥，所有手机需要重新扫码，已收到的文件保留。

## 文件与连接

- 单文件上限 200MiB，一次发送一个普通文件；文件夹可先压缩。iPhone 进入后台或点取消会断开连接，没有断点续传。
- 每个文件使用独立编号，保留文件名并添加编号前缀，避免覆盖已有文件。接收文件不自动打开、不自动执行，收件箱不定期清理。
- 以分块方式传输，接收端按约定大小限长，并用 SHA-256 校验。只有完整校验并完成本地保存后才确认送达。中断文件会清理，不留作可打开的最终文件。
- 连接中断时，以 Mac 收件箱为准：保存后的确认消息若丢失，手机可能未显示送达；手动重发会产生另一份带编号的文件。
- 配对码包含随机密钥，相当于此 Mac 的连接凭证，只应交给自己的设备；撤销配对会使旧码失效。当前提供整批撤销，不提供逐设备密钥吊销。

## 实现与验证

Apple Network.framework 使用 Bonjour `_liana-pet._tcp` 发现服务，TLS 1.2 PSK + AES-128-GCM 认证与加密传输。256 位随机 PSK 留在两端钥匙串，二维码负责线下交换；不使用服务器、账号或证书信任绕过。Mac 首次额外确认发送设备，后续记住授权。

共享实现位于 `platforms/apple/`。每帧限长 70KiB，JSON 控制消息限长 8KiB，文件分块 64KiB；认证连接超时 20 秒，会话空闲超时 5 分钟，最多同时四个连接。文件选择与读取在 iPhone 主 App 内进行。

```bash
swiftc platforms/apple/PetLinkTransport.swift platforms/apple/PetLinkReceiver.swift \
  platforms/apple/PetLinkSender.swift platforms/apple/Tests/PetLinkTests.swift \
  -o /tmp/liana-petlink-tests
/tmp/liana-petlink-tests

# Mac 原生接收窗口构造、控件边界与配对码解码（需登录图形会话）
swiftc platforms/apple/PetLinkTransport.swift platforms/apple/PetLinkReceiver.swift \
  platforms/macos/Sources/PetLinkWindow.swift platforms/macos/tests/PetLinkWindowTests.swift \
  -o /tmp/liana-petlink-window-tests
/tmp/liana-petlink-window-tests
```

自动验证包含真实本机 TLS 传输、错误配对密钥拒绝、半传文件清理、记住首次授权、分块、校验与保存确认，以及无效配对码/文件名拒绝。iOS 模拟器验证键盘与配对页面。实体 iPhone 的相机、局域网发现及跨设备传输仍待实机验收。

## 按需文字剪贴板（iOS build 6 起）

两端升级后，在 Mac 收件箱勾选「允许已配对设备发送／读取文字剪贴板」（默认关闭）。iPhone 主 App 配对完成，再在移动输入工具复制配对到键盘；键盘工具面板接收后可发送当前文字剪贴板或接收 Mac 文字剪贴板。键盘需允许完全访问，首次会作为独立设备在 Mac 确认配对。

每次最多 4KB UTF-8 文字，使用原有 TLS-PSK 身份验证与独立请求确认，文件传输期间禁止交叉发送。接收后写入剪贴板，由用户粘贴；不监听剪贴板变化，不后台同步，不读取图片、历史或输入框上下文。文件传输本身不需要开启剪贴板选项。
