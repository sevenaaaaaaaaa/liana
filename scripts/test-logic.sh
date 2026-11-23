#!/usr/bin/env bash
# Swift 纯逻辑回归：用 swiftc 直接编译 + 运行，不需要 Xcode 工程、不需要模拟器。
#
# 为什么单独有这个脚本：仓库里这几个测试一直是「文档里写了命令、靠人记得跑」。
# 2026-11-17 复盘时核对：macOS 的 4 个 tests/*.swift 在 CI 里从未被执行过，
# iOS 的 XCTest 也只在本地。这个脚本把「能在命令行跑的」全部收进来，
# 由 .github/workflows/ci.yml 调用，改坏了就红。
#
# 不在这里跑的：platforms/ios/Tests 下用 XCTest + UIKit 的三个（需要模拟器），
# 以及 UITests。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

FAILED=0
PASSED=0

run() {
  local name="${1}"; shift
  local bin="$OUT/$name"
  if ! swiftc "$@" -o "$bin" 2>"$OUT/$name.log"; then
    echo "✗ $name 编译失败"; sed 's/^/    /' "$OUT/$name.log" | head -20; FAILED=$((FAILED+1)); return
  fi
  if "$bin" >"$OUT/$name.out" 2>&1; then
    echo "✓ $name"; PASSED=$((PASSED+1))
  else
    echo "✗ $name 断言失败"; sed 's/^/    /' "$OUT/$name.out" | head -20; FAILED=$((FAILED+1))
  fi
}

echo "==> macOS 纯逻辑"
run input-source-registration \
  platforms/macos/Sources/InputSourceRegistration.swift \
  platforms/macos/tests/InputSourceRegistrationTests.swift
run pet-studio \
  platforms/macos/Sources/PetStudioCore.swift \
  platforms/macos/tests/PetStudioTests.swift
run pet-gaze-gate \
  platforms/macos/Sources/PetGazeGate.swift \
  platforms/macos/tests/PetGazeGateTests.swift

echo "==> iOS 纯逻辑（不依赖 UIKit）"
run command-catalog \
  platforms/ios/Keyboard/CommandCatalog.swift \
  platforms/ios/Tests/CommandCatalogTests.swift
run fold-layout \
  platforms/ios/Keyboard/FoldLayout.swift \
  platforms/ios/Tests/FoldLayoutTests.swift
run candidate-noise \
  platforms/ios/Keyboard/CandidateNoiseFilter.swift \
  platforms/ios/Tests/CandidateNoiseFilterTests.swift
run t9-missing-digit \
  platforms/ios/Keyboard/MobileLexicon.swift \
  platforms/ios/Keyboard/CandidateNoiseFilter.swift \
  platforms/ios/Tests/T9MissingDigitLookupTests.swift
run translation-wire \
  platforms/ios/Keyboard/TranslationAPI.swift \
  platforms/ios/Tests/TranslationAPITests.swift

echo
echo "通过 ${PASSED}，失败 ${FAILED}"
[[ $FAILED -eq 0 ]] || { echo "RESULT: swift logic tests failed"; exit 1; }
echo "RESULT: swift logic tests passed"
