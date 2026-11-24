#!/usr/bin/env python3
"""UD Japanese dev/test → 词级评测集（假名读音 → 原词形）

用法：
    python3 crates/ja/tools/make_word_eval.py \
        --conllu crates/ja/data/.cache/ja_gsd-ud-dev.conllu \
        --conllu crates/ja/data/.cache/ja_gsd-ud-test.conllu \
        --output xtask/data/corpus/liana-ja-words.tsv --count 500

口径：每个词条一行，输入是该词在句子里的假名读音，期望是原词形（含汉字）。
只取名词/动词/形容词/副词，丢掉专名、符号、含拉丁字母的词；同 (读音, 词形)
去重后按语料出现频次取前 N 个。按频次而不是按词型均匀抽样：用户打的是常见词。
它测「词表消歧」，不测上下文——上下文由整句语料测。
"""

import argparse
import sys

KANA = set("ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんゔー")
UPOS_OK = {"NOUN", "VERB", "ADJ", "ADV"}
KANJI = lambda ch: "\u4e00" <= ch <= "\u9fff"
VOWEL = {}
for _row, _v in (("あかさたなはまやらわ", "あ"), ("いきしちにひみり", "い"),
                 ("うくすつぬふむゆる", "う"), ("えけせてねへめれ", "え"),
                 ("おこそとのほもよろ", "お")):
    for _c in _row:
        VOWEL[_c] = _v
VOWEL.update({"ゃ": "あ", "ゅ": "う", "ょ": "お", "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お"})


def fix_long_vowel(s: str) -> str:
    out = []
    for i, ch in enumerate(s):
        if ch == "ー" and i > 0 and s[i - 1] in VOWEL:
            v = VOWEL[s[i - 1]]
            out.append("い" if v == "え" else "う" if v == "お" else v)
        else:
            out.append(ch)
    return "".join(out)


def kata_to_hira(s: str) -> str:
    return "".join(chr(ord(c) - 0x60) if 0x30A1 <= ord(c) <= 0x30F6 else c for c in s)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conllu", action="append", required=True)
    ap.add_argument("--output", default="xtask/data/corpus/liana-ja-words.tsv")
    ap.add_argument("--count", type=int, default=500)
    args = ap.parse_args()

    from collections import Counter

    counts = Counter()
    pos_of = {}
    for path in args.conllu:
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 10 or "-" in cols[0] or "." in cols[0]:
                continue
            form, upos, misc = cols[1], cols[3], cols[9]
            if upos not in UPOS_OK or not any(KANJI(c) for c in form):
                continue
            if any(c.isascii() and c.isalnum() for c in form):
                continue
            lform = pron = ""
            for part in misc.split("|"):
                if part.startswith("UnidicInfo="):
                    fs = part[len("UnidicInfo="):].split(",")
                    if fs:
                        lform = fs[0]
                    if len(fs) >= 5:
                        pron = fs[4]
            rd = fix_long_vowel(kata_to_hira(pron)) if upos in ("VERB", "ADJ") and pron else fix_long_vowel(kata_to_hira(lform)) if lform else ""
            if not rd:
                continue
            rd = kata_to_hira(rd)
            if not rd or any(not (c in KANA or c == "ー") for c in rd):
                continue
            if len(form) > 8:
                continue
            key = (rd, form)
            counts[key] += 1
            pos_of.setdefault(key, upos)

    # 按使用频次取词：输入法用户打的是常见词，按「词型均匀」抽样会把生僻
    # 同音词抬成主样本，测出来的不是真实使用中的正确率。
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[: args.count]
    picked = [(rd, form, pos_of.get((rd, form), "?")) for (rd, form), _c in ranked]
    with open(args.output, "w", encoding="utf-8") as f:
        for rd, form, upos in picked:
            f.write(f"{rd}\t{form}\t{upos}\n")
    print(f"unique={len(counts)} picked={len(picked)} -> {args.output}")
    for rd, form, upos in picked[:6]:
        print(f"  {rd} -> {form} ({upos})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
