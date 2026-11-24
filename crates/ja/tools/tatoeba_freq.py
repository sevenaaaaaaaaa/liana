#!/usr/bin/env python3
"""Tatoeba 日语语料 → 词表表面频次（供 prune_jmdict.py --surface-freq）

用法：
    python3 crates/ja/tools/tatoeba_freq.py \
        --dict crates/ja/data/jmdict.tsv \
        --input crates/ja/data/.cache/jpn_sentences.tsv.bz2 \
        --output crates/ja/data/.cache/ja-surface-freq.tsv

口径：对每条句子做「最长匹配」——每步优先取词表里最长的表面，命中即计数并前进；
未命中的字符前进 1。只保留聚合计数，不复制句子。

原因：UD train 只有 15 万 token，对「初めて/始めて」「新鮮/深セン」这类同音词
区分不够；Tatoeba 约 25 万句（300 万字）更接近真实书写分布。

许可证：Tatoeba 句子 CC BY 2.0 FR（署名见 crates/ja/data/SOURCES.md）。
"""

import argparse
import bz2
import sys
from collections import Counter


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dict", default="crates/ja/data/jmdict.tsv")
    ap.add_argument("--input", default="crates/ja/data/.cache/jpn_sentences.tsv.bz2")
    ap.add_argument("--output", default="crates/ja/data/.cache/ja-surface-freq.tsv")
    args = ap.parse_args()

    surfaces = set()
    max_len = 1
    with open(args.dict, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) >= 2 and cols[1]:
                surfaces.add(cols[1])
                max_len = max(max_len, len(cols[1]))

    counts = Counter()
    sentences = chars = 0
    with bz2.open(args.input, "rt", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            text = parts[2]
            if not text:
                continue
            ascii_alpha = sum(1 for c in text if c.isascii() and c.isalpha())
            if ascii_alpha * 5 > len(text):
                continue
            sentences += 1
            chars += len(text)
            i, n = 0, len(text)
            while i < n:
                hit = None
                for ln in range(min(max_len, n - i), 0, -1):
                    cand = text[i : i + ln]
                    if cand in surfaces:
                        hit = (cand, ln)
                        break
                if hit:
                    counts[hit[0]] += 1
                    i += hit[1]
                else:
                    i += 1

    with open(args.output, "w", encoding="utf-8") as f:
        for surface, c in counts.most_common():
            f.write(f"{surface}\t{c}\n")
    print(f"sentences={sentences} chars={chars} surfaces={len(counts)} -> {args.output}")
    print("top:", ", ".join(f"{s}={c}" for s, c in counts.most_common(10)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
