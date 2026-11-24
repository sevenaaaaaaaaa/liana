#!/usr/bin/env python3
"""UD Japanese dev/test → 200 句假名→汉字评测语料

用法：
    python3 crates/ja/tools/make_eval_corpus.py \
        --conllu crates/ja/data/.cache/ja_gsd-ud-dev.conllu \
        --conllu crates/ja/data/.cache/ja_gsd-ud-test.conllu \
        --output xtask/data/corpus/liana-ja.tsv --count 200

语料行：ja <TAB> かな入力 <TAB> 期望表记

读数口径：
- 纯假名 token 直接用它的书写形（は→は、を→を、た→た），不用发音（ワ）；
- 含汉字的 token 用 UniDicInfo 的第 4 段 pron（该 token 的表层发音，行っ→イッ）；
- 标点原样保留；含拉丁字母/数字、专有名词、空读音的句子整句丢弃，避免评测
  被词典里本来就没有的名字拖低。
"""

import argparse
import sys
from collections import Counter

KANA = set("ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんゔー")
PUNCT_OK = set("。、！？「」『』（）・…ー～〜：；,.!?()[]{}「」『』【】〈〉《》")
KANJI = lambda ch: "\u4e00" <= ch <= "\u9fff"
# 发音（pron）把长音写成「ー」，用户实际键入的是假名拼写。按前一个假名的行还原：
# え段→い（せんせー→せんせい）、お段→う（きんちょー→きんちょう），其余同行母音。
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


def parse_sentence(lines):
    """返回 [(form, upos, pron, space_after)]；跳过不合格行。"""
    toks = []
    for line in lines:
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 10 or "-" in cols[0] or "." in cols[0]:
            continue
        form, upos, misc = cols[1], cols[3], cols[9]
        lform = pron = ""
        for part in misc.split("|"):
            if part.startswith("UnidicInfo="):
                fields = part[len("UnidicInfo="):].split(",")
                # 实测量产数据：0=lForm 1=lemma 2=orth 3=orthBase 4=pron
                if len(fields) >= 1:
                    lform = fields[0]
                if len(fields) >= 5:
                    pron = fields[4]
        toks.append((form, upos, lform, pron, "SpaceAfter=No" not in misc))
    return toks


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conllu", action="append", required=True)
    ap.add_argument("--output", default="xtask/data/corpus/liana-ja.tsv")
    ap.add_argument("--count", type=int, default=200)
    args = ap.parse_args()

    cands = []
    stats = Counter()
    for path in args.conllu:
        cur = []
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("# sent_id"):
                    if cur:
                        cands.append(cur)
                    cur = []
                elif line:
                    cur.append(line)
        if cur:
            cands.append(cur)
        stats["sentences"] += 1

    rows = []
    seen = set()
    for lines in cands:
        toks = parse_sentence(lines)
        if len(toks) < 4 or len(toks) > 30:
            stats["skip_len"] += 1
            continue
        kana, expected = [], []
        bad = False
        for form, upos, lform, pron, _space in toks:
            if upos in ("PROPN", "SYM", "X"):
                bad = True
                break
            if any(c.isascii() and c.isalnum() for c in form):
                bad = True
                break
            if upos == "PUNCT":
                kana.append(form)
                expected.append(form)
                continue
            if all(c in KANA for c in form):
                rd = form
            elif upos in ("VERB", "ADJ", "AUX") and pron:
                # 活用形要用表层发音（行っ→イッ）；名词要用词条读音（先生→センセイ），
                # 因为 pron 会把长音写成「ー」（センセー），那不是用户实际键入的假名。
                rd = fix_long_vowel(kata_to_hira(pron))
            elif lform:
                rd = kata_to_hira(lform)
            elif pron:
                rd = kata_to_hira(pron)
            else:
                bad = True
                break
            if not rd or any(not (c in KANA or c == "ー") for c in rd):
                bad = True
                break
            kana.append(rd)
            expected.append(form)
        if bad:
            stats["skip_token"] += 1
            continue
        kana_s = "".join(kana)
        exp_s = "".join(expected)
        if not (6 <= len(kana_s) <= 60 and len(exp_s) <= 60):
            stats["skip_len2"] += 1
            continue
        if not any(KANJI(c) for c in exp_s):
            stats["skip_nokanji"] += 1
            continue
        if any(c not in KANA and c not in PUNCT_OK for c in kana_s):
            stats["skip_charset"] += 1
            continue
        if kana_s in seen:
            stats["skip_dup"] += 1
            continue
        seen.add(kana_s)
        rows.append((kana_s, exp_s))

    stats["candidates"] = len(rows)
    # 均匀抽样，跨 dev/test 与不同文档分散，不按难度挑
    step = max(1, len(rows) // args.count)
    picked = rows[::step][: args.count]
    with open(args.output, "w", encoding="utf-8") as f:
        for kana_s, exp_s in picked:
            f.write(f"ja\t{kana_s}\t{exp_s}\n")
    print(" ".join(f"{k}={v}" for k, v in stats.items()))
    print(f"picked={len(picked)} -> {args.output}")
    for kana_s, exp_s in picked[:8]:
        print(f"  {kana_s}  →  {exp_s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
