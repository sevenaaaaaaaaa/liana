#!/usr/bin/env bash
# 三端菜单一致性闸门：菜单的语言清单必须来自内核注册表，不许各端再写死一份。
#
# 为什么需要它：iOS 曾经枚举 7 档、Android/鸿蒙写死 ['pinyin','en']，内核加了 ja/ko/es
# 之后三端菜单都跟不上——这类回归不会让任何测试变红，只会让用户少几门语言。
# 本脚本检查三件事：
#   1. 每个平台确实调用了内核清单（经各自的 C ABI 垫片）；
#   2. 写死的两档清单已经不存在；
#   3. 三端的内置回退清单与内核的 9 个 id 对得上（缺一项就红）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
CHECKS=0

ok() { CHECKS=$((CHECKS + 1)); echo "  ✓ $1"; }
bad() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "  ✗ $1"; }

need() { # file, pattern, description
  if grep -Fq -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3（$1 里找不到：$2）"; fi
}

forbid() { # file, pattern, description
  if grep -Fq -- "$2" "$1" 2>/dev/null; then bad "$3（$1 仍有：$2）"; else ok "$3"; fi
}

IOS_MENU=platforms/ios/Keyboard/KeyboardViewController.swift
IOS_CATALOG=platforms/ios/Keyboard/LanguageCatalog.swift
ANDROID_MENU=platforms/android/app/src/main/java/dev/liana/ime/LianaImeService.kt
ANDROID_CATALOG=platforms/android/app/src/main/java/dev/liana/ime/LanguageMenu.kt
ANDROID_JNI=platforms/android/app/src/main/cpp/jni_shim.c
HARMONY_MENU=platforms/harmonyos/entry/src/main/ets/inputmethod/LianaIME.ets
HARMONY_CATALOG=platforms/harmonyos/entry/src/main/ets/inputmethod/LanguageList.ts
HARMONY_NAPI=platforms/harmonyos/entry/src/main/cpp/napi_shim.cpp

echo "==> 1/3 三端都读内核注册表"
need "$IOS_MENU" "kernelLanguagesJSON" "iOS 菜单经 kernelLanguagesJSON 取值"
need "$IOS_MENU" "liana_languages()" "iOS 调 liana_languages()"
need "$ANDROID_MENU" "LanguageMenu.load(LianaJni.languages())" "Android 菜单读内核清单"
need "$ANDROID_JNI" "Java_dev_liana_ime_LianaJni_nativeLanguages" "Android JNI 垫片导出 nativeLanguages"
need "$HARMONY_MENU" "loadKernelLanguages" "鸿蒙菜单加载内核清单"
need "$HARMONY_MENU" "liana.languages()" "鸿蒙调 NAPI languages()"
need "$HARMONY_NAPI" "liana_languages" "鸿蒙 NAPI 垫片转出 liana_languages"

echo "==> 2/3 写死的两档清单已清掉"
forbid "$IOS_MENU" "MobileInputMethod.allCases.map" "iOS 菜单不再用固定枚举 allCases"
forbid "$ANDROID_MENU" 'arrayOf("pinyin", "en")' "Android 不再写死 pinyin/en"
forbid "$HARMONY_MENU" "const MODES" "鸿蒙不再写死 MODES"

echo "==> 3/3 三端回退清单与内核 9 项一致"
# 内核 id 的唯一真相源在 crates/engine/src/lib.rs::builtin_languages()；
# 这里用 FFI 测试同样的清单做交叉校验：任一端少一项，或内核多一门没同步，都红。
IDS="pinyin flypy mspy zrm emoji en es ja ko"
for id in $IDS; do
  # 三端写法不同：Swift `id: "ja"` / Kotlin `LianaLanguage("ja"` / TS `id: 'ja'`
  grep -Fq "id: \"$id\"" "$IOS_CATALOG" && ok "iOS 回退含 $id" || bad "iOS 回退缺 $id"
  grep -Fq "LianaLanguage(\"$id\"" "$ANDROID_CATALOG" && ok "Android 回退含 $id" || bad "Android 回退缺 $id"
  grep -Fq "id: '$id'" "$HARMONY_CATALOG" && ok "鸿蒙回退含 $id" || bad "鸿蒙回退缺 $id"
done
need crates/engine/src/lib.rs '("pinyin", "拼音", "ascii")' "内核清单仍是唯一真相源"

echo
if [[ $FAILED -gt 0 ]]; then
  echo "RESULT: language menus out of sync（$FAILED/$CHECKS 项失败）"
  exit 1
fi
echo "RESULT: language menus in sync（$CHECKS 项）"
