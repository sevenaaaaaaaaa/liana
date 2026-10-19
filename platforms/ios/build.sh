#!/usr/bin/env bash
# iOS 构建一条龙：Rust 静态库（真机 + 模拟器）→ 词典 → XcodeGen → xcodebuild
#
# 前置：rustup 目标 aarch64-apple-ios / aarch64-apple-ios-sim、Xcode、xcodegen(brew)
# 产物：build/Release-iphonesimulator/LianaApp.app（可拖进模拟器试）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
SCHEME="LianaApp"

echo "==> 1/4 Rust 静态库（device + simulator）"
cargo build --release -p liana-ffi --target aarch64-apple-ios
cargo build --release -p liana-ffi --target aarch64-apple-ios-sim
cargo build --release -p liana-ffi --target x86_64-apple-ios
mkdir -p "$HERE/libs"
cp "$ROOT/target/aarch64-apple-ios/release/libliana_ffi.a" "$HERE/libs/libliana_ffi_device.a"
# 模拟器库：arm64-sim + x86_64-sim 合并（generic 模拟器目标两个切片都要）
lipo -create \
    "$ROOT/target/aarch64-apple-ios-sim/release/libliana_ffi.a" \
    "$ROOT/target/x86_64-apple-ios/release/libliana_ffi.a" \
    -output "$HERE/libs/libliana_ffi_sim.a"

echo "==> 2/4 生成词典（Resources/base.ifd）"
DICT_OUT="$HERE/Resources/base.ifd"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
# 基础词库或官方词包（同目录 packs/default，构建时自动合并）有变化就重建
if [[ ! -f "$DICT_OUT" || -n "$(find "$(dirname "$DICT_SRC")" -name "*.tsv" -newer "$DICT_OUT" -print -quit)" ]]; then
    mkdir -p "$HERE/Resources"
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
else
    echo "词典已是最新，跳过"
fi

echo "==> 3/4 XcodeGen 生成工程"
cd "$HERE"
xcodegen generate

echo "==> 4/4 xcodebuild（iOS Simulator）"
xcodebuild -project Liana.xcodeproj -scheme "$SCHEME" \
    -destination "generic/platform=iOS Simulator" \
    -configuration Release -derivedDataPath "$HERE/build" build \
    | tail -3

APP="$HERE/build/Build/Products/Release-iphonesimulator/LianaApp.app"
[[ -d "$APP" ]] || { echo "未找到 $APP" >&2; exit 1; }
echo
echo "完成: $APP"
echo "试跑: xcrun simctl install booted \"$APP\" && xcrun simctl launch booted dev.liana.ime.ios"