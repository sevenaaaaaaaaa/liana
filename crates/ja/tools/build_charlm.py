#!/usr/bin/env python3
"""Tatoeba 日语语料 → 字符 4-gram 语言模型（charlm.bin）

用法：
    python3 crates/ja/tools/build_charlm.py \
        --input crates/ja/data/.cache/jpn_sentences.tsv.bz2 \
        --output crates/ja/data/charlm.bin --max 200000

格式（小端）：
    magic "JCL1" (4B) · u8 order=4 · u32 count
    count × (u64 FNV-1a 64 哈希, i16 cost)

cost = -ln((count+α)/(total+α·V)) × 100，只存出现最多的 --max 个 4-gram；
未命中的 4-gram 在运行时按 UNSEEN 计。句子边界用 NUL 字符补齐。

许可证：Tatoeba 句子 CC BY 2.0 FR；这里只保留 n-gram 统计量，不复制句子。
"""

import argparse
import bz2
import math
import struct
import sys
from collections import Counter

ALPHA = 0.1
FIELDS = "UnidicInfo"


def fnv1a64(s: str) -> int:
    h = 0xCBF29CE484222325
    for ch in s:
        h ^= ord(ch)
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="crates/ja/data/.cache/jpn_sentences.tsv.bz2")
    ap.add_argument("--output", default="crates/ja/data/charlm.bin")
    ap.add_argument("--max", type=int, default=200000)
    ap.add_argument("--order", type=int, default=4)
    args = ap.parse_args()
    order = args.order

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
            if sum(1 for c in text if c.isascii() and c.isalpha()) * 5 > len(text):
                continue
            sentences += 1
            chars += len(text)
            padded = "\x00" * (order - 1) + text + "\x00"
            for i in range(len(padded) - order + 1):
                counts[padded[i : i + order]] += 1

    top = counts.most_common(args.max)
    total = sum(counts.values())
    vocab = len(counts)
    with open(args.output, "wb") as out:
        out.write(b"JCL1")
        out.write(struct.pack("<BI", order, len(top)))
        for gram, c in top:
            p = (c + ALPHA) / (total + ALPHA * vocab)
            cost = max(-30000, min(30000, round(-math.log(p) * 100)))
            out.write(struct.pack("<Qh", fnv1a64(gram), cost))
    print(f"sentences={sentences} chars={chars} distinct={vocab} stored={len(top)} total={total}")
    print("top:", ", ".join(f"{g!r}={c}" for g, c in top[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
