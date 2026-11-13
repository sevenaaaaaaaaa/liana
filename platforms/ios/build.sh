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

# Dictionaries, two tiers:
#   core: ~100k entries + every single character + 简拼 priors + packs/default,
#         packed into base.ifd for the Rust session (bounded for the keyboard budget).
#   full: base-large + packs/default + packs/optional + packs/mobile extras,
#         packed into mobile.sqlite as the segmentation fallback index.
# merge_default_packs() reads packs/default next to the input TSV, so build in a
# scratch directory with a packs symlink instead of writing into crates/dict/data.
DICT_BUILD="$HERE/build/dict"
mkdir -p "$DICT_BUILD"
rm -f "$DICT_BUILD/mobile-core.tsv" "$DICT_BUILD/mobile-full.tsv" "$DICT_BUILD/packs"
ln -s "$ROOT/crates/dict/data/packs" "$DICT_BUILD/packs"
CORE_LIMIT="${LIANA_IOS_CORE_LIMIT:-100000}"
python3 "$ROOT/tools/build_ios_dict.py" "$ROOT/crates/dict/data/base-large.tsv" \
    "$DICT_BUILD/mobile-core.tsv" --limit "$CORE_LIMIT"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p xtask -- \
    dict build "$DICT_BUILD/mobile-core.tsv" -o "$HERE/Resources/base.ifd"

python3 "$ROOT/tools/build_ios_dict.py" "$ROOT/crates/dict/data/base-large.tsv" \
    "$DICT_BUILD/mobile-full.tsv" --all \
    --merge-dir "$ROOT/crates/dict/data/packs/default" \
    --merge-dir "$ROOT/crates/dict/data/packs/optional" \
    --merge-dir "$ROOT/crates/dict/data/packs/mobile"
python3 "$ROOT/tools/build_mobile_index.py" "$DICT_BUILD/mobile-full.tsv" \
    "$HERE/Vendor/Wubi86/wubi86.dict.yaml" "$ROOT/crates/en/data/words.txt" "$HERE/Resources/mobile.sqlite" \
    --tag "place=$ROOT/crates/dict/data/packs/default/places.tsv,$ROOT/crates/dict/data/packs/default/places-extra.tsv" \
    --tag "person=$ROOT/crates/dict/data/packs/default/names.tsv,$ROOT/crates/dict/data/packs/optional/people.tsv" \
    --person-surnames

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
    # Xcode 26+ stamps com.apple.provenance on executables; ditto turns any xattr into
    # AppleDouble (._*) entries, which pollute Payload and fail IPA validation.
    /usr/bin/xattr -cr "$STAGE/Payload"
    python3 "$HERE/validate_ipa.py" --app "$STAGE/Payload/LianaApp.app"
    /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGE/Payload" "$IPA"
    python3 "$HERE/validate_ipa.py" "$IPA"
    (cd "$(dirname "$IPA")" && shasum -a 256 "$(basename "$IPA")") > "$IPA.sha256"
    echo "IPA: $IPA"
    echo 'Signing: unsigned device build; re-sign both the app and embedded keyboard extension with your installation tool.'
fi
if [[ "$MODE" == simulator || "$MODE" == all ]]; then
    build_app iphonesimulator 'generic/platform=iOS Simulator' "$SIM_ARCH"
    echo "Simulator: $HERE/build/Build/Products/Release-iphonesimulator/LianaApp.app"
fi
