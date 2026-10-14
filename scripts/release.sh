#!/usr/bin/env bash
# 松萝正式发版：只用于主版本 X.Y.0（紧急修复才发 X.Y.Z）。日常构建走 scripts/daily-release.sh（Nightly）。
#
# 用法：
#   scripts/release.sh 0.5.0              # 正式发版
#   scripts/release.sh 0.5.0 --dry-run    # 只校验前置条件 + CHANGELOG + 打印发版说明，不改任何东西
#
# 前提：CHANGELOG.md 已有对应小节——主版本 `## X.Y.0 — 日期 · 主题`，补丁 `### X.Y.Z — 日期  修复：…`
# （把 `## Unreleased` 的内容整理进去后再跑）。
#
# 流程：main + 干净 + 与 origin 同步 → cargo test → 版本写入所有位置（来源：Cargo.toml
# [workspace.package] version）→ 提交 `chore(release): vX.Y.Z` + 附注 tag → dist.sh 打 DMG 并校验
# → push main 与 tag（触发 CI release.yml 补 Android/Linux 产物）→ `gh release create --latest`
# （说明 = CHANGELOG 小节 + 安装指引 + sha256）。
# 中途失败可重跑：HEAD 已是 `chore(release): vX.Y.Z` 且 tag 在 HEAD 时跳过改版本，续跑后续步骤。
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRODUCT_BUNDLE_ID="dev.liana.inputmethod.ime"
LOG="$HOME/Library/Logs/liana-release.log"

VERSION=""; DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        v[0-9]*|[0-9]*) VERSION="${arg#v}" ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "用法：scripts/release.sh X.Y.0 [--dry-run]" >&2; exit 2; }
TAG="v$VERSION"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo; echo "════════ $(date '+%F %T') release $TAG $* ════════"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ──────────────────── 1. 前置条件 ────────────────────

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "正式发版只在 main 上进行"
[[ -z "$(git status --porcelain)" ]] || die "工作区不干净，请先提交或暂存"
git fetch --quiet --tags origin || die "git fetch 失败"
[[ "$(git rev-list --count HEAD..origin/main)" == 0 ]] || die "落后 origin/main，请先 pull"

