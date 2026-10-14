#!/usr/bin/env bash
# 松萝每日构建（Nightly）：同步 → 测试 → 有新提交才构建 → 打 macOS DMG（含放行助手）
#                        → 移动 `nightly` tag → 更新唯一的 GitHub 预发布「Nightly」→ 更新本机输入法
#
# 版本号规则：版本唯一来源是 Cargo.toml 的 [workspace.package] version（正式版，如 0.4.2）。
# Nightly 版本 = 下一个 minor + 预发布后缀，例如 0.5.0-nightly.20261014（semver：高于所有 0.4.x，
# 低于下一个正式版 0.5.0）。该版本号只注入构建产物，绝不写回源文件、绝不提交。
# 正式版（X.Y.0，紧急修复才发 X.Y.Z）用 scripts/release.sh。
#
# 用法：
#   scripts/daily-release.sh              # 完整 nightly
#   scripts/daily-release.sh --dry-run    # 只构建 + 打包 + 校验 DMG；不动 tag/不推送/不发布/不安装
#   scripts/daily-release.sh --no-install # 发布 nightly 但不更新本机输入法
#   scripts/daily-release.sh --force      # nightly 已指向 HEAD 也重新构建发布
#
# 设计约束：可由 launchd 无人值守运行——不交互；只有真失败才非零退出；工作区不干净时
# 打印原因后 exit 0（skipped），绝不替用户提交未完成的改动。
# 结果标记：最后一行固定为 `RESULT: built nightly <版本> <短 sha>` / `RESULT: skipped <原因>` /
# `RESULT: failed <原因>`，供 ~/.local/bin/daily-release-all.sh 判定。
# 中途失败可直接重跑：只有 Release 上已有本次 HEAD 的 DMG 才算完成，否则重新构建发布。
# 日志：~/Library/Logs/liana-daily-release.log
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Liana"
PRODUCT_BUNDLE_ID="dev.liana.inputmethod.ime"
INSTALL_DIR="$HOME/Library/Input Methods"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
HELPER_CMD="打不开？双击我.command"
HELPER_TXT="安装说明.txt"
LOG="$HOME/Library/Logs/liana-daily-release.log"
NIGHTLY_TAG="nightly"

DRY_RUN=0; NO_INSTALL=0; FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=1 ;;
        --no-install) NO_INSTALL=1 ;;
        --force)      FORCE=1 ;;
        -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知参数：${arg}（可用：--dry-run --no-install --force）" >&2
           echo "RESULT: failed bad argument ${arg}"; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo
echo "════════ $(date '+%F %T') daily-release (nightly) $* ════════"

RESULT_DONE=0
result() { RESULT_DONE=1; echo "RESULT: $*"; }
log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; result "failed $*"; exit 1; }
skip() { printf '\033[1;33m— skipped: %s\033[0m\n' "$*"; result "skipped $*"; exit 0; }

# Single-instance lock (launchd + manual run must not overlap).
LOCK="${TMPDIR:-/tmp}/liana-daily-release.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "已有一个 daily-release 在运行（锁：${LOCK}）" >&2
    echo "RESULT: failed another daily-release is running"
    exit 1
fi
MOUNT=""
cleanup() {
    local rc=$?
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    # Any unexpected exit (set -e, signal) still ends with a RESULT marker.
    if [[ $RESULT_DONE == 0 ]]; then
        echo "RESULT: failed unexpected exit (rc=${rc}), see ${LOG}"
        exit 1
    fi
}
trap cleanup EXIT

START=$(date +%s)
[[ $DRY_RUN == 1 ]] && log "DRY-RUN：只构建与打包，不动 tag/不推送/不发布/不安装"

# ──────────────────── 1. 前置条件 ────────────────────

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    [[ $DRY_RUN == 1 ]] && warn "当前分支是 ${BRANCH}（nightly 要求 main）" || die "当前分支是 ${BRANCH}，nightly 只在 main 上构建"
fi

DIRTY="$(git status --porcelain)"
if [[ -n "$DIRTY" ]]; then
    echo "工作区有未提交改动："
    echo "$DIRTY" | sed 's/^/    /'
    [[ $DRY_RUN == 1 ]] && warn "DRY-RUN 继续（产物包含这些未提交改动）" \
        || skip "dirty working tree (commit or stash first; WIP is never auto-committed)"
fi

log "同步 origin"
if ! git fetch --quiet --tags --force origin; then
    [[ $DRY_RUN == 1 ]] && warn "git fetch 失败（DRY-RUN 用本地已有的 origin/main 继续）" || die "git fetch failed"
fi
BEHIND="$(git rev-list --count HEAD..origin/main)"
if [[ "$BEHIND" -gt 0 ]]; then
    if [[ $DRY_RUN == 1 ]]; then
        warn "落后 origin/main $BEHIND 个提交（DRY-RUN 不拉取）"
    else
        log "落后 $BEHIND 个提交，rebase 拉取"
        if ! git pull --rebase --autostash --quiet origin main; then
            git rebase --abort 2>/dev/null || true
            die "pull conflict (rebase aborted, nothing forced) — resolve manually"
        fi
    fi
