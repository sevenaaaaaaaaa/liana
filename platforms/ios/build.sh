#!/usr/bin/env bash
# iPhone IPA (unsigned for the user's signing tool) or simulator build.
# Usage: ./build.sh [device|simulator|all] -- defaults to device.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
MODE="${1:-device}"
case "$MODE" in device|simulator|all) ;; *) echo 'Usage: ./build.sh [device|simulator|all]' >&2; exit 2 ;; esac
VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
mkdir -p "$HERE/libs" "$HERE/Resources" "$HERE/build" "$ROOT/dist"

# Bounded dictionary: full desktop dictionaries exceed the keyboard extension's memory budget.
python3 "$ROOT/tools/build_ios_dict.py" "$ROOT/crates/dict/data/base-large.tsv" "$HERE/build/mobile.tsv"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
    dict build "$HERE/build/mobile.tsv" -o "$HERE/Resources/base.ifd" --no-packs

if [[ "$MODE" == device || "$MODE" == all ]]; then
    echo '==> Building Rust for iPhone (arm64)'
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --manifest-path "$ROOT/Cargo.toml" \
        -p liana-ffi --no-default-features --target aarch64-apple-ios
    cp "$ROOT/target/aarch64-apple-ios/release/libliana_ffi.a" "$HERE/libs/libliana_ffi_device.a"
fi
if [[ "$MODE" == simulator || "$MODE" == all ]]; then
    if [[ "$(uname -m)" == arm64 ]]; then SIM_TARGET=aarch64-apple-ios-sim; SIM_ARCH=arm64
    else SIM_TARGET=x86_64-apple-ios; SIM_ARCH=x86_64; fi
    echo "==> Building Rust for Simulator ($SIM_ARCH)"
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --manifest-path "$ROOT/Cargo.toml" \
        -p liana-ffi --no-default-features --target "$SIM_TARGET"
    cp "$ROOT/target/$SIM_TARGET/release/libliana_ffi.a" "$HERE/libs/libliana_ffi_sim.a"
fi

cd "$HERE"
xcodegen generate
build_app() {
    local sdk="$1" destination="$2" arch="$3" log="$HERE/build/$1.log"
    if ! xcodebuild -project Liana.xcodeproj -scheme LianaApp -sdk "$sdk" \
        -destination "$destination" -configuration Release -derivedDataPath "$HERE/build" \
        ARCHS="$arch" ONLY_ACTIVE_ARCH=YES MARKETING_VERSION="$VERSION" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$log" 2>&1; then
        tail -70 "$log" >&2
        return 1
    fi
    tail -3 "$log"
}
if [[ "$MODE" == device || "$MODE" == all ]]; then
    build_app iphoneos 'generic/platform=iOS' arm64
    APP="$HERE/build/Build/Products/Release-iphoneos/LianaApp.app"
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
    IPA="$ROOT/dist/Liana-iOS-$VERSION-build$BUILD_NUMBER-unsigned.ipa"
    STAGE="$(mktemp -d "$HERE/build/ipa.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    mkdir -p "$STAGE/Payload"
    /usr/bin/ditto "$APP" "$STAGE/Payload/LianaApp.app"
    python3 "$HERE/validate_ipa.py" --app "$STAGE/Payload/LianaApp.app"
    /usr/bin/ditto -c -k --keepParent "$STAGE/Payload" "$IPA"
    python3 "$HERE/validate_ipa.py" "$IPA"
    (cd "$(dirname "$IPA")" && shasum -a 256 "$(basename "$IPA")") > "$IPA.sha256"
    echo "IPA: $IPA"
    echo 'Signing: unsigned device build; re-sign both the app and embedded keyboard extension with your installation tool.'
fi
if [[ "$MODE" == simulator || "$MODE" == all ]]; then
    build_app iphonesimulator 'generic/platform=iOS Simulator' "$SIM_ARCH"
    echo "Simulator: $HERE/build/Build/Products/Release-iphonesimulator/LianaApp.app"
fi
