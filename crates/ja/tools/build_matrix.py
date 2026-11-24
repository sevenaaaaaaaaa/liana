#!/usr/bin/env python3
"""UD Japanese CoNLL-U → 词性连接矩阵 matrix.bin

用法：
    python3 crates/ja/tools/build_matrix.py \
        --conllu crates/ja/data/.cache/ja_gsd-ud-train.conllu \
        --output crates/ja/data/matrix.bin [--dump]

格式（小端）：
    magic  "JAM1" (4B)
    u8     version = 1
    u8     ntags
    ntags × (u8 len + UTF-8 name)
    ntags × ntags × i16  cost（行 = 前一个词性，列 = 后一个词性）

cost = -ln((count + α) / (row_total + α·V)) × 100，α=0.5。
BOS/EOS 各占一行一列：首词成本取 BOS 行，末词成本取 EOS 列。
"""

import argparse
import math
import struct
import sys
from collections import Counter

TAGS = ["BOS", "EOS", "NOUN", "VERB", "ADJ", "ADV", "ADP", "AUX",
        "CCONJ", "SCONJ", "PART", "PRON", "NUM", "PREF", "DET", "INTJ", "X", "UNK"]
TAG_ID = {t: i for i, t in enumerate(TAGS)}
UPOS_MAP = {
    "NOUN": "NOUN", "PROPN": "NOUN", "VERB": "VERB", "ADJ": "ADJ", "ADV": "ADV",
    "ADP": "ADP", "AUX": "AUX", "CCONJ": "CCONJ", "SCONJ": "SCONJ", "PART": "PART",
    "PRON": "PRON", "NUM": "NUM", "DET": "DET", "INTJ": "INTJ", "X": "X",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conllu", action="append", required=True)
    ap.add_argument("--output", default="crates/ja/data/matrix.bin")
    ap.add_argument("--dump", action="store_true")
    args = ap.parse_args()

    counts = Counter()
    sentences = 0
    for path in args.conllu:
        prev = "BOS"
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("# sent_id"):
                    if prev != "BOS":
                        counts[(prev, "EOS")] += 1
                        sentences += 1
                    prev = "BOS"
                    continue
                if not line or line.startswith("#"):
                    continue
                cols = line.split("\t")
                if len(cols) != 10 or "-" in cols[0] or "." in cols[0]:
                    continue
                upos = cols[3]
                tag = UPOS_MAP.get(upos)
                if tag is None:
                    continue
                counts[(prev, tag)] += 1
                prev = tag
    if prev != "BOS":
        counts[(prev, "EOS")] += 1
        sentences += 1

    n = len(TAGS)
    alpha = 0.5
    rows = Counter()
    for (a, _b), c in counts.items():
        rows[a] += c
    costs = [[0] * n for _ in range(n)]
    for i, a in enumerate(TAGS):
        if a == "BOS":
            # 句首不设强先验：日语常省略主语，语料里的句首分布会把 私/僕 这类
            # 代词压到名词后面；首词交给词成本决定。
            for j in range(n):
                costs[i][j] = 120
            continue
        if a == "EOS":
            for j in range(n):
                costs[i][j] = 120
            continue
        if rows.get(a, 0) == 0:
            # 训练语料里没出现过的行（PREF/X/UNK 等）不能因为「没有数据」而变便宜：
            # 给一个中性且偏高的成本，避免这些词性被当成万能接续。
            for j in range(n):
                costs[i][j] = 900
            continue
        for j, b in enumerate(TAGS):
            if b == "EOS":
                # 句尾同样不设强先验：输入法里用户经常只打一个片段，
                # 「と」不该因为 ADP 很少结句就输给同音名词 人。
                costs[i][j] = 120
                continue
            c = counts.get((a, b), 0)
            p = (c + alpha) / (rows[a] + alpha * n)
            costs[i][j] = max(-30000, min(30000, round(-math.log(p) * 100)))

    with open(args.output, "wb") as f:
        f.write(b"JAM1")
        f.write(struct.pack("<BB", 1, n))
        for t in TAGS:
            raw = t.encode()
            f.write(struct.pack("<B", len(raw)))
            f.write(raw)
        for i in range(n):
            for j in range(n):
                f.write(struct.pack("<h", costs[i][j]))
    print(f"sentences={sentences} transitions={sum(counts.values())} tags={n} out={args.output}")

    if args.dump:
        print("cost matrix (rows=BOS..UNK):")
        print("      " + " ".join(f"{t:>6}" for t in TAGS))
        for i, t in enumerate(TAGS):
            print(f"{t:>5} " + " ".join(f"{costs[i][j]:>6}" for j in range(n)))
        print("\nmost frequent transitions:")
        for (a, b), c in counts.most_common(15):
            print(f"  {a:>6} -> {b:<6} {c:>7}  cost={costs[TAG_ID[a]][TAG_ID[b]]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
