## 下载与安装

### macOS 13+（universal：Apple Silicon + Intel）
1. 下载 `Liana-*.dmg` 并打开
2. 把**松萝安装器**拖进 Applications，再双击 DMG 里的 **`打不开？双击我.command`**：
   它会去掉隔离标记并打开安装器（提示「已损坏 / 移到废纸篓」就是这个原因）。
   若 `.command` 本身被拦：**右键 → 打开**，或到 系统设置 → 隐私与安全性 → 点**仍要打开**
3. 安装器会装到「输入方法」并引导收录。等价终端命令：
   `xattr -dr com.apple.quarantine "/Applications/松萝安装器.app" && open "/Applications/松萝安装器.app"`
4. 系统设置 → 键盘 → 输入法（简体）→ **+** → **松萝**；列表没有就注销重登一次

> 安装包为 ad-hoc 签名、未经 Apple 公证（免费账号无公证资格），放行一次即可；
> 「任何人双击即用」需付费 Developer ID 证书。

### Android 7.0+
下载 `Liana-*-android.apk` 直接安装（允许「安装未知应用」）。
若从临时签名版本升级报「签名冲突」，卸载重装即可；配置固定签名见
`.github/workflows/release.yml` 头注释。

### Linux（x86_64 · ibus）
```bash
tar xzf liana-*-linux-x86_64.tar.gz
cd liana-*/
sudo ./install.sh          # 装到 /usr/local/lib/liana + ibus 组件声明
ibus restart               # ibus-setup → 输入法 → 添加 → 中文 → 松萝
```

### iOS 15+（未签名设备包）
下载 `Liana-iOS-*-unsigned.ipa`。它没有签名，需要用你自己的签名工具（Xcode、Sideloadly 等）
重签主 App **和** 内嵌的键盘扩展后安装；免费账号可用 7 天，开发者账号按证书有效期。

### Windows（x64 · 构建产物，骨架阶段）
下载 `liana-*-windows-x64.zip`，内含 `liana_tsf.dll`、`base.ifd` 与说明。
TSF 文本服务的注册表写入与候选窗还是 TODO，`regsvr32` 会失败，这个包只供开发联调，
还不能当输入法安装。

HarmonyOS 尚在骨架阶段，暂不提供构建产物（需要 DevEco Studio 与 ohos SDK）。

## 校验和（SHA-256）
```
