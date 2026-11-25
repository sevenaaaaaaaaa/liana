#!/usr/bin/env bash
# Android 原生层构建：Rust 静态库（cargo-ndk）+ NDK clang 编 JNI 垫片
#
# 产物：app/src/main/jniLibs/<abi>/libliana_jni.so（自包含，静态链接 liana-ffi）
# 不依赖 Android Studio / CMake 工程，与 macOS build.sh 同一哲学。
#
# 用法：./build_native.sh          # 三 ABI（arm64-v8a / armeabi-v7a / x86_64）
#       ABI=arm64-v8a ./build_native.sh   # 单 ABI
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$HOME/.cargo/bin:$PATH"

command -v cargo >/dev/null || { echo "找不到 cargo（rustup shim），请检查 PATH" >&2; exit 1; }
[[ -d "$SDK" ]] || { echo "找不到 Android SDK：请设 ANDROID_HOME 或确认 $SDK 存在" >&2; exit 1; }
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)}"
[[ -d "$NDK" ]] || { echo "找不到 NDK：$SDK/ndk/ 为空" >&2; exit 1; }
# 工具链目录名随宿主变：macOS 是 darwin-x86_64（Intel / Apple Silicon 同名），Linux 是 linux-x86_64。
# 写死 darwin-x86_64 会让 CI 的 ubuntu runner 直接找不到 clang——v0.11.0 的 android job 就是这么红的。
HOST_TAG="${NDK_HOST_TAG:-}"
if [[ -z "$HOST_TAG" ]]; then
  case "$(uname -s)" in
    Darwin) HOST_TAG=darwin-x86_64 ;;
    Linux)  HOST_TAG=linux-x86_64 ;;
    *)      HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" 2>/dev/null | head -1)" ;;
  esac
  # 兜底：按名字找不到就取 NDK 里实际存在的那个
  if [[ ! -x "$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/clang" ]]; then
    HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" 2>/dev/null | head -1)"
  fi
fi
NDK_TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CLANG="$NDK_TOOLCHAIN/clang"
[[ -x "$CLANG" ]] || { echo "找不到 NDK clang：$CLANG" >&2; exit 1; }

ABIS="${ABI:-arm64-v8a armeabi-v7a x86_64}"

echo "==> 0/2 生成词典（assets/base.ifd，20 万词条）"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
DICT_OUT="$HERE/app/src/main/assets/base.ifd"
# 基础词库或官方词包（同目录 packs/default，构建时自动合并）有变化就重建
if [[ ! -f "$DICT_OUT" || -n "$(find "$(dirname "$DICT_SRC")" -name "*.tsv" -newer "$DICT_OUT" -print -quit)" ]]; then
    mkdir -p "$(dirname "$DICT_OUT")"
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
else
    echo "词典已是最新，跳过"
fi

echo "==> 1/2 构建 Rust 静态库（NDK: $(basename "$NDK")）"
# cargo-ndk 只是把 NDK clang 塞进 cargo 的 env，不是必需品：
# 2026-11-24 就是卡在它（crates.io 索引拉取超时）导致 9 个符号的欠账。
# 没有它时直接按 target 指定 CC/AR/LINKER，产出一模一样。
if cargo ndk --version >/dev/null 2>&1; then
    cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 --platform 24 \
        -- build --release -p liana-ffi
else
    echo "    cargo-ndk 不可用，改用 NDK clang 直接交叉编译"
    for abi in $ABIS; do
        case "$abi" in
            arm64-v8a)   cargo_target=aarch64-linux-android;  cc_prefix=aarch64-linux-android24 ;;
            armeabi-v7a) cargo_target=armv7-linux-androideabi; cc_prefix=armv7a-linux-androideabi24 ;;
            x86_64)      cargo_target=x86_64-linux-android;   cc_prefix=x86_64-linux-android24 ;;
            *) echo "未知 ABI：$abi" >&2; exit 1 ;;
        esac
        env_upper="$(echo "$cargo_target" | tr 'a-z-' 'A-Z_')"
        env \
            "CC_$(echo "$cargo_target" | tr '-' '_')=$NDK_TOOLCHAIN/$cc_prefix-clang" \
            "AR_$(echo "$cargo_target" | tr '-' '_')=$NDK_TOOLCHAIN/llvm-ar" \
            "CARGO_TARGET_${env_upper}_LINKER=$NDK_TOOLCHAIN/$cc_prefix-clang" \
            cargo build --release -p liana-ffi --target "$cargo_target"
    done
fi

echo "==> 2/2 NDK clang 链接 JNI 垫片"
mkdir -p "$HERE/app/src/main/jniLibs"
for abi in $ABIS; do
    case "$abi" in
        arm64-v8a)    triple=aarch64-linux-android24;   cargo_target=aarch64-linux-android ;;
        armeabi-v7a)  triple=armv7a-linux-androideabi24; cargo_target=armv7-linux-androideabi ;;
        x86_64)       triple=x86_64-linux-android24;    cargo_target=x86_64-linux-android ;;
        *) echo "未知 ABI：$abi（支持 arm64-v8a / armeabi-v7a / x86_64）" >&2; exit 1 ;;
    esac
    static_lib="$ROOT/target/$cargo_target/release/libliana_ffi.a"
    [[ -f "$static_lib" ]] || { echo "缺少 $static_lib" >&2; exit 1; }
    out="$HERE/app/src/main/jniLibs/$abi/libliana_jni.so"
    mkdir -p "$(dirname "$out")"
    "$CLANG" -target "$triple" -O2 -fvisibility=hidden \
        -I "$ROOT/crates/ffi/include" \
        "$HERE/app/src/main/cpp/jni_shim.c" \
        "$static_lib" \
        -shared -o "$out" -ldl
    # 静态链接进垫片后，cargo-ndk 顺手拷来的裸 cdylib 不再需要
    rm -f "$HERE/app/src/main/jniLibs/$abi/libliana_ffi.so"
    echo "    $abi → $(du -h "$out" | cut -f1)"
done

echo
echo "完成：$HERE/app/src/main/jniLibs/"
echo "下一步：cd platforms/android && gradle assembleDebug"