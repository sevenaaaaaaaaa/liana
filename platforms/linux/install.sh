#!/usr/bin/env bash
# 松萝 IBus 引擎安装（需要 sudo）
#
# 被 build.sh 与发布 tarball 里的 install.sh 共用同一份逻辑：只在这里维护一次。
# 装完立刻自检：引擎是否被 ibus 列出、组件 xml 的 exec 是否指向真实文件、
# 当前用户词典是否就位；然后打印「怎么切过去」。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." 2>/dev/null && pwd || echo "$HERE")"
LIB_DIR="/usr/local/lib/liana"
COMPONENT_DIR="/usr/share/ibus/component"
ENGINE_BIN="$LIB_DIR/ibus-liana"

# 源文件：发布 tarball 里就在同目录，仓库里在 platforms/linux/ 或 target/release/
src() {
    for candidate in "$HERE/$1" "$HERE/build/$1" "$ROOT/target/release/$1"; do
        [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    done
    return 1
}
SO="$(src libliana_ffi.so || true)"
PY="$(src libliana.py || true)"
ENGINE="$(src ibus-liana || true)"
XML="$(src liana.xml || true)"
DICT="$(src base.ifd || true)"

for f in "$SO" "$PY" "$ENGINE" "$XML"; do
    [[ -f "$f" ]] || { echo "缺少构建产物: $f（先在仓库里跑 ./build.sh --local）" >&2; exit 1; }
done

# 依赖预检：ibus-liana 是 Python 脚本，硬依赖 PyGObject 与 IBus 1.0 typelib。
# 以前只在 py_compile 里过一遍语法，装完点引擎才炸（"No module named gi"），用户无从下手。
if ! python3 -c "import gi; gi.require_version('IBus','1.0'); from gi.repository import IBus" 2>/dev/null; then
    echo "缺少运行依赖：python3-gi（PyGObject）+ IBus 1.0 typelib" >&2
    echo "  Debian/Ubuntu: sudo apt install python3-gi gir1.2-ibus-1.0" >&2
    echo "  Fedora:        sudo dnf install python3-gobject ibus-libs" >&2
    echo "（先装依赖再重跑本脚本；否则引擎装上了也起不来）" >&2
    exit 1
fi

echo "==> 安装到 $LIB_DIR"
sudo mkdir -p "$LIB_DIR"
sudo cp "$SO" "$LIB_DIR/libliana_ffi.so"
sudo cp "$ENGINE" "$LIB_DIR/ibus-liana"
sudo chmod +x "$LIB_DIR/ibus-liana"
sudo cp "$PY" "$LIB_DIR/libliana.py"
if [[ -n "$DICT" ]]; then
    sudo cp "$DICT" "$LIB_DIR/base.ifd"
    # 引擎以当前用户身份运行：词典放用户目录，避免 /usr/local 只读时无法学习/更新
    mkdir -p "$HOME/.local/share/liana"
    cp "$DICT" "$HOME/.local/share/liana/base.ifd"
fi

sudo mkdir -p "$COMPONENT_DIR"
sudo cp "$XML" "$COMPONENT_DIR/liana.xml"
sudo sed -i "s|exec>.*|exec>$ENGINE_BIN</exec|" "$COMPONENT_DIR/liana.xml" 2>/dev/null || true

# 让 ibus 重新读取组件：不重启的话新引擎不会出现在 ibus-setup 里
if command -v ibus >/dev/null 2>&1; then
    ibus restart >/dev/null 2>&1 || true
fi

echo
echo "==> 自检"
ok=1
if command -v ibus >/dev/null 2>&1; then
    if ibus list-engine 2>/dev/null | grep -qi liana; then
        echo "✓ ibus 已列出松萝引擎"
    else
        echo "✗ ibus 未列出松萝引擎 —— 检查 $COMPONENT_DIR/liana.xml 的 exec 路径，再跑 ibus restart"
        ok=0
    fi
else
    echo "· 没找到 ibus 命令（可能不是 IBus 环境），跳过引擎检查"
fi
if [[ -x "$ENGINE_BIN" ]]; then
    echo "✓ 引擎可执行: $ENGINE_BIN"
else
    echo "✗ 引擎不可执行: $ENGINE_BIN"
    ok=0
fi
if grep -q "<exec>$ENGINE_BIN</exec>" "$COMPONENT_DIR/liana.xml" 2>/dev/null; then
    echo "✓ 组件声明指向真实路径"
else
    echo "✗ 组件声明的 exec 路径不对（应为 $ENGINE_BIN）"
    ok=0
fi
[[ -f "$HOME/.local/share/liana/base.ifd" ]] && echo "✓ 用户词典: $HOME/.local/share/liana/base.ifd"

cat <<EOF

启用（30 秒）：
  1. 已自动执行 ibus restart；若刚才失败，手动跑：ibus restart
  2. 打开 ibus-setup → 输入法 → 添加 → 中文 → 松萝
  3. Super + Space（或你设的切换键）切到「松萝」

自检不通过时的排查顺序：
  · ibus list-engine | grep -i liana        引擎有没有被列出
  · cat $COMPONENT_DIR/liana.xml            看 <exec> 是否为 $ENGINE_BIN
  · python3 $LIB_DIR/libliana.py            单独启动引擎看报错
EOF

[[ "$ok" == "1" ]] || exit 1
