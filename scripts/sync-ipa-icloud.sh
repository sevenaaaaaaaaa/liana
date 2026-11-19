#!/usr/bin/env bash
# 把 dist/ 里最新的 iOS IPA 与校验和同步到 iCloud Drive 根目录。
#
# 为什么要有这一步：真机安装靠 iCloud 取件（这台机器出包、另一台设备下载安装），
# 每次更新/发版/提交之后都要有最新 IPA 可拿。手工找文件容易漏，所以固化进流程：
# release.sh 与 platforms/ios/build.sh 结束时都会调它。
#
# 约定（与 iCloud 里其它项目一致）：IPA 与 .sha256 都放 CloudDocs 根目录，同名覆盖。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICL="${LIANA_ICLOUD_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs}"

if [[ ! -d "$ICL" ]]; then
    echo "  ⚠️ iCloud 同步跳过（未登录 iCloud 或未开启云盘）：$ICL" >&2
    exit 1
fi

IPA="$(ls -t "$ROOT"/dist/*.ipa 2>/dev/null | head -1)"
if [[ -z "$IPA" ]]; then
    echo "  ⚠️ iCloud 同步跳过：dist/ 里没有 .ipa" >&2
    exit 1
fi

NAME="$(basename "$IPA")"
cp -f "$IPA" "$ICL/$NAME" || { echo "  ⚠️ 复制到 iCloud 失败：$ICL/$NAME" >&2; exit 1; }
( cd "$ICL" && shasum -a 256 "$NAME" > "$NAME.sha256" )
echo "  iCloud 已同步：$ICL/${NAME}（$(du -h "$IPA" | cut -f1)）"
