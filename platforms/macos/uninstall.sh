#!/usr/bin/env bash
# 卸载输入法。
#
# 默认（推荐）：只移除程序与输入法注册，**保留**本地数据、偏好（桌宠、词库设置）与钥匙串密钥
#   → 重装后桌宠形象、用户词、剪切板历史都还在，这是大多数人想要的「卸载重装」
# --purge：连本地数据（用户词、剪切板、知你学习数据）、偏好域、钥匙串密钥一起删
#
# 同时清理品牌升级前的 InputFlow 遗留（旧 app / 旧偏好域）。
set -euo pipefail

APP="Liana"
LEGACY_APP="InputFlow"
DEST="$HOME/Library/Input Methods/$APP.app"
LEGACY_DEST="$HOME/Library/Input Methods/$LEGACY_APP.app"
SYSTEM_APP="/Library/Input Methods/$APP.app"
DATA_DIR="$HOME/Library/Application Support/Liana"
LEGACY_DATA_DIR="$HOME/Library/Application Support/InputFlow"
PLIST="$DEST/Contents/Info.plist"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            echo "用法: $0 [--purge]"
            echo "  默认保留本地数据、偏好与钥匙串密钥（适合卸载后重装）"
            echo "  --purge 全部删除（彻底清除）"
            exit 0
            ;;
        *) echo "未知参数: $arg（可用 --purge / --help）" >&2; exit 2 ;;
    esac
done

# 以已安装 bundle 的实际 id 为准（支持 build.sh 的 BUNDLE_ID 覆盖）
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[[ -n "$BUNDLE_ID" ]] || BUNDLE_ID="dev.liana.inputmethod.ime"
LEGACY_BUNDLE_ID="dev.inputflow.ime"
# 钥匙串服务名钉死在初代 bundle id 上（EncryptedStore.swift），不随品牌/bundle id 变
KEYCHAIN_SERVICE="dev.inputflow.inputmethod"

# 1) 先从注册表移除本输入法，否则卸载后菜单里还挂着一条点不动的「松萝」
BIN="$DEST/Contents/MacOS/$APP"
if [[ -x "$BIN" ]]; then
    "$BIN" --remove-input-source || true
fi

# 2) 退出进程、删程序
killall "$APP" "$LEGACY_APP" 2>/dev/null || true
rm -rf "$DEST" "$LEGACY_DEST"

# 3) 系统级副本需要管理员权限：只打印命令，不擅自 sudo
if [[ -d "$SYSTEM_APP" ]]; then
    echo "⚠ 还留有系统级副本：$SYSTEM_APP"
    echo "  删除需要管理员权限，请手动执行："
    echo "      sudo rm -rf \"$SYSTEM_APP\""
fi

# 4) 偏好域：默认保留（桌宠位置/形象、词库与同步设置都在这里）
if [[ "$PURGE" == "1" ]]; then
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    defaults delete "$LEGACY_BUNDLE_ID" 2>/dev/null || true
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a userdata-key >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR" "$LEGACY_DATA_DIR"
    echo "已彻底删除：本地数据、偏好、钥匙串密钥（$DATA_DIR）"
else
    echo "已保留：本地数据（$DATA_DIR）、偏好（桌宠/词库设置）、钥匙串密钥"
    echo "想连数据一起清除，重跑加 --purge"
fi

echo "已卸载 $APP（$BUNDLE_ID）。注销或重启后系统输入法列表会刷新。"
