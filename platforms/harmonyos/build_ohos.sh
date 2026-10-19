#!/usr/bin/env bash
# 鸿蒙构建：Rust 静态库（aarch64-unknown-linux-ohos）+ DevEco hvigor 打包
#
# 前置：
#   rustup target add aarch64-unknown-linux-ohos
#   OHOS_SDK=/path/to/ohos-sdk（DevEco Studio 自带，或 OpenHarmony SDK 下载）
#
# 用法：./build_ohos.sh            # 构建 Rust 库 + hvigor 组包（若有 SDK）
#       ./build_ohos.sh --rust-only # 只构建 Rust 静态库
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
OHOS_SDK="${OHOS_SDK:-}"
OHOS_NATIVELLVM="$OHOS_SDK/native/llvm/bin"

echo "==> 1/2 Rust 静态库（aarch64-unknown-linux-ohos）"
if [[ -d "$OHOS_NATIVELLVM" ]]; then
    # OHOS SDK 自带 llvm：rustc 需要它做链接器（构建 .a 本身不需要链接，
    # 但后续 NAPI .so 的链接在 hvigor/CMake 里也用同一套 clang）
    CC_aarch64_unknown_linux_ohos="$OHOS_NATIVELLVM/clang" \
    AR_aarch64_unknown_linux_ohos="$OHOS_NATIVELLVM/llvm-ar" \
    cargo build --release -p liana-ffi --target aarch64-unknown-linux-ohos
else
    # 纯静态库构建无需链接器；--crate-type staticlib 跳过 cdylib 链接
    cargo rustc --release -p liana-ffi --target aarch64-unknown-linux-ohos --crate-type staticlib
fi
mkdir -p "$HERE/entry/src/main/cpp/libs/arm64-v8a"
cp "$ROOT/target/aarch64-unknown-linux-ohos/release/libliana_ffi.a" \
   "$HERE/entry/src/main/cpp/libs/arm64-v8a/libliana_ffi.a"

echo "==> 2/2 词典（rawfile/base.ifd）"
DICT_OUT="$HERE/entry/src/main/resources/rawfile/base.ifd"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
# 基础词库或官方词包（同目录 packs/default，构建时自动合并）有变化就重建
if [[ ! -f "$DICT_OUT" || -n "$(find "$(dirname "$DICT_SRC")" -name "*.tsv" -newer "$DICT_OUT" -print -quit)" ]]; then
    mkdir -p "$(dirname "$DICT_OUT")"
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
fi

if [[ "${1:-}" == "--rust-only" || -z "$OHOS_SDK" ]]; then
    echo
    echo "Rust 静态库就绪：$HERE/entry/src/main/cpp/libs/arm64-v8a/"
    [[ "${1:-}" == "--rust-only" ]] && exit 0
    echo "未设 OHOS_SDK，跳过 hvigor 组包。在 DevEco Studio 里打开本目录或："
    echo "  OHOS_SDK=/path/to/ohos-sdk ./build_ohos.sh"
    exit 0
fi

echo "==> hvigor 组包（DevEco 命令行）"
HVIGOR="$OHOS_SDK/../tool/node/bin/node $HERE/hvigor/hvigor-wrapper.js"
$HVIGOR assembleHap --mode module -p product=default
echo "完成：entry/build/default/outputs/default/*.hap"