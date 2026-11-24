#!/bin/bash
# 下载日语数据快照（JMdict + UD Japanese-GSD）。可重复执行：已存在则跳过。
# 用法：bash crates/ja/tools/fetch_data.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
CACHE="crates/ja/data/.cache"
mkdir -p "$CACHE"

fetch() {
  local url="$1" out="$2"
  if [ -s "$out" ]; then
    echo "已存在，跳过：$out"
  else
    echo "下载：$url"
    curl -sS --fail --location --retry 3 --retry-delay 2 -C - -o "$out" "$url"
  fi
  ls -l "$out"
}

fetch https://www.edrdg.org/pub/Nihongo/JMdict_e.gz "$CACHE/JMdict_e.gz"
fetch https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/master/ja_gsd-ud-train.conllu "$CACHE/ja_gsd-ud-train.conllu"
fetch https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/master/ja_gsd-ud-dev.conllu "$CACHE/ja_gsd-ud-dev.conllu"
fetch https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/master/ja_gsd-ud-test.conllu "$CACHE/ja_gsd-ud-test.conllu"
fetch https://downloads.tatoeba.org/exports/per_language/jpn/jpn_sentences.tsv.bz2 "$CACHE/jpn_sentences.tsv.bz2"

echo "--- sha256（与 SOURCES.md 比对；JMdict 每日更新，哈希会变）---"
shasum -a 256 "$CACHE"/*.gz "$CACHE"/*.conllu
gzip -t "$CACHE/JMdict_e.gz" && echo "JMdict gzip OK"
