#!/usr/bin/env python3
"""生成官方词包：crates/dict/data/packs/{default,optional}/*.tsv。

词包与 base-large.tsv 同格式、同词频尺度（`词<TAB>拼音(空格分隔)<TAB>词频`，「的」≈1e7）。
default/ 里的词包在构建 base.ifd 时合并进基础词库（同词同音取较大词频，所以词包只会补词、抬词频，
不会压低已有词）；optional/ 留给用户按需开启。

来源：
- packs/src/*.txt：本项目人工维护的应用 / 公司 / 口语 / 地名清单，按档位给词频
- 清华 THUOCL（MIT）：分领域词表，词频是新闻语料文档频次，按与基础词库的重合词校准到同一尺度
- chinese-xinhua idiom.json（MIT）：成语及其带调拼音

用法：
    pip install pypinyin
    git clone --depth 1 https://github.com/thunlp/THUOCL /tmp/THUOCL
    curl -sSL -o /tmp/idiom.json https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/idiom.json
    python3 tools/build_vocab_packs.py --thuocl /tmp/THUOCL/data --idioms /tmp/idiom.json
"""
import argparse
import json
import math
import re
import unicodedata
from pathlib import Path
from statistics import median

from pypinyin import Style, lazy_pinyin

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "crates/dict/data"
PACKS = DATA / "packs"

TIERS = {"A": 20000, "B": 8000, "C": 3000, "D": 1000, "E": 300}
# 人工清单 → 词包文件名
CURATED = {"apps": "apps", "companies": "companies", "slang": "slang", "places": "places-extra"}
# THUOCL 领域 → (词包, 是否默认开启)
THUOCL = {
    "IT": ("it", True),
    "caijing": ("finance", True),
    "diming": ("places", True),
    "food": ("food", True),
    "car": ("car", True),
    "lishimingren": ("people", False),
    "poem": ("poem", False),
    "law": ("law", False),
    "medical": ("medical", False),
    "animal": ("animal", False),
}
# 新词（基础词库里没有的）只按校准值的这个比例给分：它们大多比已有词冷门，不和老词抢首选
NEW_WORD_DAMP = 0.6
# 校准后低于这个词频的生僻条目不收（THUOCL 长尾里有不少噪声）
MIN_FREQ = 10
# 不在 THUOCL 成语表里的成语给的保底词频：整句打全时能出来，不会压过常用词
IDIOM_FLOOR = 60

HAN = re.compile(r"^[㐀-鿿]+$")


def pinyin(word):
    return " ".join(lazy_pinyin(word, style=Style.NORMAL, v_to_u=False))


def strip_tones(text):
    text = text.replace("ü", "v").replace("Ü", "v")
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return " ".join(re.findall(r"[a-zv]+", text.lower()))


def load_base():
    """基础词库：词 → 最大词频、(词, 拼音) 集合、全部合法音节。"""
    freq, pairs = {}, set()
    for line in open(DATA / "base-large.tsv", encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 3 or line.startswith("#"):
            continue
        w, p, fr = f[0], f[1], float(f[2] or 1)
        freq[w] = max(freq.get(w, 0), fr)
        pairs.add((w, p))
    syllables = {s for _, p in pairs for s in p.split()}
    return freq, pairs, syllables


def read_thuocl(path):
    text = open(path, encoding="utf-8-sig").read()
    return [(w, int(n)) for w, n in re.findall(r"([^\s\d]+)\s+(\d+)", text)]


def calibrate(rows, base):
    """THUOCL 文档频次 → 基础词库尺度：取重合词 log 比值的中位数。"""
    diffs = [math.log10(base[w]) - math.log10(n) for w, n in rows if w in base and n > 0]
    return median(diffs) if len(diffs) >= 50 else 0.0


def write_pack(path, header, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as out:
        for line in header:
            out.write(f"# {line}\n")
        out.write("# 格式：词<TAB>拼音（空格分隔）<TAB>词频（与 base-large.tsv 同尺度）\n")
        for w, p, fr in sorted(entries, key=lambda e: (-e[2], e[0])):
            out.write(f"{w}\t{p}\t{fr}\n")
    print(f"{path.relative_to(ROOT)}: {len(entries)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--thuocl", required=True, help="THUOCL 的 data 目录")
    ap.add_argument("--idioms", required=True, help="chinese-xinhua 的 idiom.json")
    args = ap.parse_args()
    base, pairs, syllables = load_base()

    # 人工清单
    for src, name in CURATED.items():
        entries = []
        for line in open(PACKS / "src" / f"{src}.txt", encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            word, tier = parts[0], parts[1]
            if not HAN.match(word):
                continue
            py = " ".join(parts[2:]) if len(parts) > 2 else pinyin(word)
            entries.append((word, py, TIERS[tier]))
        write_pack(PACKS / "default" / f"{name}.tsv",
                   [f"松萝官方词包 · {name}（本项目维护，AGPL-3.0-only）"], entries)

    # 成语：新华成语全量 + THUOCL 成语频次；已有成语按频次抬到合理位置
    thuocl_dir = Path(args.thuocl)
    cy_rows = read_thuocl(thuocl_dir / "THUOCL_chengyu.txt")
    cy_ratio = 10 ** calibrate(cy_rows, base)
    cy_freq = {w: n * cy_ratio for w, n in cy_rows}
    idioms = {}
    for item in json.load(open(args.idioms, encoding="utf-8")):
        w = item.get("word", "").strip()
        if len(w) >= 4 and HAN.match(w):
            idioms[w] = strip_tones(item.get("pinyin", "")) or pinyin(w)
    for w in cy_freq:
        if len(w) >= 4 and HAN.match(w) and w not in idioms:
            idioms[w] = pinyin(w)
    entries = []
    for w, py in idioms.items():
        # 新华成语表的拼音偶有录入错误（bia huan、li yie）：音节数不对或含非法音节就改用自动注音
        if len(py.split()) != len(w) or not all(s in syllables for s in py.split()):
            py = pinyin(w)
        target = max(IDIOM_FLOOR, round(cy_freq.get(w, 0)))
        if target > base.get(w, 0):
            entries.append((w, py, target))
    write_pack(PACKS / "default" / "idioms.tsv",
               ["松萝官方词包 · 成语（chinese-xinhua 成语表 + 清华 THUOCL 成语频次，MIT）"], entries)

    # THUOCL 其他领域：只补基础词库没有的词
    for domain, (name, default) in THUOCL.items():
        rows = read_thuocl(thuocl_dir / f"THUOCL_{domain}.txt")
        ratio = 10 ** calibrate(rows, base)
        entries = []
        for w, n in rows:
            if len(w) < 2 or not HAN.match(w) or w in base:
                continue
            fr = round(n * ratio * NEW_WORD_DAMP)
            if fr >= MIN_FREQ:
                entries.append((w, pinyin(w), fr))
        write_pack(PACKS / ("default" if default else "optional") / f"{name}.tsv",
                   [f"松萝官方词包 · {name}（清华 THUOCL_{domain}，MIT；只含基础词库没有的词）"], entries)


if __name__ == "__main__":
    main()
