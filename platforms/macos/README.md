# Liana for macOS（M1）

InputMethodKit 外壳 + Rust 内核静态库；候选窗在 macOS 26+ 使用系统原生 Liquid Glass，
旧系统回退 `NSVisualEffectView`。**无网络代码**：既没有网络权限声明，也不链接任何网络库
（AI 模型下载是唯一例外，只在用户点击下载时建立 HTTPS 连接）。

## 构建与安装

```bash
./build.sh      # cargo 静态库 + swiftc + 手工 bundle + ad-hoc 签名 + 图形安装器
./install.sh    # 安装到 ~/Library/Input Methods，并准备数据目录
```

## 图形安装器

`build.sh` 会同时产出 `build/松萝安装器.app`（内嵌 Liana.app、base.ifd 与图标）：

- 侧栏三步向导：**安装位置**（用户级 / 系统级需管理员）→ **输入与隐私**（默认模式、
  简繁输出、剪切板、桌宠、按应用记忆、输入统计、标点策略）→ **安装与验证**
  （安装进度日志、收录状态实时检测、打开键盘设置、卸载）
- 配置写入 `dev.inputflow.inputmethod` 域（与输入法本体的 UserDefaults 一致）
- 打包 DMG 时把「松萝安装器.app」与说明一起放入即可

## 图标

- 源文件：`assets/icon/*.svg`（「光标抽芽」：文本光标是茎，长出卷须与两片叶——输入即生长）
- 生成：`python3 tools/make_icons.py` → `assets/Liana.icns`、`assets/LianaInstaller.icns`、菜单栏模板图 `assets/LianaMenu.png`、`docs/assets/logo.png`
- 已提交 icns，`build.sh` 直接复制进两个 bundle 的 `Contents/Resources`

## 签名与系统收录（重要）

macOS 26/27 的输入源扫描器会**拒绝 ad-hoc 签名**的第三方输入法（实测对照）：

| 实验 | 结果 |
|---|---|
| Developer ID 签名的鼠须管（TeamID 28HU5A7B46） | 安装后立即可被收录（无需注销） |
| 同一 bundle 重签为 ad-hoc | 完全不收录 |
| 本项目 ad-hoc 构建（用户目录 / 系统目录、重启后） | 完全不收录 |

市面上分发的 DMG 目前用 **Apple Development** 签名（可本机使用、不可公证）；未公证的包
会被 Gatekeeper 拦一次，DMG 里的「打不开？双击我.command」负责放行。想让用户双击即开、
不再需要放行，必须换成 **Developer ID** 签名并公证：把 `codesign --sign` 的身份换成
`"Developer ID Application: …"`（`dist.sh` 已按 `Developer ID → Apple Development → ad-hoc` 三级降级）。

`install.sh` 会调用输入法自带的注册命令（`--register-input-source`、`--enable-input-source`），
等价于 Squirrel 的安装流程；这些命令也可以单独手动执行：

```bash
BIN="$HOME/Library/Input Methods/Liana.app/Contents/MacOS/Liana"
"$BIN" --register-input-source   # 通知系统缓存重建
"$BIN" --enable-input-source     # 在输入法列表中启用
"$BIN" --select-input-source     # 立即切换为当前输入法
"$BIN" --input-source-status     # 查看启用/选中状态
```

首次启用（不需要注销/重启）：

1. 点右上角输入法图标（显示「拼」或「A」），选「松萝」；图标不在就按 `Control + 空格`；
2. 两者都没有时：系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → `+` → 中文（简体）→ **松萝**；
3. 想设为默认：把「松萝」拖到输入法列表第一行，并取消「自动切换到文稿的输入法」；
4. 列表里应该只有一条「松萝」。

装完跑一次自检，它会逐项检查副本是否唯一、注册是否双写、菜单是否只有一条、是否已启用：

```bash
"$BIN" --verify-install
```

只有自检里 TIS 一直收录不到时，才需要注销重登（系统对输入法注册有缓存）。

