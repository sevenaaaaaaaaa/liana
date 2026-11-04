# 安装与首次启用（六端）

> 这份文档只讲一件事：**从下载到打出第一个字**要经过哪几步，以及每步最容易卡在哪。
> 平台现状以各小节开头的「状态」为准——只有 macOS 是日常可用端。

通用认知（六端都一样）：

- 输入法不是普通 App：装完还要在系统里**添加**它，再用快捷键**切换**过去。
- 装完看不到它，绝大多数情况不是装坏了，而是「还没添加」或「系统缓存没刷新」。
- 同一输入法**只能装一份**。装两份会让系统枚举两遍，输入法菜单出现两条同名条目（macOS 上
  还会让键盘设置里的条目变成几十上百个重复项）。Windows/Linux/macOS 都可能踩，见各端说明。

---

## macOS（日常可用）

**状态**：✅ 可用（v0.8.0）。签名 Apple Development，未公证，需要放行一次。

### 安装

有两种装法，**选一种就好**：

| 方式 | 装到哪 | 适合 |
|---|---|---|
| 松萝安装器（推荐） | `~/Library/Input Methods/Liana.app` | 普通用户；不需要管理员密码 |
| 安装器里勾「安装给所有用户」 | `/Library/Input Methods/Liana.app` | 多用户机器；需要管理员密码 |

> ⚠️ 两种装法**不要混用**。混用会在两处各留一份，输入法菜单出现两条「松萝」，
> 键盘设置里的条目也会乱。已经混装了怎么办：删掉 `/Library/Input Methods/Liana.app`
> （`sudo rm -rf`），保留用户目录那份；或者反过来，只留你自己装的那一份。

下载的 DMG 没公证，直接双击可能提示「已损坏，无法打开」——这不是文件坏了：

1. 把「松萝安装器」拖进「应用程序」。
2. 双击 DMG 里的「打不开？双击我.command」：它会去掉隔离标记并打开安装器
   （终端等价命令：`xattr -dr com.apple.quarantine "/Applications/松萝安装器.app"`）。
3. 安装器里选模式/是否开桌宠 → 安装 → 它会自己注册并启用。
   装完窗口里会显示三步启用指引；安装过程最后一步是**自检**，会告诉你
   副本是否唯一、注册是否双写、菜单里有几条。

### 启用（30 秒）

1. 点屏幕右上角输入法图标（显示「拼」或「A」），列表里选「松萝」。
   - 图标不在：按 `Control + 空格` 切；还不行就 系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → `+` → 中文（简体）→ 松萝。
2. 想设为默认：把「松萝」拖到列表第一行，并取消「**自动切换到文稿的输入法**」
   （不取消的话，每个 App 会记住它上一次用的输入法，切到别的 App 就变回英文）。
3. 列表里应该只有一条「松萝」。

### 自检与排错

```bash
"/Library/Input Methods/Liana.app/Contents/MacOS/Liana" --verify-install   # 或 ~/Library 下那份
```

它会逐项打印：安装副本数、注册表条目（HIToolbox / 第三方表）、菜单可见条数、
enabled/selectable、本地数据是否在，并给每条失败的下一步命令。常见结论：

| 症状 | 原因 | 处理 |
|---|---|---|
| 菜单两条「松萝」 | 装了两份（`~/Library` + `/Library`） | 删一份，再跑 `--dedupe-input-source` |
| 键盘设置里几百条输入法 | 其实是 macOS 自带「全部输入源」目录（253 键盘布局 + 各种输入法），不是你装了这么多；重复的是同名那条 | 同上，先保证只有一份 |
| 列表里没有松萝 | 系统还没收录 | 注销重登一次；仍没有检查签名：`codesign -dv <app>` |
| 切过去打字没反应 | 未选中/输入法被系统切换 | 看 `--input-source-status`，或菜单重新选一次 |

### 卸载

```bash
./platforms/macos/uninstall.sh            # 保留本地数据、桌宠偏好、钥匙串密钥
./platforms/macos/uninstall.sh --purge    # 连数据一起删
```

装过系统级副本时脚本会提示你手动 `sudo rm -rf /Library/Input Methods/Liana.app`。

---

## Linux（IBus）

**状态**：🟡 可构建、可安装，处于联调阶段。

```bash
./platforms/linux/build.sh          # 构建 + 安装（需要 sudo）
# 或解包发布 tarball 后：sudo ./install.sh
```

装完启用：

