#!/usr/bin/env bash
# 整句准确率闸门：固定语料 + 仓库内自带的搭配模型，跨机器可复现。
#
# 为什么需要它：发版脚本过去只把准确率当「趋势打印」，明确写了「失败不阻断发版」。
# 于是移动端换了剪枝模型、候选排序改了，都没有任何东西会红。
#
# 口径：
#   语料 xtask/data/corpus/liana-seed.tsv（120 句，随仓库走）
#   词典 crates/dict/data/base-large.tsv（随仓库走）
#   模型 platforms/ios/Vendor/LM/base.lm（随仓库走，17MB / 450 万条，iOS 实际分发的档位）
# 同一份输入 → 同一组数字，不受本机装了什么影响。
#
# 2026-11-20 基线（各端模型分发补齐后实测）：
#   整句 Top-1 53.3% · Top-3 71.7% · 字准确率 92.8% · 逐键 p95 8ms
# 对照（同一套语料、同一份词典，只换模型，实测）：
#   完整 42MB（1100 万条，桌面端）：64.2% / 75.0% / 93.8%
#   17MB（450 万条，iOS）：53.3% / 71.7% / 92.8%
#   无模型（2026-11-20 之前的 Android / Windows / Linux）：47.5% / 61.7% / 91.4%
#   iOS 旧剪枝档 5.3MB（107 万条）：51.7% / 70.0% / 92.1%
# 旧基线 51.7 是拿 5.3MB 剪枝档跑的；现在闸门跟产品实际分发的模型一致。
#
# 阈值取基线下方约 1 个百分点（延迟给到 25ms）：只拦真回归，不拦抖动。
# 改阈值必须在同一次提交里说明原因。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIN_TOP1=52
MIN_TOP3=70
MIN_CHAR=92
MAX_P95=25

echo "==> 跑 liana-seed 固定语料（120 句，仓库内模型）"
OUT="$(cargo run -q --release -p xtask -- eval-corpus \
  --set liana-seed --lm platforms/ios/Vendor/LM/base.lm --show 0 2>&1 | tail -20)"
echo "$OUT" | grep -E '语料集|liana-seed|逐键延迟' || true

LINE="$(echo "$OUT" | awk '/^  liana-seed/ {print; exit}')"
if [[ -z "$LINE" ]]; then
  echo "✗ 没能解析到 liana-seed 结果行" >&2
  echo "RESULT: accuracy gate error"; exit 2
fi

read -r top1 top3 char < <(echo "$LINE" | awk '{gsub("%","",$3); gsub("%","",$4); gsub("%","",$5); print $3, $4, $5}')
p95="$(echo "$OUT" | awk '/逐键延迟/{for(i=1;i<=NF;i++) if($i=="p95"){print $(i+1); exit}}')"

echo "解析：Top-1=${top1}% Top-3=${top3}% 字准确率=${char}% p95=${p95:-?}ms"

FAIL=0
awk -v v="$top1" -v m="$MIN_TOP1" 'BEGIN{exit !(v+0 >= m+0)}' || { echo "✗ 整句 Top-1 ${top1}% < 门槛 ${MIN_TOP1}%" >&2; FAIL=1; }
awk -v v="$top3" -v m="$MIN_TOP3" 'BEGIN{exit !(v+0 >= m+0)}' || { echo "✗ Top-3 ${top3}% < 门槛 ${MIN_TOP3}%" >&2; FAIL=1; }
awk -v v="$char" -v m="$MIN_CHAR" 'BEGIN{exit !(v+0 >= m+0)}' || { echo "✗ 字准确率 ${char}% < 门槛 ${MIN_CHAR}%" >&2; FAIL=1; }

[[ $FAIL -eq 0 ]] || { echo "RESULT: accuracy gate failed"; exit 1; }

# —— 英文补全闸门 ——
# 129 条（前缀 → 词表内该前缀词频最高的词）。这条闸门守的是「补全排序别乱动」，
# 不是「英文输入质量」：期望值由词表词频派生，因此 100% 是正常的，低于 99% 说明排序退化了。
echo "==> 跑英文补全语料（129 条）"
EN_OUT="$(cargo run -q --release -p xtask -- eval-corpus --set liana-en --lang en --show 0 2>&1 | tail -20)"
EN_LINE="$(echo "$EN_OUT" | awk '/^  liana-en/ {print; exit}')"
if [[ -z "$EN_LINE" ]]; then
  echo "✗ 没能解析到 liana-en 结果行" >&2
  echo "RESULT: accuracy gate error"; exit 2
fi
EN_TOP1="$(echo "$EN_LINE" | awk '{gsub("%","",$3); print $3}')"
echo "英文解析：Top-1=${EN_TOP1}%"
EN_MIN_TOP1=99
awk -v v="$EN_TOP1" -v m="$EN_MIN_TOP1" 'BEGIN{exit !(v+0 >= m+0)}' || { echo "✗ 英文补全 Top-1 ${EN_TOP1}% < 门槛 ${EN_MIN_TOP1}%" >&2; FAIL=1; }

# 延迟放最后：它受机器负载影响最大，红了也不该吞掉前面语料段的结果。
if [[ -n "${p95:-}" ]]; then
  awk -v v="$p95" -v m="$MAX_P95" 'BEGIN{exit !(v+0 <= m+0)}' || { echo "✗ 逐键延迟 p95 ${p95}ms > 上限 ${MAX_P95}ms" >&2; FAIL=1; }
fi

[[ $FAIL -eq 0 ]] || { echo "RESULT: accuracy gate failed"; exit 1; }
echo "RESULT: accuracy gate passed"
