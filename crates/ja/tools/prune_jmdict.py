#!/usr/bin/env python3
"""JMdict_e.gz → crates/ja/data/jmdict.tsv（常用词剪枝 + 常用活用形展开）

用法（在仓库根目录运行）：
    python3 crates/ja/tools/prune_jmdict.py \
        --input crates/ja/data/.cache/JMdict_e.gz \
        --output crates/ja/data/jmdict.tsv \
        --max 30000 --stats

输入：EDRDG 的 JMdict_e（UTF-8 XML，内部 DTD 自带实体定义）。
输出：4 列 TSV，按读音排序：
    reading <TAB> surface <TAB> pos <TAB> score

- reading：平假名（片假名统一转平假名，供罗马字→假名的输入串直接查表）
- surface：首选表记；没有汉字表记时等于读音
- pos：粗词性，取值与 matrix.bin 同一套 tagset（见 COARSE）
- score：1..100 的整数权重（由 news/ichi/spec/gai/nf 优先标签换算），
  运行时按 -ln(score/Σscore) 转成词成本

选词规则（可复现、无人工名单）：
1. 有任一优先标签（news1/2、ichi1/2、spec1/2、gai1/2、nf01..nf48）→ 候选；
2. 语法词（助词/助动词/接续词/感叹词/代词/数词/量词/前缀/后缀）即使无标签也保留；
3. 按 score 降序取前 --max 条（按词条计，不含活用形）；同 (reading, surface)
   去重，保留 score 最高的一条。

活用形展开（让「たべました」能出「食べました」，而不只是词典形「食べる」）：
- 动词生成 ます / ました / ません / て / た / ない / なかった 七形；
- イ形容词生成 く / かった / くない / くなかった；ナ形容词生成 な / に / だ / だった；
- 生成形继承词条词性与 score-3，不参与 --max 计数。

许可证：JMdict 数据由 EDRDG 以 CC BY-SA 4.0 提供；本脚本产出的 TSV 是其衍生
作品，同样按 CC BY-SA 4.0 分发。见 crates/ja/data/SOURCES.md。
"""

import argparse
import gzip
import math
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter

# JMdict 词性实体名 → 粗词性（与 matrix.bin 的 tagset 一致）
COARSE = {
    "n": "NOUN", "n-adv": "NOUN", "n-t": "NOUN", "n-suf": "PART", "n-pref": "PREF",
    "vs": "NOUN", "vs-s": "VERB", "vs-i": "VERB",
    "adj-i": "ADJ", "adj-ix": "ADJ", "adj-na": "ADJ", "adj-no": "ADJ",
    "adj-pn": "ADJ", "adj-f": "ADJ", "adj-t": "ADJ", "adj": "ADJ",
    "adv": "ADV", "adv-to": "ADV",
    "v1": "VERB", "v1-s": "VERB", "v5": "VERB", "v5aru": "VERB", "v5b": "VERB",
    "v5g": "VERB", "v5k": "VERB", "v5k-s": "VERB", "v5m": "VERB", "v5n": "VERB",
    "v5r": "VERB", "v5r-i": "VERB", "v5s": "VERB", "v5t": "VERB", "v5u": "VERB",
    "v5u-s": "VERB", "v5uru": "VERB", "v5z": "VERB", "vk": "VERB", "vn": "VERB",
    "vz": "VERB", "vi": "VERB", "vt": "VERB", "iv": "VERB",
    "prt": "ADP",
    "aux": "AUX", "aux-v": "AUX", "aux-adj": "AUX", "cop": "AUX",
    "conj": "CCONJ",
    "int": "INTJ",
    "pn": "PRON",
    "num": "NUM",
    "ctr": "NOUN",
    "pref": "PREF",
    "suf": "PART",
    "exp": "X", "id": "X",
}

# 无优先标签也必须保留的语法词性（助词、助动词、接续词、感叹词、代词等）
GRAMMAR = {"ADP", "AUX", "CCONJ", "INTJ", "PRON", "NUM", "PREF", "PART"}

PRI = {
    "news1": 60, "news2": 40,
    "ichi1": 60, "ichi2": 40,
    "spec1": 40, "spec2": 30,
    "gai1": 35, "gai2": 25,
}
NF_RE = re.compile(r"^nf(\d{2})$")
MAX_READING = 16
MAX_READINGS_PER_ENTRY = 3

