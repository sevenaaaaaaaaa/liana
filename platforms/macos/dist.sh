#!/usr/bin/env bash
# 松萝发布打包一条龙：签名 → Hardened Runtime → 公证 → DMG → staple → 校验和
#
# 分级降级（证书决定能力，脚本绝不假装）：
#   Developer ID Application  → 完整流程：hardened + 公证 + staple，任何人下载 DMG 双击即用
#   Apple Development（免费） → 本机开发用：hardened 可公证但无 Developer ID，跳过公证并提示
#   ad-hoc                    → 仅本机调试：macOS 26+ 不收录，DMG 仅限自担风险者
#
# 一次性准备（付费开发者账号）：
#   xcrun notarytool store-credentials liana-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# 用法：
#   ./dist.sh                        # 完整流程（含构建）
#   ./dist.sh --skip-build           # 复用 build/ 里现成的产物（调签名/公证时反复试错用）
#   NOTARY_PROFILE=xx ./dist.sh      # 自定义 notarytool 凭据档案名
#   LIANA_VERSION=0.4.1 ./dist.sh    # 覆盖构建产物里的版本号（不改源文件；daily-release / 彩排用）
#
# DMG 内附 Gatekeeper 放行助手（模板在 packaging/macos/）：
#   打不开？双击我.command  去 quarantine →（签名坏才 ad-hoc 重签）→ 打开安装器
#   安装说明.txt            拖拽安装 + 放行步骤 + 等价终端命令
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/build"
ENTITLEMENTS="$HERE/Liana.entitlements"
OUT="$ROOT/dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-liana-notary}"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

APP="$BUILD/Liana.app"
INSTALLER="$BUILD/松萝安装器.app"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ──────────────────── 1/6 证书分级 ────────────────────

identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEV_ID="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$identities" | head -1)"
APP_DEV="$(sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' <<<"$identities" | head -1)"

if [[ -n "$DEV_ID" ]]; then
    IDENTITY="$DEV_ID"; TIER="devid"
    log "签名身份：Developer ID（完整分发流程）"
elif [[ -n "$APP_DEV" ]]; then
    IDENTITY="$APP_DEV"; TIER="appdev"
    warn "签名身份：Apple Development（免费）——可本机收录，无法公证分发"
else
    IDENTITY="-"; TIER="adhoc"
    warn "签名身份：ad-hoc——macOS 26+ 不会被系统收录，DMG 仅限本机调试"
fi

# ──────────────────── 2/6 构建 ────────────────────

if [[ "$SKIP_BUILD" != 1 ]]; then
    log "构建（Universal + 安装器）"
    CODESIGN_IDENTITY="$IDENTITY" "$HERE/build.sh"
else
    log "跳过构建（复用 $BUILD 现有产物）"
fi
[[ -d "$APP" ]] || die "缺少 ${APP}（先跑 build.sh 或去掉 --skip-build）"
[[ -d "$INSTALLER" ]] || warn "缺少图形安装器，DMG 将只含输入法 App"

