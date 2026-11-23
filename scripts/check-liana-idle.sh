#!/usr/bin/env bash
# check-liana-idle.sh — Liana 空闲期 WebKit 活动闸门（可当回归测试跑，默认不杀进程）
#
# 背景：2026-11-23 空闲整机冻结。root cause 是桌宠的 WKWebView 在鼠标不动、
# 屏幕已息、会话已锁的情况下仍以 15Hz 推 evaluateJavaScript；WebKit 为每次调用
# 创建并立刻销毁一个 foreground ProcessThrottler activity，每个 activity 的
# create / invalidate 都触发一次 updateThrottleStateIfNeeded → ProcessDidResume。
# 现场：90 秒 2700 次 resume（30 次/秒），55,757 行日志，随后整机冻结。
#
# 这个脚本只做两件事：量它，然后给退出码。
#   退出 0 = 空闲行为达标
#   退出 1 = 超标（修复回归了）
#   退出 2 = 没法测（Liana 没在跑 / log show 拿不到数据）
#
# 用法：
#   ./scripts/check-liana-idle.sh                  # 采 30 秒，判一次
#   IDLE_WINDOW=120 ./scripts/check-liana-idle.sh  # 采 2 分钟（别用 SECONDS，那是 bash 自己的计数器）
#   RUNJS_MAX=0 ./scripts/check-liana-idle.sh      # 更严：一次 JS 都不许有
#   ./scripts/check-liana-idle.sh --watch          # 常驻保底：超标就记录并重启输入法
#
# 注意：采样窗口里请别动鼠标 —— 鼠标真的在动时 15 次/秒是正常行为。
# 脚本会自己用 HIDIdleTime 判断窗口内是否有输入，没空满窗口时会把 JS 一项标成 SKIP，
# 只判 ProcessDidResume（那一项和你动没动鼠标无关）。
set -uo pipefail

WINDOW="${IDLE_WINDOW:-30}"
RUNJS_MAX="${RUNJS_MAX:-5}"
RESUME_MAX="${RESUME_MAX:-0}"
CPU_MAX="${CPU_MAX:-12}"
APP_PATH="$HOME/Library/Input Methods/Liana.app"

watch=0
[[ "${1:-}" == "--watch" ]] && watch=1

pid_of_liana() { pgrep -f "Liana.app/Contents/MacOS/Liana" | head -1; }

# 距最后一次 HID 输入多少秒（鼠标/键盘都算）
hid_idle() {
  ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF / 1000000000); exit}'
}

measure() {
  local pid; pid="$(pid_of_liana)"
  if [[ -z "$pid" ]]; then
    echo "Liana 没有在运行，测不了。" >&2
    return 2
  fi
  local log
  log="$(log show --last "${WINDOW}s" --predicate 'process == "Liana"' --style compact 2>/dev/null)"
  if [[ -z "$log" ]]; then
    echo "log show 没拿到 Liana 的日志（统一日志被裁剪 / 没有权限？）。" >&2
    return 2
  fi

  # 一次 evaluateJavaScript = 一条 "WebPage::runJavaScriptInFrameInScriptWorld: frameID="
  local runjs resumes total cpu idle
  runjs="$(printf '%s\n' "$log" | grep -c 'runJavaScriptInFrameInScriptWorld: frameID=')"
  resumes="$(printf '%s\n' "$log" | grep -c 'sending ProcessDidResume')"
  total="$(printf '%s\n' "$log" | wc -l | tr -d ' ')"
  # ps 的 %cpu 是进程生命期平均值，量不出空闲时的瞬时占用；top 的第二轮采样才是。
  cpu="$(top -l 2 -s 1 -stats pid,cpu -pid "$pid" 2>/dev/null | awk -v p="$pid" '$1 == p { v = $2 } END { printf "%d", v + 0 }')"
  cpu="${cpu:-0}"
  idle="$(hid_idle)"; idle="${idle:-0}"

  local idle_ok skip_runjs=0
  if [[ "$idle" -ge $((WINDOW + 2)) ]]; then idle_ok=1; else idle_ok=0; skip_runjs=1; fi

  printf '窗口 %ss | pid=%s | 日志 %s 行 | JS=%s | resume=%s | CPU=%s%% | HID 空闲=%ss\n' \
    "$WINDOW" "$pid" "$total" "$runjs" "$resumes" "$cpu" "$idle"

  local fail=0
  if [[ "$skip_runjs" -eq 1 ]]; then
    echo "  SKIP  JS 一项：窗口内 HID 空闲只有 ${idle}s < $((WINDOW + 2))s，鼠标/键盘有动作，15Hz 属正常"
  elif [[ "$runjs" -gt "$RUNJS_MAX" ]]; then
    echo "  FAIL  JS=$runjs > ${RUNJS_MAX}：空闲时仍在推 evaluateJavaScript（2026-11-23 事故特征）"
    fail=1
  else
    echo "  ok    JS=$runjs <= ${RUNJS_MAX}"
  fi
  if [[ "$resumes" -gt "$RESUME_MAX" ]]; then
    echo "  FAIL  resume=$resumes > ${RESUME_MAX}：WebKit 正在反复 resume 被节流的 WebContent"
    fail=1
  else
    echo "  ok    resume=$resumes"
  fi
  if [[ "$cpu" -gt "$CPU_MAX" ]]; then
    echo "  WARN  CPU=$cpu% > ${CPU_MAX}%（空闲时应在 2% 以下）"
  else
    echo "  ok    CPU=$cpu%"
  fi
  return "$fail"
}

if [[ "$watch" -eq 0 ]]; then
  measure; rc=$?
  [[ "$rc" -eq 0 ]] && echo "RESULT: idle gate passed" || echo "RESULT: idle gate failed (rc=$rc)"
  exit "$rc"
fi

# --watch：常驻保底。超标就记录并重启输入法（修复版发布前给自己兜底用）。
LOG="$HOME/Library/Logs/liana-idle-watch.log"; mkdir -p "$(dirname "$LOG")"
echo "watch 模式：每 $((WINDOW * 2))s 量一次，超标记录并重启；日志 $LOG"
while :; do
  out="$(measure)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s | rc=%s | %s\n' "$(date "+%F %T")" "$rc" "$(echo "$out" | tr '\n' ';')" >> "$LOG"
    kill -9 "$(pid_of_liana)" 2>/dev/null
    /bin/sleep 2
    pgrep -f "Liana.app/Contents/MacOS/Liana" >/dev/null || open -a "$APP_PATH" 2>/dev/null
  fi
  /bin/sleep $((WINDOW * 2))
done
