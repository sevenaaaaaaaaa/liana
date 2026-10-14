#!/usr/bin/env bash
# 构建 macOS 输入法（不依赖 Xcode 工程：Rust 静态库 + swiftc + 手工 bundle）
#
# 默认产出 Universal Binary（arm64 + x86_64），覆盖 Apple Silicon（M1–M6…）
# 与 Intel 芯片；部署目标 macOS 13.0，可运行于 macOS 13/14/15/26+。
# 单架构构建：UNIVERSAL=0 ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="Liana"
BUILD="$HERE/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"
BIN_DIR="$CONTENTS/MacOS"
DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
UNIVERSAL="${UNIVERSAL:-1}"
# 交叉目标不可用时自动降级为单架构（例如 Homebrew Rust 未装 x86_64 标准库）
if [[ "$UNIVERSAL" == "1" ]]; then
    X86_LIB="$(rustc --print target-libdir --target x86_64-apple-darwin 2>/dev/null || true)"
    if [[ -z "$X86_LIB" || ! -d "$X86_LIB" ]]; then
        echo "⚠ 缺少 x86_64-apple-darwin 标准库，退回单架构 $(uname -m)"
        UNIVERSAL=0
    fi
fi
# 签名身份：优先 CODESIGN_IDENTITY，其次自动选用钥匙串里的 Apple Development，最后退回 ad-hoc。
# macOS 26+ 只收录有效签名（Apple 签发、带 Team ID）的第三方输入法，ad-hoc 不会出现。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
# bundle id：默认产品 id；本机开发可覆盖（例如系统对旧 id 留下负面缓存时）
# 优先级：环境变量 BUNDLE_ID > platforms/macos/.bundle-id（已 gitignore）> 产品默认
if [[ -f "$HERE/.bundle-id" ]]; then
    BUNDLE_ID="${BUNDLE_ID:-$(tr -d '[:space:]' < "$HERE/.bundle-id")}"
else
    BUNDLE_ID="${BUNDLE_ID:-dev.liana.inputmethod.ime}"
fi

echo "==> 1/5 构建 Rust 内核静态库"
mkdir -p "$ROOT/target/release"
if [[ "$UNIVERSAL" == "1" ]]; then
    # 零 crates 依赖，两个 target 都能干净交叉编译
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p liana-ffi \
        --target aarch64-apple-darwin
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p liana-ffi \
        --target x86_64-apple-darwin
    lipo -create \
        "$ROOT/target/aarch64-apple-darwin/release/libliana_ffi.a" \
        "$ROOT/target/x86_64-apple-darwin/release/libliana_ffi.a" \
        -output "$ROOT/target/release/libliana_ffi.a"
else
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p liana-ffi
fi

echo "==> 2/5 编译 Swift 外壳（目标 macOS ${DEPLOY_TARGET}）"
rm -rf "$BUNDLE"
mkdir -p "$BIN_DIR" "$CONTENTS/Resources"
# 显式链接静态库（避免链接到同目录的 .dylib，保证 app 自包含可分发）
RUST_LIB="$ROOT/target/release/libliana_ffi.a"
[[ -f "$RUST_LIB" ]] || { echo "缺少 $RUST_LIB" >&2; exit 1; }

# swiftc 驱动不支持 -arch：逐架构编译出可执行文件，最后 lipo 合成 Universal
SWIFT_SOURCES=("$HERE/Sources/main.swift" "$HERE/Sources/Engine.swift" \
    "$HERE/Sources/CandidateWindow.swift" "$HERE/Sources/AppProfile.swift" \
    "$HERE/Sources/PetWindow.swift" "$HERE/Sources/EncryptedStore.swift" \
    "$HERE/Sources/ClipboardMonitor.swift" "$HERE/Sources/ClipboardWindow.swift" \
    "$HERE/Sources/AIModelStore.swift" "$HERE/Sources/BackupManager.swift" \
    "$HERE/Sources/SettingsWindow.swift" "$HERE/Sources/InputController.swift" \
    "$HERE/Sources/AppModeMemory.swift" "$HERE/Sources/Theme.swift" \
    "$HERE/Sources/PermissionCenter.swift" "$HERE/Sources/PetStats.swift" \
    "$HERE/Sources/FeedWindow.swift" \
    "$HERE/Sources/VRMPetView.swift" \
    "$HERE/Sources/PetWebView.swift" \
    "$HERE/Sources/Live2DPetView.swift" \
    "$HERE/Sources/PetRuntimeStore.swift" \
    "$HERE/Sources/PetCatalog.swift" \
    "$HERE/Sources/PetCatalogWindow.swift" \
    "$HERE/Sources/PetImporter.swift" \
    "$HERE/Sources/AvatarCreatorWindow.swift" \
    "$HERE/Sources/VoiceInput.swift" \
    "$HERE/Sources/TranslateClient.swift" \
    "$HERE/Sources/LianaUI.swift" \
    "$HERE/Sources/LianaActions.swift" \
    "$HERE/Sources/QuickPanel.swift" \
    "$HERE/Sources/SettingsCenter.swift")