# JMdict 里没有独立词条的现代语法词（助动词/接续），不补就会把「たべました」
# 拆成假名。这一小张表由本项目维护（CC BY-SA 4.0 之外的自有内容，按 AGPL 发布）。
GRAMMAR_SUPPLEMENT = [
    # 助词：JMdict 没有独立的现代「の」，且 は/が/で 会被同音汉字压过。
    ("の", "の", "ADP", 20000),
    ("は", "は", "ADP", 20000),
    ("が", "が", "ADP", 20000),
    ("を", "を", "ADP", 20000),
    ("に", "に", "ADP", 20000),
    ("で", "で", "ADP", 20000),
    ("と", "と", "ADP", 20000),
    ("も", "も", "ADP", 20000),
    ("て", "て", "ADP", 20000),
    ("へ", "へ", "ADP", 15000),
    ("や", "や", "ADP", 12000),
    ("から", "から", "ADP", 12000),
    ("まで", "まで", "ADP", 10000),
    ("より", "より", "ADP", 8000),
    ("だけ", "だけ", "ADP", 8000),
    ("しか", "しか", "ADP", 6000),
    ("など", "など", "ADP", 6000),
    ("ながら", "ながら", "ADP", 4000),
    ("ので", "ので", "CCONJ", 6000),
    ("のに", "のに", "CCONJ", 5000),
    ("けど", "けど", "CCONJ", 5000),
    # 助动词：JMdict 没有独立的 ます 系列；いた/い 是 いる 的连用形，补上才能
    # 把「思っていた」切成 思っ + て + いた，而不是 思っ + て + 板。
    ("ます", "ます", "AUX", 15000),
    ("ました", "ました", "AUX", 12000),
    ("ません", "ません", "AUX", 10000),
    ("ませんでした", "ませんでした", "AUX", 8000),
    ("です", "です", "AUX", 15000),
    ("でした", "でした", "AUX", 10000),
    ("だ", "だ", "AUX", 15000),
    ("だった", "だった", "AUX", 10000),
    ("だろう", "だろう", "AUX", 8000),
    ("でしょう", "でしょう", "AUX", 8000),
    ("た", "た", "AUX", 20000),
    ("い", "い", "AUX", 3500),
    ("いた", "いた", "AUX", 3500),
    ("いて", "いて", "AUX", 3500),
    ("います", "います", "AUX", 4000),
    ("いました", "いました", "AUX", 3500),
    ("ない", "ない", "AUX", 10000),
    ("なかった", "なかった", "AUX", 8000),
]

# 五段动词：词典形词尾 → 各活用词干（表面/读音同规则，只换最后一个假名）
GODAN = {
    "う": ("い", "わ", "っ", "っ"),
    "く": ("き", "か", "い", "い"),
    "ぐ": ("ぎ", "が", "い", "い"),
    "す": ("し", "さ", "し", "し"),
    "つ": ("ち", "た", "っ", "っ"),
    "ぬ": ("に", "な", "ん", "ん"),
    "ぶ": ("び", "ば", "ん", "ん"),
    "む": ("み", "ま", "ん", "ん"),
    "る": ("り", "ら", "っ", "っ"),
}
# て/た 的浊音化：ぐ/ぬ/ぶ/む → で/だ
TE_DAKUTEN = {"ぐ", "ぬ", "ぶ", "む"}
ICHIDAN_ENDINGS = set("きぎしじちにひびみりえけげせぜてでねへべめれ")


def kata_to_hira(s: str) -> str:
    return "".join(chr(ord(c) - 0x60) if 0x30A1 <= ord(c) <= 0x30F6 else c for c in s)


def load_entity_map(path: str) -> dict[str, str]:
    """从文件内联 DTD 读出 实体值→实体名，用来把 ET 展开后的英文词性还原成短名。"""
    out = {}
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            m = re.match(r'<!ENTITY\s+([A-Za-z0-9_-]+)\s+"([^"]*)">', line)
            if m:
                out[m.group(2)] = m.group(1)
            if line.startswith("]>"):
                break
    return out


def priority_score(tags) -> int:
    best = 0
    for t in tags:
        if t in PRI:
            best = max(best, PRI[t])
        else:
            m = NF_RE.match(t)
            if m:
                n = int(m.group(1))
                if 1 <= n <= 48:
                    best = max(best, 100 - n)
    return best


