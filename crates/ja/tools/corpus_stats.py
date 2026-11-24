#!/usr/bin/env python3
"""UD Japanese CoNLL-U → 词频表（供 prune_jmdict.py --freq 使用）

用法：
    python3 crates/ja/tools/corpus_stats.py \
        --conllu crates/ja/data/.cache/ja_gsd-ud-train.conllu \
        --output crates/ja/data/.cache/ja-freq.tsv

口径：按 LEMMA 计数（一个词条的词典形出现一次记 1），跳过标点/符号。
输出：lemma <TAB> count，按 count 降序。
"""

import argparse
import sys
from collections import Counter


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conllu", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    counts = Counter()
    sentences = tokens = 0
    with open(args.conllu, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("# sent_id"):
                sentences += 1
                continue
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 10 or "-" in cols[0] or "." in cols[0]:
                continue
            lemma, upos = cols[2], cols[3]
            if upos in ("PUNCT", "SYM"):
                continue
            tokens += 1
            counts[lemma] += 1

    with open(args.output, "w", encoding="utf-8") as f:
        for lemma, c in counts.most_common():
            f.write(f"{lemma}\t{c}\n")
    print(f"sentences={sentences} tokens={tokens} lemmas={len(counts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