# 版本号覆盖：只改构建产物（含安装器内嵌的输入法），随后统一重签
if [[ -n "${LIANA_VERSION:-}" ]]; then
    LIANA_VERSION="${LIANA_VERSION#v}"
    log "版本号覆盖为 ${LIANA_VERSION}（仅构建产物）"
    for plist in "$APP/Contents/Info.plist" \
                 "$INSTALLER/Contents/Info.plist" \
                 "$INSTALLER/Contents/Resources/Liana.app/Contents/Info.plist"; do
        [[ -f "$plist" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LIANA_VERSION" "$plist"
    done
fi

# ──────────────────── 3/6 Hardened Runtime 重签 ────────────────────

# Only Developer ID distribution needs a trusted timestamp for notarization.
# Development/ad-hoc previews cannot be notarized, so keep them buildable offline.
TIMESTAMP_ARGS=(--timestamp)
[[ "$TIER" == "devid" ]] || TIMESTAMP_ARGS=(--timestamp=none)

# 公证的硬性前提。build.sh 的签名不带 runtime 标志，这里按发布口径统一重签
# （内嵌所有框架/Helper 一并覆盖；deep 保持与 build.sh 的自包含承诺一致）。
log "重签（Hardened Runtime + entitlements）：Liana.app"
codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" \
    --deep "${TIMESTAMP_ARGS[@]}" "$APP" || die "重签 Liana.app 失败"
if [[ -d "$INSTALLER" ]]; then
    log "重签（Hardened Runtime + entitlements）：安装器"
    # --deep 不递归 Resources/ 下的内嵌 .app，先显式重签内嵌输入法再签外层
    if [[ -d "$INSTALLER/Contents/Resources/Liana.app" ]]; then
        codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" \
            --deep "${TIMESTAMP_ARGS[@]}" "$INSTALLER/Contents/Resources/Liana.app" || die "重签内嵌输入法失败"
    fi
    codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" \
        --deep "${TIMESTAMP_ARGS[@]}" "$INSTALLER" || die "重签安装器失败"
fi
codesign --verify --strict "$APP" || die "签名校验未通过"
echo "   $(codesign -dv "$APP" 2>&1 | grep -E 'TeamIdentifier|Signature' | tr '\n' ' ')"

# ──────────────────── 4/6 公证 + staple ────────────────────

notarize() {
    local path="$1" name
    name="$(basename "$path")"
    log "公证提交：$name"
    xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "公证失败：${name}（检查 notarytool 凭据：xcrun notarytool store-credentials $NOTARY_PROFILE …）"
    log "staple：$name"
    xcrun stapler staple "$path" || die "staple 失败：$name"
    xcrun stapler validate "$path" || die "staple 校验失败：$name"
}

NOTARIZED=0
# Developer ID present but no notarytool profile: skip notarization instead of failing midway.
if [[ "$TIER" == "devid" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    warn "未找到可用的 notarytool 凭据档案「${NOTARY_PROFILE}」，跳过公证（配置方法见脚本头注释）"
    TIER="devid-unnotarized"
fi
if [[ "$TIER" == "devid" ]]; then
    notarize "$APP"
    [[ -d "$INSTALLER" ]] && notarize "$INSTALLER"
    NOTARIZED=1
else
    warn "跳过公证：Developer ID 证书就位后重跑本脚本，DMG 才能达到「任何人双击即用」"
    [[ "$TIER" == "adhoc" ]] && warn "macOS 26+ 不收录 ad-hoc 输入法——这个包只能自测，不要分发"
fi

# ──────────────────── 5/6 DMG ────────────────────

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 1)"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Liana" 2>/dev/null | tr ' ' '-')"
[[ -n "$ARCHS" ]] || ARCHS="$(uname -m)"
case "$ARCHS" in
    *x86_64*arm64*|*arm64*x86_64*) SLUG="universal" ;;
    *) SLUG="$ARCHS" ;;
esac
DMG_NAME="Liana-${VERSION}-${SLUG}.dmg"
DMG="$OUT/$DMG_NAME"
mkdir -p "$OUT"

log "打包 DMG：$DMG_NAME"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
[[ -d "$INSTALLER" ]] && cp -R "$INSTALLER" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# 附上许可证与说明，分发页面省事
cp "$ROOT/LICENSE" "$STAGING/" 2>/dev/null || true
# Gatekeeper 放行助手：未公证的包下载后会被隔离，用户双击即可放行
HELPER_DIR="$ROOT/packaging/macos"
HELPER_CMD="打不开？双击我.command"
HELPER_TXT="安装说明.txt"
[[ -f "$HELPER_DIR/$HELPER_CMD" && -f "$HELPER_DIR/$HELPER_TXT" ]] || die "缺少放行助手模板：$HELPER_DIR"
cp "$HELPER_DIR/$HELPER_CMD" "$HELPER_DIR/$HELPER_TXT" "$STAGING/"
chmod 755 "$STAGING/$HELPER_CMD"
hdiutil create -volname "Liana $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" \
    >/dev/null || die "DMG 打包失败"

if [[ "$NOTARIZED" == 1 ]]; then
    notarize "$DMG"
else
    warn "DMG 未公证（见上）"
fi

# ──────────────────── 6/6 校验和与产物清单 ────────────────────

SUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "$SUM  $DMG_NAME" > "$OUT/${DMG_NAME}.sha256"

log "产物就绪：$OUT"
ls -lh "$OUT" | tail -n +2
echo
echo "  DMG:       $DMG_NAME"
echo "  SHA-256:   $SUM"
echo "  版本:      $VERSION ($BUILD_NUM)"
echo "  签名分级:  ${TIER}（${IDENTITY}）"
echo "  公证:      $([[ $NOTARIZED == 1 ]] && echo '✅ 已公证 + staple' || echo '❌ 未公证——分发前需 Developer ID')"
[[ "$TIER" == "adhoc" ]] && { echo; warn "ad-hoc 包请勿分发给他人"; }
exit 0