if [[ "$UNIVERSAL" == "1" ]]; then
    SWIFT_ARCHS=(arm64 x86_64)
else
    SWIFT_ARCHS=("$(uname -m)")
fi
for arch in "${SWIFT_ARCHS[@]}"; do
    swiftc -O -wmo \
        -target "${arch}-apple-macos${DEPLOY_TARGET}" \
        -import-objc-header "$ROOT/crates/ffi/include/liana.h" \
        "$RUST_LIB" \
        -framework AppKit -framework InputMethodKit -framework Carbon -framework WebKit \
        -framework Speech -framework AVFoundation -framework Vision -framework SwiftUI \
        -o "$BIN_DIR/$APP.$arch" \
        "${SWIFT_SOURCES[@]}"
done
if [[ "${#SWIFT_ARCHS[@]}" -gt 1 ]]; then
    lipo -create "$BIN_DIR/$APP."{"${SWIFT_ARCHS[0]}","${SWIFT_ARCHS[1]}"} -output "$BIN_DIR/$APP"
    rm -f "$BIN_DIR/$APP."*
else
    mv "$BIN_DIR/$APP.${SWIFT_ARCHS[0]}" "$BIN_DIR/$APP"
fi

cp "$HERE/Info.plist" "$CONTENTS/Info.plist"
# Version override for nightly/formal release builds: patch only the build copy, never the source plist.
if [[ -n "${LIANA_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${LIANA_VERSION#v}" "$CONTENTS/Info.plist"
fi
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$HERE/assets/Liana.icns" "$CONTENTS/Resources/Liana.icns"
cp "$HERE/assets/LianaMenu.png" "$CONTENTS/Resources/LianaMenu.png"

# 形象目录（内置可下载条目）
cp "$HERE/assets/PetCatalog.json" "$CONTENTS/Resources/PetCatalog.json"

# VRM 桌宠运行时（three.js + three-vrm，本地离线）
rm -rf "$CONTENTS/Resources/PetRuntime"
cp -R "$HERE/assets/PetRuntime" "$CONTENTS/Resources/PetRuntime"

# 随包分发示例插件（皮肤/桌宠形象包），首次启动 seeding 到用户插件目录
mkdir -p "$CONTENTS/Resources/Plugins"
for d in "$ROOT"/examples/plugins/*/; do
    name="$(basename "$d")"
    case "$name" in
        pet-*|skin-*) cp -R "${d%/}" "$CONTENTS/Resources/Plugins/$name" ;;
    esac
done

# 覆盖 bundle id（默认与 Info.plist 一致；本机开发可用 BUNDLE_ID=... 规避系统负面缓存）
if [[ "$BUNDLE_ID" != "dev.liana.inputmethod.ime" ]]; then
    PB=/usr/libexec/PlistBuddy
    PL="$CONTENTS/Info.plist"
    "$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PL"
    "$PB" -c "Set :TISInputSourceID $BUNDLE_ID" "$PL"
    # IMK 强制约定：连接名必须是 <bundle-id>_Connection
    CONNECTION="${BUNDLE_ID}_Connection"
    "$PB" -c "Set :InputMethodConnectionName $CONNECTION" "$PL"
    "$PB" -c "Copy :ComponentInputModeDict:tsInputModeListKey:dev.liana.inputmethod.ime.zh :ComponentInputModeDict:tsInputModeListKey:${BUNDLE_ID}.zh" "$PL"
    "$PB" -c "Delete :ComponentInputModeDict:tsInputModeListKey:dev.liana.inputmethod.ime.zh" "$PL"
    "$PB" -c "Set :ComponentInputModeDict:tsInputModeListKey:${BUNDLE_ID}.zh:TISInputSourceID ${BUNDLE_ID}.zh" "$PL"
    "$PB" -c "Set :ComponentInputModeDict:tsVisibleInputModeOrderedArrayKey:0 ${BUNDLE_ID}.zh" "$PL"
    echo "    bundle id 覆盖为: $BUNDLE_ID"
fi

# 输入模式的本地化显示名：以模式的 TISInputSourceID 为 key 写入 InfoPlist.strings，
# 否则切换器/系统设置里会显示裸 bundle id（如 dev.liana.ime.zh），既长又难认。
MODE_ID="${BUNDLE_ID}.zh"
mkdir -p "$CONTENTS/Resources/zh-Hans.lproj" "$CONTENTS/Resources/Base.lproj"
write_strings() {
    local path="$1" name="$2"
    cat > "$path" <<EOF
"${MODE_ID}" = "${name}";
"CFBundleDisplayName" = "${name}";
"CFBundleName" = "${name}";
EOF
}
write_strings "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings" "松萝"
write_strings "$CONTENTS/Resources/Base.lproj/InfoPlist.strings" "松萝"

echo "==> 3/5 生成外部词典（base.ifd，20 万词条）"
DICT_OUT="$HERE/build/base.ifd"
DICT_SRC="$ROOT/crates/dict/data/base-large.tsv"
if [[ ! -f "$DICT_OUT" || "$DICT_SRC" -nt "$DICT_OUT" ]]; then
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
        dict build "$DICT_SRC" -o "$DICT_OUT"
else
    echo "词典已是最新，跳过（源文件未变）"
fi

echo "==> 4/5 构建图形安装器"
INSTALLER="$BUILD/松萝安装器.app"
INSTALLER_CONTENTS="$INSTALLER/Contents"
INSTALLER_BIN="$INSTALLER_CONTENTS/MacOS"
INSTALLER_RES="$INSTALLER_CONTENTS/Resources"
rm -rf "$INSTALLER"
mkdir -p "$INSTALLER_BIN" "$INSTALLER_RES"
swiftc -O -wmo -parse-as-library \
    -target "$(uname -m)-apple-macos${DEPLOY_TARGET}" \
    -framework AppKit -framework Carbon -framework SwiftUI \
    -o "$INSTALLER_BIN/LianaInstaller" \
    "$HERE/installer/Installer.swift"
cp "$HERE/installer/Info.plist" "$INSTALLER_CONTENTS/Info.plist"
if [[ -n "${LIANA_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${LIANA_VERSION#v}" "$INSTALLER_CONTENTS/Info.plist"
fi
printf 'APPL????' > "$INSTALLER_CONTENTS/PkgInfo"
cp "$HERE/assets/LianaInstaller.icns" "$INSTALLER_RES/LianaInstaller.icns"
cp "$HERE/assets/Liana.icns" "$INSTALLER_RES/Liana.icns"
# 把输入法本体与词库作为安装包内嵌资源
cp -R "$BUNDLE" "$INSTALLER_RES/Liana.app"
cp "$HERE/build/base.ifd" "$INSTALLER_RES/base.ifd"

echo "==> 5/5 签名"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    echo "    使用签名身份: $CODESIGN_IDENTITY"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$BUNDLE" >/dev/null 2>&1 \
        || echo "（签名失败，退化为 ad-hoc）"
    # --deep 不递归 Resources/ 下的内嵌 .app；漏签会让安装器装出未签名输入法，系统静默拒绝收录
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$INSTALLER_RES/Liana.app" >/dev/null 2>&1 \
        || echo "（内嵌输入法签名失败）"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$INSTALLER" >/dev/null 2>&1 \
        || echo "（安装器签名失败）"
else
    echo "    未找到有效签名身份，使用 ad-hoc（macOS 26+ 不会被系统收录）"
    codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 \
        || echo "（签名失败不影响本地安装）"
    codesign --force --deep --sign - "$INSTALLER_RES/Liana.app" >/dev/null 2>&1 \
        || echo "（内嵌输入法签名失败不影响本地使用）"
    codesign --force --deep --sign - "$INSTALLER" >/dev/null 2>&1 \
        || echo "（安装器签名失败不影响本地使用）"
fi
codesign -dv "$BUNDLE" 2>&1 | rg 'TeamIdentifier|Signature' | sed 's/^/    /' || true

echo
echo "完成: $BUNDLE"
echo "安装器: $INSTALLER"
echo "下一步: ./install.sh 或双击安装器"
