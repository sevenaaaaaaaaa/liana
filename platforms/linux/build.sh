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

# 整句搭配模型：仓库里带一份跨平台共享的 base.lm（由 macOS 构建生成后签入）。
# 没有它整句不看上下文，实测整句 Top-1 从 64.2% 掉到 47.5%——这是各端准确率差的主因。
LM_OUT="$HERE/build/base.lm"
LM_SRC="$ROOT/crates/dict/data/lm/base.lm"
if [[ -f "$LM_SRC" ]] && { [[ ! -f "$LM_OUT" ]] || [[ "$LM_SRC" -nt "$LM_OUT" ]]; }; then
    mkdir -p "$HERE/build"
    cp "$LM_SRC" "$LM_OUT"
    echo "    搭配模型就位：$(du -h "$LM_OUT" | cut -f1)"
elif [[ -f "$LM_OUT" ]]; then
    echo "    搭配模型已是最新，跳过"
else
    echo "    ⚠️ 缺少 crates/dict/data/lm/base.lm，本次不带整句搭配模型"
fi

# 局域网对端 CLI：Ctrl+Alt+V 拉 Mac 剪贴板靠它（协议是 TLS-PSK，Python 说不了）
PEER_OUT="$HERE/build/liana-peer"
if [[ -x "$ROOT/tools/liana-peer/target/release/liana-peer" ]]; then
    cp "$ROOT/tools/liana-peer/target/release/liana-peer" "$PEER_OUT"
    echo "    局域网对端就位：$(du -h "$PEER_OUT" | cut -f1)"
elif command -v cargo >/dev/null 2>&1; then
    ( cd "$ROOT/tools/liana-peer" && cargo build --release >/dev/null 2>&1 ) \
        && cp "$ROOT/tools/liana-peer/target/release/liana-peer" "$PEER_OUT" \
        && echo "    已构建局域网对端" \
        || echo "    ⚠️ liana-peer 构建失败，Ctrl+Alt+V 暂不可用"
else
    echo "    ⚠️ 没有 cargo，也没有预构建的 liana-peer，Ctrl+Alt+V 暂不可用"
fi

echo "==> 3/3 引擎语法检查"
python3 -m py_compile "$HERE/ibus-liana" "$HERE/libliana.py"
echo "    Python 语法 OK"

if [[ "${1:-}" == "--local" ]]; then
    echo
    echo "构建完成（未安装）：$SO"
    exit 0
fi

echo "==> 安装（platforms/linux/install.sh，会打印启用步骤与自检结果）"
exec "$HERE/install.sh"
