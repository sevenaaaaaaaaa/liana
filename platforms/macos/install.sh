#!/usr/bin/env bash
# 安装到 ~/Library/Input Methods 并准备数据目录
#
# 首次安装最容易出的问题是「同一输入法装了两份」——~/Library 一份、/Library 一份，
# 系统会把两份各枚举一次，输入法菜单里就出现两条同名条目。所以这里先查副本、装完再自检。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="Liana"
SRC="$HERE/build/$APP.app"
DEST_DIR="$HOME/Library/Input Methods"
DATA_DIR="$HOME/Library/Application Support/Liana"
SYSTEM_APP="/Library/Input Methods/$APP.app"

if [[ ! -d "$SRC" ]]; then
    echo "未找到 ${SRC}，请先运行 ./build.sh" >&2
    exit 1
fi

# 1) 装之前先看有没有系统级副本：两份同 bundle id 会让菜单出现两条
if [[ -d "$SYSTEM_APP" ]]; then
    echo "✗ 检测到系统级副本：$SYSTEM_APP"
    echo "  同一输入法装两份（~/Library 与 /Library）会让输入法菜单出现两条「松萝」，"
    echo "  系统设置里还会报 duplicated input source。先删掉那份，再重跑本脚本："
    echo "      sudo rm -rf \"$SYSTEM_APP\""
    echo "  或使用图形安装器，在原安装位置升级。"
    exit 1
fi

# 在替换前检查签名与新副本，拷贝失败时仍保留当前安装。
/usr/bin/codesign --verify --deep --strict "$SRC"
mkdir -p "$DEST_DIR" "$DATA_DIR"
STAGING="$(mktemp -d "$HOME/Library/.liana-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$SRC" "$STAGING/$APP.app"
/usr/bin/codesign --verify --deep --strict "$STAGING/$APP.app"
killall "$APP" 2>/dev/null || true
if [[ -d "$DEST_DIR/$APP.app" ]]; then
    mv "$DEST_DIR/$APP.app" "$STAGING/previous.app"
fi
if ! mv "$STAGING/$APP.app" "$DEST_DIR/$APP.app"; then
    [[ ! -d "$STAGING/previous.app" ]] || mv "$STAGING/previous.app" "$DEST_DIR/$APP.app"
    exit 1
fi

if [[ -f "$HERE/build/base.ifd" ]]; then
    cp "$HERE/build/base.ifd" "$DATA_DIR/base.ifd"
    echo "词典已安装: $DATA_DIR/base.ifd"
fi
if [[ -f "$HERE/build/base.lm" ]]; then
    cp "$HERE/build/base.lm" "$DATA_DIR/base.lm"
    echo "整句搭配模型已安装: $DATA_DIR/base.lm"
fi

killall "$APP" 2>/dev/null || true

# 注册并启用输入源（与 Squirrel 相同：由 app 自身调用 TIS API，无需注销）
BIN="$DEST_DIR/$APP.app/Contents/MacOS/$APP"
if [[ -x "$BIN" ]]; then
    # 登记 .lianapet 文件类型：Finder 里双击形象包即由松萝导入
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST_DIR/$APP.app" 2>/dev/null || true
    "$BIN" --repair-input-source
    killall -u "$(id -un)" TextInputMenuAgent TextInputSwitcher 2>/dev/null || true

    # 2) 装完立刻自检：副本唯一、注册不双写、菜单只有一条、是否已启用
    echo
    if ! "$BIN" --verify-install-stable; then
        echo
        echo "⚠ 自检未通过：先按上面的提示修，再重跑本脚本。" >&2
        exit 1
    fi
else
    echo "⚠ 未找到可执行文件 $BIN，跳过注册" >&2
fi

cat <<EOF

首次启用（30 秒）：
  1. 点屏幕右上角的输入法图标（显示「拼」或「A」），在列表里选「松萝」
     —— 没有图标就按 Control + 空格 切换；两者都没有时：
     系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → + → 中文（简体）→ 松萝
  2. 想让它成为默认：把「松萝」拖到输入法列表第一行，
     并取消勾选「自动切换到文稿的输入法」（不取消的话每个 App 会记住各自的上一次选择）
  3. 列表里应该只有一条「松萝」。出现两条说明装了两份，跑下面这条看诊断：
     "$BIN" --verify-install

使用：
  - 直接输入拼音/双拼；空格选第一个候选，数字键 1-9 选词，← → 或 - = 翻页
  - 单按左 Shift 切换 中/英；Esc 取消；回车原样上屏
  - 输入法菜单（右上角）可切换 拼音/小鹤/微软/自然码/English/日本語
EOF
