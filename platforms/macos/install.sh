#!/usr/bin/env bash
# 安装到 ~/Library/Input Methods 并准备数据目录
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="Liana"
SRC="$HERE/build/$APP.app"
DEST_DIR="$HOME/Library/Input Methods"
DATA_DIR="$HOME/Library/Application Support/Liana"

if [[ ! -d "$SRC" ]]; then
    echo "未找到 ${SRC}，请先运行 ./build.sh" >&2
    exit 1
fi

mkdir -p "$DEST_DIR" "$DATA_DIR"
rm -rf "$DEST_DIR/$APP.app"
cp -R "$SRC" "$DEST_DIR/"

if [[ -f "$HERE/build/base.ifd" ]]; then
    cp "$HERE/build/base.ifd" "$DATA_DIR/base.ifd"
    echo "词典已安装: $DATA_DIR/base.ifd"
fi

killall "$APP" 2>/dev/null || true

# 注册并启用输入源（与 Squirrel 相同：由 app 自身调用 TIS API，无需注销）
BIN="$DEST_DIR/$APP.app/Contents/MacOS/$APP"
if [[ -x "$BIN" ]]; then
    "$BIN" --register-input-source || echo "（注册失败，注销重新登录后系统也会自动发现）"
    # 登记 .lianapet 文件类型：Finder 里双击形象包即由松萝导入
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST_DIR/$APP.app" 2>/dev/null || true
    "$BIN" --enable-input-source || true
    # 防止升级后旧注册残留导致 HIToolbox 与第三方表双写 → 菜单出现两个同名输入法
    "$BIN" --dedupe-input-source || true
fi

cat <<'EOF'
安装完成。

首次启用：
  系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → + → 中文（简体）→ 松萝
  （若列表里没有，注销并重新登录一次）

使用：
  - 直接输入拼音/双拼；空格选第一个候选，数字键 1-9 选词，← → 或 - = 翻页
  - 单按左 Shift 切换 中/英；Esc 取消；回车原样上屏
  - 输入法菜单（右上角）可切换 拼音/小鹤/微软/自然码/English/日本語
EOF