1. `ibus restart`（不重启 ibus 不会看到新引擎；改完之后 `install.sh` 会自动跑一次）
2. `ibus-setup` → 输入法 → 添加 → 中文 → 松萝
3. `Super + Space` 切过去

依赖：`ibus-liana` 是 Python 脚本，硬依赖 `python3-gi`（PyGObject）与 IBus 1.0 typelib。
Debian/Ubuntu：`sudo apt install python3-gi gir1.2-ibus-1.0`；Fedora：`sudo dnf install python3-gobject ibus-libs`。
缺依赖时引擎起不来，`install.sh` 会在自检里报出来。

自检：`ibus list-engine | grep -i liana` 应能看到引擎；没有则看
`/usr/share/ibus/component/liana.xml` 里的 `exec` 路径是否指向 `/usr/local/lib/liana/ibus-liana`。

---

## Windows（TSF）

**状态**：🔴 构建/联调阶段。COM 骨架、按键 sink、组合文本上屏与 TIP 注册仍是 TODO，
**尚不能在 Windows 上日常使用**。本仓库不发布 Windows 安装包。

开发者构建（在 Windows 上）：`cd platforms\windows && build.cmd`。脚本只保证「能编出
`build\liana_tsf.dll`」；现在还不能注册成输入法——`DllRegisterServer` 返回 `E_NOTIMPL`，
DLL 也还没有导出表，所以 `regsvr32` 必然失败。验证导出：`dumpbin /exports build\liana_tsf.dll`。

将来开放时的目标体验（写在这里，避免实现时偏离）：

1. 提供 `.exe` 安装包，装到 `%ProgramFiles%\Liana`，注册 TSF TIP；
2. 安装完成页直接给出「Win + 空格 → 松萝」的指引；
3. 卸载时清理 TIP 注册与数据目录，默认保留用户词。

---

## Android

**状态**：🟡 可构建 APK，处于联调阶段。

启用步骤（Android 的输入法必须手动启用，这是系统强制流程；应用**无法**替用户完成）：

1. 安装 APK（构建见 `platforms/android/`）。
2. **打开「松萝输入法」应用**（桌面上的图标）——它会显示当前是否已启用，并给你两个按钮：
   - 「① 打开键盘设置」→ 系统设置 → 系统 → 语言和输入法 → 屏幕键盘 → **启用「松萝」**
     （Android 12+ 在「管理屏幕键盘」里；会弹一个「输入法可以收集你输入的内容」的系统提示，确认即可）；
   - 「② 选择输入法」→ 在弹出的选择器里选「松萝」。
3. 回到应用，状态应变为「✓ 已启用」。
4. 切不回来时：键盘底部的切换键，或长按空格。

也可以用 adb 一步到位（开发者）：

```bash
adb shell ime enable dev.liana.ime/.LianaImeService
adb shell ime set    dev.liana.ime/.LianaImeService
```

> Android 上「启用了但列表里没有」几乎都是第 2 步没做——只装了 APK 不等于启用了输入法。
> 键盘设置里点「设置」也会打开这个引导页（`method.xml` 的 `settingsActivity` 指向它）。

---

## iOS

**状态**：🟡 键盘扩展可构建，处于联调阶段（需真机 + 开发者证书）。

启用步骤：

1. 装 App → 打开一次 App 完成初始化。
2. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选「松萝」。
3. **再点一次「松萝」→ 打开「允许完全访问」**（不开的话输入法无法保存词库、无法学习）。
4. 打字时长按地球键切换。

---

## HarmonyOS

**状态**：🔴 构建/联调阶段，无可用安装包。

---

## 给贡献者：改安装流程时要守的规矩

1. **一个输入法只装一份**：安装脚本/安装器必须检查另一处（`/Library` vs `~/Library`、
   系统级 vs 用户级）是否已有同 bundle id 的副本，有就删掉或明确报错停下，
   不允许两份并存。
2. **安装结束必须自检**：`--verify-install` 这类命令要能被脚本与 GUI 复用，
   检查「副本唯一 / 注册不双写 / 菜单一条 / 已启用」，失败时给出可复制的修复命令。
3. **装完要告诉用户怎么切过去**：至少覆盖「右上角菜单」「快捷键」「系统设置路径」三条路。
4. **卸载默认保留数据**：用户词、桌宠偏好、钥匙串密钥只有用户显式 `--purge` 才删。
5. 改名/bundle id 变更属于禁区，见 `CLAUDE.md`「改名禁区」——换 id 等于换一个输入法，
   旧注册与旧偏好都要迁移，否则就是本文档开头说的「两条同名条目」。