def inflect(surface: str, reading: str, pos_entity: str):
    """返回 [(surface, reading)] 的常用活用形（不含词典形）。"""
    if len(surface) < 2 or len(reading) < 2:
        return []
    out = []
    if reading == "くる" and surface == "来る":
        return [
            ("来ます", "きます"), ("来ました", "きました"), ("来ません", "きません"),
            ("来て", "きて"), ("来た", "きた"), ("来ない", "こない"),
            ("来なかった", "こなかった"), ("来", "き"), ("来", "こ"),
        ]
    if pos_entity.startswith("v5") or pos_entity in ("vk", "vn"):
        tail = reading[-1]
        s_tail, r_tail = surface[-1], reading[-1]
        if tail not in GODAN:
            return []
        renyou, mizen, te_stem, ta_stem = GODAN[tail]
        base_s, base_r = surface[:-1], reading[:-1]
        # 行く：て/た 是 行って/行った，不是 行いて
        if reading in ("いく", "ゆく"):
            te_stem = ta_stem = "っ"
        dakuten = "だ" if tail in TE_DAKUTEN else "た"
        out += [
            (base_s + renyou + "ます", base_r + renyou + "ます"),
            (base_s + renyou + "ました", base_r + renyou + "ました"),
            (base_s + renyou + "ません", base_r + renyou + "ません"),
            (base_s + te_stem + "て", base_r + te_stem + "て"),
            (base_s + ta_stem + dakuten, base_r + ta_stem + dakuten),
            (base_s + mizen + "ない", base_r + mizen + "ない"),
            (base_s + mizen + "なかった", base_r + mizen + "なかった"),
            # 裸词干：让「食べました」「書いていました」这类复合活用有节点可落
            (base_s + renyou, base_r + renyou),
            (base_s + mizen, base_r + mizen),
            (base_s + te_stem, base_r + te_stem),
        ]
    elif pos_entity in ("v1", "v1-s", "vz"):
        if not reading.endswith("る") or reading[-2] not in ICHIDAN_ENDINGS:
            return []
        base_s, base_r = surface[:-1], reading[:-1]
        out += [
            (base_s + "ます", base_r + "ます"),
            (base_s + "ました", base_r + "ました"),
            (base_s + "ません", base_r + "ません"),
            (base_s + "て", base_r + "て"),
            (base_s + "た", base_r + "た"),
            (base_s + "ない", base_r + "ない"),
            (base_s + "なかった", base_r + "なかった"),
            (base_s, base_r),
        ]
    elif pos_entity in ("vs-i", "vs-s"):
        # する 及其复合（勉強する 等）：词干 + し…
        if reading.endswith("する"):
            base_s, base_r = surface[:-2], reading[:-2]
            out += [
                (base_s + "します", base_r + "します"),
                (base_s + "しました", base_r + "しました"),
                (base_s + "しません", base_r + "しません"),
                (base_s + "して", base_r + "して"),
                (base_s + "した", base_r + "した"),
                (base_s + "しない", base_r + "しない"),
                (base_s + "しなかった", base_r + "しなかった"),
            ]
        elif reading.endswith("くる") and surface.endswith("来る"):
            base_s = surface[:-2]
            out += [
                (base_s + "来ます", "きます"),
                (base_s + "来ました", "きました"),
                (base_s + "来ません", "きません"),
                (base_s + "来て", "きて"),
                (base_s + "来た", "きた"),
                (base_s + "来ない", "こない"),
                (base_s + "来なかった", "こなかった"),
            ]
    elif pos_entity in ("adj-i", "adj-ix"):
        if not reading.endswith("い") or not surface.endswith("い"):
            return []
        base_s, base_r = surface[:-1], reading[:-1]
        out += [
            (base_s + "く", base_r + "く"),
            (base_s + "かった", base_r + "かった"),
            (base_s + "くない", base_r + "くない"),
            (base_s + "くなかった", base_r + "くなかった"),
        ]
    elif pos_entity == "adj-na":
        out += [
            (surface + "な", reading + "な"),
            (surface + "に", reading + "に"),
            (surface + "だ", reading + "だ"),
            (surface + "だった", reading + "だった"),
        ]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="crates/ja/data/.cache/JMdict_e.gz")
    ap.add_argument("--output", default="crates/ja/data/jmdict.tsv")
    ap.add_argument("--max", type=int, default=30000)
    ap.add_argument("--freq", default="crates/ja/data/.cache/ja-freq.tsv",
                    help="UD 词频表（corpus_stats.py 产出）；缺省时只用 JMdict 优先标签")
    ap.add_argument("--surface-freq", default="crates/ja/data/.cache/ja-surface-freq.tsv",
                    help="Tatoeba 表面频次（tatoeba_freq.py 产出）；更接近真实书写分布")
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args()

    freq = {}
    try:
        with open(args.freq, encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    freq[parts[0]] = int(parts[1])
    except FileNotFoundError:
        print(f"warning: 词频表 {args.freq} 不存在，仅用 JMdict 标签", file=sys.stderr)
    sfreq = {}
    try:
        with open(args.surface_freq, encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    sfreq[parts[0]] = int(parts[1])
    except FileNotFoundError:
        print(f"warning: 表面频次 {args.surface_freq} 不存在，仅用 UD 词频", file=sys.stderr)

    ent2name = load_entity_map(args.input)
    rows = {}  # (reading, surface) -> (score, pos, seq)
    lemmas = []  # (score, seq, surface, [readings], pos, pos_entity)
    total = tagged = grammar_only = skipped = 0
    tag_hist = Counter()

    with gzip.open(args.input, "rb") as f:
        for _ev, el in ET.iterparse(f, events=("end",)):
            if el.tag != "entry":
                continue
            total += 1
            seq = int(el.findtext("ent_seq") or 0)
            kebs = [(k.findtext("keb") or "").strip() for k in el.findall("k_ele")]
            kebs = [k for k in kebs if k]
            rebs = [(r.findtext("reb") or "").strip() for r in el.findall("r_ele")]
            rebs = [r for r in rebs if r]
            pris = [p.text or "" for p in el.iter("ke_pri")] + [p.text or "" for p in el.iter("re_pri")]
            # 词性与 uk 只看第一个义项：行く 的第 10-12 义项才是 uk（ auxiliary/口语），
            # 按全条目判断会把「行きました」写成假名。
            sense1 = el.find("sense")
            sense_pos = sense1.findall("pos") if sense1 is not None else []
            sense_misc = sense1.findall("misc") if sense1 is not None else []
            pos_names = [ent2name.get((p.text or "").strip(), (p.text or "").strip()) for p in sense_pos]
            coarse = []
            for p in pos_names:
                c = COARSE.get(p)
                if c and c not in coarse:
                    coarse.append(c)
            score = priority_score(pris)
            # 语料词频：JMdict 的 nf/news 排名对「行く」这类词缺失，靠语料计数补。
            # score 只用于选词排序；写进 TSV 的是 weight（成本 = -ln(weight/Σweight)），
            # 这样 は（语料 4839 次）和 刃（0 次）不会都被压成 99 分而无法区分。
            # 只在「没有汉字表记」时才拿读音去查词频：否则 刃/歯/波 会继承
            # 助词「は」的 4839 次计数，权重和真词一样高。
            keys = kebs if kebs else ([rebs[0]] if rebs else [])
            hits = [freq.get(k, 0) for k in keys]
            cnt = max(hits) if hits else 0
            if cnt:
                score = max(score, min(99, 50 + int(12 * math.log1p(cnt))))
            grammar = any(c in GRAMMAR for c in coarse)
            if score == 0 and not grammar:
                el.clear()
                continue
            tagged += 1 if score > 0 else 0
            grammar_only += 1 if score == 0 and grammar else 0
            if not rebs:
                el.clear()
                continue
            readings = []  # (原始书写形, 查表用平假名)
            for r in rebs[:MAX_READINGS_PER_ENTRY]:
                orig = r
                r = kata_to_hira(r)
                if not r or len(r) > MAX_READING:
                    continue
                if any(not (0x3041 <= ord(c) <= 0x3096 or c == "ー") for c in r):
                    continue
                if all(rd != r for _o, rd in readings):
                    readings.append((orig, r))
            if not readings:
                skipped += 1
                el.clear()
                continue
            misc = [ent2name.get((m.text or "").strip(), (m.text or "").strip()) for m in sense_misc]
            pos = coarse[0] if coarse else "X"
            if score == 0:
                score = 55
            base_weight = max(1, cnt + score // 2)
            # 假名表记：
            # - 无汉字表记（バイオリン/ヴァイオリン）：每条读音用各自的原始书写形；
            # - 有汉字表记但通常写假名（今日は）：所有读音变体统一落到首选假名形
            #   （こんにちわ → こんにちは），汉字形降权保留。
            # 读音按出现顺序衰减（1, 1/4, 1/16）：幅 的冷僻读音「の」不能继承「はば」的权重。
            multi = len(readings) > 1
            for ridx, (orig, rd) in enumerate(readings):
                w = max(1, base_weight // (4 ** ridx))
                if not kebs:
                    surfaces = [(orig, w)]
                elif "uk" in misc:
                    surfaces = [(readings[0][0], w), (kebs[0], max(1, w // 6))]
                else:
                    surfaces = [(kebs[0], w)]
                for surface, wt in surfaces:
                    if not surface or any(ch.isspace() or ch == "\t" for ch in surface):
                        continue
                    # Tatoeba 表面频次只对「单一读音」或「假名表记」生效：
                    # 今日は 的表面计数 1233 混了「きょうは」，直接套到「こんにちは」
                    # 上会把问候语压掉。多读音的汉字表记继续用 UD 的词条频次。
                    if not multi or surface == readings[0][0]:
                        wt = max(wt, sfreq.get(surface, 0) // (4 ** ridx))
                    key = (rd, surface)
                    if key not in rows or rows[key][0] < wt:
                        rows[key] = (wt, pos, seq)
            # 活用形：uk 词（居る/有る/する）用假名词干，否则「居り」会顶掉「おり」
            p_ent = next((p for p in pos_names if p in COARSE), "")
            if p_ent and kebs:
                lemma_surface = readings[0][0] if "uk" in misc else kebs[0]
                lemmas.append((score, seq, base_weight, lemma_surface, readings[0][1], pos, p_ent))
            tag_hist.update(pris)
            el.clear()

    # 词条按 score 截断，再展开活用形（活用形不占 3 万词名额）
    lemmas.sort(key=lambda x: (-x[0], x[1]))
    if len(lemmas) > args.max:
        lemmas = lemmas[: args.max]
    forms = 0
    for _score, seq, base_w, surface, reading, pos, p_ent in lemmas:
        for s2, r2 in inflect(surface, reading, p_ent):
            if not r2 or len(r2) > MAX_READING:
                continue
            if any(not (0x3041 <= ord(c) <= 0x3096 or c == "ー") for c in r2):
                continue
            key = (r2, s2)
            wt = max(1, base_w * 7 // 10, sfreq.get(s2, 0))
            if key not in rows or rows[key][0] < wt:
                rows[key] = (wt, pos, seq)
                forms += 1

    for rd, sfc, pos, wt in GRAMMAR_SUPPLEMENT:
        key = (rd, sfc)
        if key not in rows or rows[key][0] < wt:
            rows[key] = (wt, pos, 0)

    lines = [f"{r}\t{s}\t{pos}\t{wt}\n" for (r, s), (wt, pos, _seq) in rows.items()]
    lines.sort()
    with open(args.output, "w", encoding="utf-8") as f:
        f.writelines(lines)

    if args.stats:
        print(f"entries total      : {total}")
        print(f"lemmas selected    : {len(lemmas)}  (cap {args.max})")
        print(f"  with priority tag: {tagged}")
        print(f"  grammar-only     : {grammar_only}")
        print(f"skipped (bad kana) : {skipped}")
        print(f"inflected forms    : {forms}")
        print(f"rows written       : {len(lines)}")
        weights = sorted(w for w, _p, _s in rows.values())
        if weights:
            print(f"weight p50/p95/max : {weights[len(weights)//2]} / {weights[int(len(weights)*0.95)]} / {weights[-1]}")
        print(f"output bytes       : {sum(len(x.encode()) for x in lines)}")
        print("pos histogram      : " + ", ".join(f"{k}={v}" for k, v in Counter(v[1] for v in rows.values()).most_common()))
        print("top tags           : " + ", ".join(f"{k}={v}" for k, v in tag_hist.most_common(12)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