fi
AHEAD="$(git rev-list --count origin/main..HEAD)"
[[ "$AHEAD" -gt 0 && $DRY_RUN == 0 ]] && skip "main is ${AHEAD} commit(s) ahead of origin/main — push main first (nightly never pushes main)"

# ──────────────────── 2. 版本号与是否需要构建 ────────────────────

BASE_VERSION="$(sed -n -E '/^\[workspace\.package\]/,/^\[/ s/^version = "([^"]+)"/\1/p' Cargo.toml | head -1)"
[[ "$BASE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "cannot read workspace version from Cargo.toml"
DATE_TAG="$(date +%Y%m%d)"
DATE_TITLE="$(date +%F)"
VERSION="${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1)).0-nightly.$DATE_TAG"
HEAD_SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short HEAD)"
LAST_FORMAL="$(git tag -l 'v*' --sort=-v:refname | head -1)"

# Already published for this HEAD? (nightly tag at HEAD *and* the release carries this build's DMG)
nightly_published() {
    local tag_sha assets body
    tag_sha="$(git rev-parse -q --verify "refs/tags/$NIGHTLY_TAG^{commit}" 2>/dev/null || true)"
    [[ "$tag_sha" == "$HEAD_SHA" ]] || return 1
    body="$(gh release view "$NIGHTLY_TAG" --json body -q .body 2>/dev/null)" || return 1
    grep -qF "构建提交：\`$SHORT_SHA\`" <<<"$body" || return 1
    assets="$(gh release view "$NIGHTLY_TAG" --json assets -q '.assets[].name' 2>/dev/null)" || return 1
    grep -qE "^Liana-.*-nightly\..*\.dmg$" <<<"$assets"
}

if [[ $FORCE == 0 ]]; then
    if [[ $DRY_RUN == 0 ]] && nightly_published; then
        skip "no new commits since last nightly ($SHORT_SHA)"
    fi
    if [[ $DRY_RUN == 1 && "$(git rev-parse -q --verify "refs/tags/$NIGHTLY_TAG^{commit}" 2>/dev/null)" == "$HEAD_SHA" ]]; then
        warn "nightly 已指向 HEAD（正式运行会跳过；DRY-RUN 继续）"
    fi
fi
log "Nightly ${VERSION}（基于正式版本 ${BASE_VERSION}，提交 ${SHORT_SHA}，上个正式版 ${LAST_FORMAL:-无}）"

log "运行测试：cargo test"
cargo test --workspace --quiet || die "cargo test failed"

# ──────────────────── 3. 构建 macOS DMG ────────────────────

# LIANA_VERSION is applied to the build copies only (build.sh + dist.sh patch the bundled
# Info.plists); source files stay untouched, CFBundleVersion keeps the numeric source value.
BUILD_START=$(date +%s)
log "构建 + 打包 DMG（产品 bundle id，版本 ${VERSION}）"
rm -f dist/Liana-*-nightly.*.dmg dist/Liana-*-nightly.*.dmg.sha256
LIANA_VERSION="$VERSION" BUNDLE_ID="$PRODUCT_BUNDLE_ID" platforms/macos/dist.sh || die "dist.sh failed"
BUILD_SECS=$(( $(date +%s) - BUILD_START ))
[[ -z "$(git status --porcelain)" || $DRY_RUN == 1 ]] || die "build modified tracked files — refusing to publish"

DMG="$(ls -t dist/Liana-"$VERSION"-*.dmg 2>/dev/null | head -1)"
[[ -f "$DMG" ]] || die "dist/Liana-$VERSION-*.dmg not found"
DMG_SUM="$DMG.sha256"
[[ -f "$DMG_SUM" ]] || (cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG_SUM")")

log "校验 DMG 内容"
MOUNT="$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[[ -d "$MOUNT" ]] || die "DMG mount failed"
for entry in "$APP_NAME.app" Applications "$HELPER_CMD" "$HELPER_TXT"; do
    [[ -e "$MOUNT/$entry" ]] || die "DMG missing: $entry"
done
[[ -x "$MOUNT/$HELPER_CMD" ]] || die "DMG helper $HELPER_CMD is not executable"
DMG_VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$MOUNT/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo '?')"
[[ "$DMG_VER" == "$VERSION" ]] || die "DMG app version is $DMG_VER, expected $VERSION"
ls -la "$MOUNT" | tail -n +2 | sed 's/^/    /'
hdiutil detach "$MOUNT" -quiet && MOUNT=""
echo "    ✓ 4 项必需内容齐全，助手可执行，版本 $DMG_VER"

if [[ $DRY_RUN == 1 ]]; then
    echo
    log "DRY-RUN 完成（$(( $(date +%s) - START ))s，其中构建 ${BUILD_SECS}s）"
    echo "  Nightly 版本: $VERSION"
    echo "  DMG:          ${DMG}（$(du -h "$DMG" | cut -f1)）"
    echo "  日志:         $LOG"
    result "skipped dry-run (built $VERSION $SHORT_SHA, not published)"
    exit 0
fi

# ──────────────────── 4. 移动 nightly tag + 更新 Nightly 预发布 ────────────────────

# The `nightly` tag does not match CI's `v*` trigger (.github/workflows/release.yml), so CI stays idle.
log "移动 tag $NIGHTLY_TAG → $SHORT_SHA"
git tag -f -a "$NIGHTLY_TAG" -m "Nightly $VERSION" HEAD >/dev/null || die "git tag nightly failed"
git push --quiet --force origin "refs/tags/$NIGHTLY_TAG" || die "push nightly tag failed"

NOTES="$(mktemp)"
{
    echo "> 每日自动构建，未经完整验证，可能不稳定。正式版请看标记为 **Latest** 的 Release。"
    echo
    echo "版本：\`$VERSION\` · 构建提交：\`$SHORT_SHA\` · 构建日期：$DATE_TITLE"
    echo
    echo "## 自 ${LAST_FORMAL:-首个提交} 以来的改动"
    git log --no-merges --format='- %s' "${LAST_FORMAL:+$LAST_FORMAL..}HEAD" 2>/dev/null \
        | grep -v -E '^- chore\(release\)' || echo "- （无）"
    echo
    # Nightly ships the macOS DMG only: keep the macOS part of the install footer.
    awk '/^### Android/{exit} {print}' .github/release-notes-template.md
    echo "## 校验和（SHA-256）"
    echo '```'
    cat "$DMG_SUM"
    echo '```'
} > "$NOTES"

TITLE="Nightly · $DATE_TITLE"
if gh release view "$NIGHTLY_TAG" >/dev/null 2>&1; then
    log "更新 Release $NIGHTLY_TAG"
    gh release edit "$NIGHTLY_TAG" --title "$TITLE" --notes-file "$NOTES" --prerelease --latest=false \
        || die "gh release edit nightly failed"
    # Drop older nightly assets (names carry the date), then upload this build.
    keep="$(basename "$DMG")|$(basename "$DMG_SUM")"
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        [[ "|$keep|" == *"|$a|"* ]] && continue
        gh release delete-asset "$NIGHTLY_TAG" "$a" --yes >/dev/null 2>&1 || warn "删除旧资产 $a 失败"
    done < <(gh release view "$NIGHTLY_TAG" --json assets -q '.assets[].name')
    gh release upload "$NIGHTLY_TAG" "$DMG" "$DMG_SUM" --clobber || die "upload nightly assets failed"
else
    log "创建 Release $NIGHTLY_TAG"
    gh release create "$NIGHTLY_TAG" --verify-tag --title "$TITLE" --notes-file "$NOTES" \
        --prerelease --latest=false "$DMG" "$DMG_SUM" || die "gh release create nightly failed"
fi
rm -f "$NOTES"
RELEASE_URL="$(gh release view "$NIGHTLY_TAG" --json url -q .url 2>/dev/null || echo "?")"

# ──────────────────── 5. 更新本机输入法 ────────────────────

INSTALLED_NOTE="未安装（--no-install）"
if [[ $NO_INSTALL == 0 ]]; then
    WAS_RUNNING=0
    pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null && WAS_RUNNING=1
    if [[ $WAS_RUNNING == 1 ]]; then
        log "退出正在运行的 $APP_NAME"
        RUNNING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "$PRODUCT_BUNDLE_ID")"
        osascript -e "quit app id \"$RUNNING_ID\"" >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null || break
            sleep 0.5
        done
    fi
    # The DMG build uses the product bundle id; a local .bundle-id override (the id the user's
    # existing IME registration lives under) needs a matching rebuild before install.
    if [[ -f platforms/macos/.bundle-id ]]; then
        log "按本机 bundle id 覆盖（platforms/macos/.bundle-id）重新构建"
        LIANA_VERSION="$VERSION" platforms/macos/build.sh || die "local rebuild failed"
    fi
    log "安装到 $INSTALL_DIR"
    platforms/macos/install.sh || die "install.sh failed"
    xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
    if [[ $WAS_RUNNING == 1 ]]; then
        open -g "$INSTALLED_APP" || warn "重新启动 $APP_NAME 失败（下次切换输入法时系统会自动拉起）"
    fi
    INSTALLED_NOTE="$INSTALLED_APP"
fi

# ──────────────────── 6. 总结 ────────────────────

echo
log "Nightly 完成（$(( $(date +%s) - START ))s）"
echo "  版本:     $VERSION"
echo "  Release:  $RELEASE_URL"
echo "  DMG:      $DMG"
echo "  本机安装: $INSTALLED_NOTE"
echo "  日志:     $LOG"
result "built nightly $VERSION $SHORT_SHA"