CUR="$(sed -n -E '/^\[workspace\.package\]/,/^\[/ s/^version = "([^"]+)"/\1/p' Cargo.toml | head -1)"
IFS=. read -r NMAJ NMIN NPAT <<<"$VERSION"
if [[ "$NPAT" != 0 ]]; then
    warn "$TAG 是补丁版本：只应用于正式版的紧急修复"
fi

# Release notes come from the CHANGELOG section of this version (heading `## X.Y.Z` or `### X.Y.Z`).
changelog_section() {
    awk -v v="$VERSION" '
        BEGIN { esc = v; gsub(/\./, "\\.", esc) }
        $0 ~ "^##+ " esc "( |$)" { on = 1; lvl = match($0, /[^#]/) - 1; print; next }
        on && /^##+ / { l = match($0, /[^#]/) - 1; if (l <= lvl) exit }
        on { print }
    ' CHANGELOG.md
}
SECTION="$(changelog_section)"
[[ -n "$SECTION" ]] || die "CHANGELOG.md 里没有 $VERSION 小节（先把 Unreleased 整理成 \`## $VERSION — 日期 · 主题\`）"

RESUME=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    if [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" \
          && "$(git log -1 --format=%s)" == "chore(release): $TAG" ]]; then
        RESUME=1; log "HEAD 已是 $TAG 的发版提交：续跑"
    else
        die "tag $TAG 已存在但不在 HEAD——请人工检查"
    fi
fi

if [[ $DRY_RUN == 1 ]]; then
    log "DRY-RUN：当前版本 $CUR → ${TAG}（不改任何东西）"
    echo "──── 发版说明（CHANGELOG 小节）────"; echo "$SECTION"
    exit 0
fi

log "运行测试：cargo test"
cargo test --workspace --quiet || die "cargo test 未通过"

# ──────────────────── 2. 写版本号 + 提交 + tag ────────────────────

# Every place the project keeps a version string; the source of truth is Cargo.toml.
set_version() {
    local v="$1"
    sed -i '' -E '/^\[workspace\.package\]/,/^\[/ s/^version = "[^"]*"/version = "'"$v"'"/' Cargo.toml
    cargo update --workspace --offline --quiet
    # Text substitution (not PlistBuddy) keeps the hand-written plist formatting intact.
    V="$v" perl -0pi -e 's{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*}{$1$ENV{V}}' \
        platforms/macos/Info.plist platforms/macos/installer/Info.plist
    # Build number: one monotonically increasing counter shared by the IME and the installer.
    local build=0 b f
    for f in platforms/macos/Info.plist platforms/macos/installer/Info.plist; do
        b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$f" 2>/dev/null || echo 0)"
        [[ "$b" =~ ^[0-9]+$ ]] && (( b > build )) && build=$b
    done
    B="$((build + 1))" perl -0pi -e 's{(<key>CFBundleVersion</key>\s*<string>)[^<]*}{$1$ENV{B}}' \
        platforms/macos/Info.plist platforms/macos/installer/Info.plist
    local code
    code="$(sed -n -E 's/^ *versionCode = ([0-9]+).*/\1/p' platforms/android/app/build.gradle.kts)"
    sed -i '' -E "s/^( *)versionCode = [0-9]+/\1versionCode = $((code + 1))/; s/^( *)versionName = \"[^\"]*\"/\1versionName = \"$v\"/" \
        platforms/android/app/build.gradle.kts
    sed -i '' -E "s/(MARKETING_VERSION: ).*/\1$v/" platforms/ios/project.yml
}
VERSION_FILES=(Cargo.toml Cargo.lock platforms/macos/Info.plist platforms/macos/installer/Info.plist
               platforms/android/app/build.gradle.kts platforms/ios/project.yml)

if [[ $RESUME == 0 ]]; then
    log "写入版本号 $CUR → $VERSION"
    set_version "$VERSION"
    git add -- "${VERSION_FILES[@]}"
    git commit --quiet -m "chore(release): $TAG" || die "发版提交失败（pre-commit 检查未通过？）"
    git tag -a "$TAG" -m "$TAG" || die "打 tag 失败"
fi

# ──────────────────── 3. 构建 DMG ────────────────────

log "构建 + 打包 DMG（${VERSION}）"
LIANA_VERSION="$VERSION" BUNDLE_ID="$PRODUCT_BUNDLE_ID" platforms/macos/dist.sh || die "dist.sh 失败"
DMG="$(ls -t dist/Liana-"$VERSION"-*.dmg 2>/dev/null | head -1)"
[[ -f "$DMG" ]] || die "没有找到 dist/Liana-$VERSION-*.dmg"
DMG_SUM="$DMG.sha256"
[[ -f "$DMG_SUM" ]] || (cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG_SUM")")
MOUNT="$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
for entry in Liana.app Applications "打不开？双击我.command" "安装说明.txt"; do
    [[ -e "$MOUNT/$entry" ]] || { hdiutil detach "$MOUNT" -quiet; die "DMG 缺少：$entry"; }
done
hdiutil detach "$MOUNT" -quiet

# ──────────────────── 4. 推送 + GitHub Release ────────────────────

log "推送 main 与 $TAG"
git push --quiet origin main || die "push main 失败"
git push --quiet origin "$TAG" || die "push $TAG 失败"

NOTES="$(mktemp)"
{
    # Drop the version heading itself; the Release title carries it.
    echo "$SECTION" | sed '1d'
    echo
    cat .github/release-notes-template.md
    cat "$DMG_SUM"
    echo '```'
} > "$NOTES"
TITLE_THEME="$(head -1 <<<"$SECTION" | sed -n -E 's/^#+ [^·]*· *(.*)$/\1/p')"
TITLE="$TAG${TITLE_THEME:+ — $TITLE_THEME}"

# CI (release.yml) also builds on the tag push and only uploads assets missing from an existing release.
if gh release view "$TAG" >/dev/null 2>&1; then
    log "Release $TAG 已存在：更新说明并补传缺失产物"
    gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES" --latest || die "gh release edit 失败"
    existing="$(gh release view "$TAG" --json assets -q '.assets[].name')"
    for f in "$DMG" "$DMG_SUM"; do
        grep -qxF "$(basename "$f")" <<<"$existing" || gh release upload "$TAG" "$f" || die "上传 $f 失败"
    done
else
    gh release create "$TAG" --verify-tag --latest --title "$TITLE" --notes-file "$NOTES" "$DMG" "$DMG_SUM" \
        || die "gh release create 失败"
fi
rm -f "$NOTES"
log "完成：$(gh release view "$TAG" --json url -q .url 2>/dev/null || echo "$TAG")"
