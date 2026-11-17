#!/usr/bin/env bash
# 原生内核产物一致性检查（Android .so / 鸿蒙 .a）。
#
# 背景：这两个二进制是**签入仓库**的（Android gradle 直接打包 jniLibs，
# 鸿蒙 hvigor 直接链接 .a），CI 过去只跑 gradle，从不重建它们。
# 2026-11-17 复盘发现：v0.10.1 的 APK 里 libliana_jni.so 还是 10-13 的内核，
# 缺 10 个 C ABI 符号（translate / card / pin / ban / promote / new_with_layers …），
# 一个月的内核改进没有进 Android 用户手里。
#
# 做法：crates/ffi/src/lib.rs 里每个 extern "C" 函数，都必须在每个签入的原生库里找到。
# 缺一个就判红，并打印缺了哪些。已知欠账写在 platforms/native-artifacts-known-stale.txt，
# 只放过「该产物 + 该符号」这一组合——出现新符号一样判红。
#
# 用法：
#   scripts/check-native-artifacts.sh                    # 符号对账（任何平台可跑）
#   scripts/check-native-artifacts.sh --strict-mtime     # 再加一层：库必须比内核源码新
#
# 重建：platforms/android/build_native.sh（Android）/ platforms/harmonyos/build_ohos.sh --rust-only（鸿蒙）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STRICT=0
[[ "${1:-}" == "--strict-mtime" ]] && STRICT=1

FFI_SRC="crates/ffi/src/lib.rs"
KNOWN="platforms/native-artifacts-known-stale.txt"
[[ -f "$FFI_SRC" ]] || { echo "✗ 找不到 $FFI_SRC" >&2; exit 1; }

EXPECTED_FILE="$(mktemp)"
trap 'rm -f "$EXPECTED_FILE"' EXIT
grep -oE 'pub (unsafe )?extern "C" fn [a-z_0-9]+' "$FFI_SRC" | sed 's/.*fn //' | sort -u > "$EXPECTED_FILE"
EXPECTED_COUNT="$(wc -l < "$EXPECTED_FILE" | tr -d ' ')"
if [[ "$EXPECTED_COUNT" -eq 0 ]]; then echo "✗ 没能从 $FFI_SRC 里解析出任何 C ABI 符号" >&2; exit 1; fi
echo "==> 内核导出 C ABI 符号 $EXPECTED_COUNT 个"

# 取二进制符号名：优先 nm，失败退回 strings（.dynstr 里名字是明文的）
symbols_of() {
  local f="${1}"
  if command -v nm >/dev/null 2>&1 && nm -g "$f" >/dev/null 2>&1; then
    nm -g "$f" 2>/dev/null | awk '{print $NF}' | sed 's/^_//'
    return
  fi
  strings -a "$f" 2>/dev/null | tr ' \t' '\n\n'
}

# 某产物已登记的欠账符号
waived_for() {
  local artifact="${1}"
  [[ -f "$KNOWN" ]] || return 0
  awk -F'\t' -v a="$artifact" '$1==a && $2!="" {print $2}' "$KNOWN"
}

TOTAL_NEW_MISSING=0
TOTAL_WAIVED=0

check_one() {
  local f="${1}" label="${2}" tmp waived_file missing=0 waived=0 s
  [[ -f "$f" ]] || { echo "✗ 缺少 ${label}：$f" >&2; return 1; }
  tmp="$(mktemp)"; waived_file="$(mktemp)"
  symbols_of "$f" | sort -u > "$tmp"
  waived_for "$f" | sort -u > "$waived_file"
  while IFS= read -r s; do
    if ! grep -qxF "$s" "$tmp"; then
      if grep -qxF "$s" "$waived_file"; then
        waived=$((waived+1))
      else
        echo "   ✗ ${label} 缺符号：$s" >&2
        missing=$((missing+1))
      fi
    fi
  done < "$EXPECTED_FILE"
  rm -f "$tmp" "$waived_file"
  TOTAL_NEW_MISSING=$((TOTAL_NEW_MISSING+missing))
  TOTAL_WAIVED=$((TOTAL_WAIVED+waived))
  if [[ $missing -gt 0 ]]; then
    echo "✗ ${label} 缺 $missing/$EXPECTED_COUNT 个 C ABI 符号——内核改了但库没重建。" >&2
    echo "  重建：platforms/android/build_native.sh（Android）/ platforms/harmonyos/build_ohos.sh --rust-only（鸿蒙）" >&2
    return 1
  fi
  if [[ $waived -gt 0 ]]; then
    echo "   ! ${label} 有 $waived 个已知欠账（见 ${KNOWN}）"
  else
    echo "   ✓ ${label} 齐全（${f}）"
  fi
  return 0
}

FAIL=0
for abi in arm64-v8a armeabi-v7a x86_64; do
  check_one "platforms/android/app/src/main/jniLibs/$abi/libliana_jni.so" "Android $abi" || FAIL=1
done
check_one "platforms/harmonyos/entry/src/main/cpp/libs/arm64-v8a/libliana_ffi.a" "HarmonyOS arm64" || FAIL=1

if [[ $STRICT == 1 ]]; then
  echo "==> 检查库是否比内核源码新"
  newest_src="$(find crates -name '*.rs' -newer "platforms/android/app/src/main/jniLibs/arm64-v8a/libliana_jni.so" -print -quit || true)"
  if [[ -n "$newest_src" ]]; then
    echo "✗ 内核源码比 Android 库新（例如 ${newest_src}）：先重建再提交" >&2
    FAIL=1
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  echo "RESULT: native artifacts out of date" >&2
  exit 1
fi
if [[ $TOTAL_WAIVED -gt 0 ]]; then
  echo "RESULT: native artifacts in sync（另有 $TOTAL_WAIVED 项已知欠账未清）"
else
  echo "RESULT: native artifacts in sync"
fi