卸载：`./uninstall.sh`（默认保留本地数据、桌宠偏好与钥匙串密钥；`--purge` 全部删除）。

安装/启用的完整说明（含六端）见 [docs/INSTALL.md](../../docs/INSTALL.md)。

## 用法

| 按键 | 行为 |
|---|---|
| 字母 / `'` / `;` | 输入拼音（`;` 为微软双拼的 ing 键） |
| 空格 | 选第一个候选；无候选时不上屏 |
| 数字 `1`-`9` | 选词（配合翻页） |
| `←` `→` / `-` `=` / PageUp/PageDown | 候选翻页 |
| 回车 | 原样上屏当前编码 |
| Esc | 取消当前组合 |
| 单按左 Shift | 中/英切换（不影响正常大写输入） |
| 标点（未组合时） | 中文模式自动转全角；代码编辑器/终端按应用画像保持半角 |
| 中英混输 | 拼音里直接混英文：`hello`→直接出 `hello`；大写开头按英文意图处理 |
| 简拼 / 混拼 | 全拼模式只打几个字母：`nh`→你好、`bj`→北京、`wm`→我们、`nhao`→你好 |
| `u` 开头（全拼） | 符号输入：`u` 列出常用符号，`ujiantou`→→ ← ↑ ↓，`uduihao`→✓，`ueuro`→€ |
| 连按两下 `a`（浏览器） | 进入网址模式：按键直通系统，Esc / 回车退出 |
| 连按两下 `a`（聊天工具） | 进入表情模式（斗图）：空格选表情，拼音可过滤，Esc 退出 |
| 输入法菜单 | 切换 拼音 / 小鹤双拼 / 微软双拼 / 自然码 / English / 日本語 |
| 输入法菜单 | 桌宠模式（可拖动玻璃小猫，随输入状态切换表情） |
| 输入法菜单 | 剪切板历史（最近 8 条直接上屏；开启/关闭记录） |
| 输入法菜单 | 繁体输出（候选转繁体；学习与重排仍按简体，跨会话记住） |
| 输入法菜单 | 备份与恢复（加密包 / 明文包导出、合并或覆盖恢复） |
| 输入法菜单 | AI 增强…（内置统计模型状态、小模型下载/校验/启停） |

## 智能交互（无需配置）

- **应用感知**：前台 App 自动识别，代码编辑器/终端标点保持半角，聊天/浏览器用中文标点；
- **双 `a` 手势**：浏览器进入网址模式（字母、标点全部直通，不经过输入法），
  聊天工具进入表情模式（内置精选表情，`daku`→😭、`zan`→👍，空格上屏）；
- **桌宠模式**：菜单一键开关，位置记忆；输入时表情联动（发呆 🐱 / 思考 🙀 / 开心 😻）；
- **光标跟随**：候选窗优先用 `firstRect` 定位，屏幕边缘自动翻转，多屏跟随光标所在屏；
- **AI 辅助短语**：连续上屏自动沉淀成短语（无需手动短语表），下次打前几个字母即可整条补全。

## 用户数据（加密持久化）

- 用户词 + 上下词二元组 + 剪切板历史统一存
  `~/Library/Application Support/Liana/userdata.enc`（0600）；
- 密钥 256-bit 随机生成，存系统钥匙串（service `dev.inputflow.inputmethod`），
  钥匙串不可用时本次运行不落盘，绝不把密钥写到数据文件旁边；
- 格式：`IFUE` + 版本 + ChaCha20-Poly1305（头部作为 AAD），原子写入；
  文件损坏时隔离为 `userdata.enc.corrupt` 并按空数据继续；
- 剪切板历史**默认关闭**：跳过密码管理器标记的 Concealed/Transient 内容，
  上限 200 条 / 单条 100 KB，可一键清空；
- 校验：`grep -a` 搜索文件应无明文；`ls -l` 应为 `-rw-------`。

