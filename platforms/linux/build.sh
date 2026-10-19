#!/usr/bin/env bash
# Linux 构建 + 安装（在 Linux 机器上运行）
#
# 产物：
#   target/release/libliana_ffi.so   Rust 内核 cdylib
#   /usr/local/lib/liana/            安装目标（.so + 引擎脚本 + 词典）
#   /usr/share/ibus/component/liana.xml   ibus-daemon 组件声明
#
# 用法：
#   ./build.sh            # 构建并安装（需要 sudo）
#   ./build.sh --local    # 构建但不安装（CI / 语法检查）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> 1/3 构建 Rust 内核 cdylib"
cargo build --release -p liana-ffi
SO="$ROOT/target/release/libliana_ffi.so"
[[ -f "$SO" ]] || { echo "缺少 $SO" >&2; exit 1; }

echo "==> 2/3 生成词典（base.ifd，20 万词条）"
DICT_OUT="$HERE/build/base.ifd"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
# 基础词库或官方词包（同目录 packs/default，构建时自动合并）有变化就重建
if [[ ! -f "$DICT_OUT" || -n "$(find "$(dirname "$DICT_SRC")" -name "*.tsv" -newer "$DICT_OUT" -print -quit)" ]]; then
    mkdir -p "$HERE/build"
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
else
    echo "词典已是最新，跳过"
fi

echo "==> 3/3 引擎语法检查"
python3 -m py_compile "$HERE/ibus-liana" "$HERE/libliana.py"
echo "    Python 语法 OK"

if [[ "${1:-}" == "--local" ]]; then
    echo
    echo "构建完成（未安装）：$SO"
    exit 0
fi

echo "==> 安装到 /usr/local/lib/liana/"
sudo mkdir -p /usr/local/lib/liana
sudo cp "$SO" /usr/local/lib/liana/libliana_ffi.so
sudo cp "$HERE/ibus-liana" /usr/local/lib/liana/ibus-liana
sudo chmod +x /usr/local/lib/liana/ibus-liana
sudo cp "$HERE/build/base.ifd" /usr/local/lib/liana/base.ifd
# 引擎脚本以安装路径加载 .so（libliana.py 的候选路径表已含系统路径）
sudo mkdir -p /usr/local/lib/liana
sudo cp "$HERE/libliana.py" /usr/local/lib/liana/libliana.py
sudo cp "$HERE/liana.xml" /usr/share/ibus/component/liana.xml
sudo sed -i "s|exec>.*|exec>/usr/local/lib/liana/ibus-liana</exec|" \
    /usr/share/ibus/component/liana.xml 2>/dev/null || true

# 词典放用户数据目录（ibus 引擎以当前用户身份运行，写 ~/.local/share/liana）
mkdir -p "$HOME/.local/share/liana"
cp "$HERE/build/base.ifd" "$HOME/.local/share/liana/base.ifd"

echo
echo "安装完成。启用步骤："
echo "  1. 重启 ibus:  ibus restart"
echo "  2. ibus-setup → 输入法 → 添加 → 中文 → 松萝"
echo "  3. Win+Space 切换到「松萝」"