```bash
./uninstall.sh --purge   # 同时删除数据目录与钥匙串密钥
```

## 调试命令

```bash
BIN="$HOME/Library/Input Methods/Liana.app/Contents/MacOS/Liana"
"$BIN" --store-smoke       # 加密存储自检（临时文件，不触碰真实数据）
"$BIN" --backup-smoke      # 备份包自检（导出→加密→解密→导回，不弹窗）
"$BIN" --store-info        # 钥匙串可用性 + 已加载数据量
"$BIN" --clipboard-smoke   # 剪切板监控自检（真实路径，写入一条测试数据）
"$BIN" --ai-dump           # 模型目录 + 按内存推荐
"$BIN" --clipboard-window  # 直接打开剪切板历史窗
"$BIN" --pet-window        # 直接显示桌宠（并做一次开心动画）
"$BIN" --ai-settings       # 直接打开 AI 增强窗
```

## 本地 AI 增强

- **L0 统计模型**（默认开启）：用户词频 + 历史二元组重排，内存 < 1 MB，零下载；
- **L2 小模型**（默认关闭）：Gemma 3 / Qwen2.5 / Qwen3 / Whisper，按本机内存推荐；
  下载仅在你点击后发生，完成后做 sha256 校验，存放于
  `~/Library/Application Support/Liana/models/`，可一键删除；
- 神经模型推理运行时（llama.cpp / whisper.cpp）将在 M2 接入；
- 设计约束见 `docs/adr/0004-local-ai-optional-models.md`。

## 词典

- 内置主词库 20 万词条（单字 4.6 万 + 词语 15.4 万），rime-ice 导入 + 人工校准高频词，
  来源与许可见 `crates/dict/data/SOURCES.md`；
- 外部词典：`~/Library/Application Support/Liana/base.ifd`（install.sh 自动安装；重新登录或切换输入法后生效）；
- 从 Rime 词库导入（例如雾凇拼音）：

```bash
cd ../../
cargo run -p xtask -- dict import-rime ~/Downloads/pinyin.dict.yaml \
    -o /tmp/base.ifd --with-base
cp /tmp/base.ifd ~/Library/Application\ Support/Liana/base.ifd
```

## 开发说明

- `Sources/Engine.swift`：C ABI 封装 + JSON 解码（组合态、候选、AI 目录）；
- `installer/Installer.swift`：图形安装器（配置 / 安装 / 收录检测 / 卸载 / 签名诊断）；
- `Sources/InputController.swift`：按键翻译、预编辑串、模式菜单、Shift 切换、剪切板上屏、双 `a` 手势；
- `Sources/AppProfile.swift`：应用画像（代码/浏览器/聊天）与标点策略；
- `Sources/PetWindow.swift`：桌宠（状态表情、拖动、位置记忆）；
- `Sources/CandidateWindow.swift`：候选窗（NSGlassEffectView / NSVisualEffectView 回退）；
- `Sources/EncryptedStore.swift`：`userdata.enc` 容器（钥匙串密钥、ChaCha20-Poly1305、原子写）；
- `Sources/ClipboardMonitor.swift` / `ClipboardWindow.swift`：剪切板监控与历史窗；
- `Sources/AIModelStore.swift` / `SettingsWindow.swift`：模型下载/校验与 AI 增强窗；
- `Sources/BackupManager.swift`：备份导出/恢复（PBKDF2 派生密钥、ChaCha20-Poly1305 加密包）；
- 目标版本默认 `arm64-apple-macos13.0`，可用 `MACOSX_DEPLOYMENT_TARGET=14.0 ./build.sh` 覆盖；
  Intel 机器上脚本自动使用 `x86_64`（暂不产出 universal 包）。

## 已知限制（M1）

- 数字保持半角；emoji 未接入；
- 跨设备同步（用户词/剪切板）在 M3；
- 双拼键位表以 Rime 官方 schema 为准，仍建议对照输入验证（见 `crates/pinyin/src/scheme.rs` 注释）。
