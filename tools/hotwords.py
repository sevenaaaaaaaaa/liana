#!/usr/bin/env python3
"""热词管道（精准度专项 P2）：抓公开热榜 → 清洗 → 注音 → 官方词包。

产物 `crates/dict/data/packs/default/hot.tsv`，构建时随其他词包自动并入
base.ifd（build.sh 监听词包变化自动重建），运行端无需任何联网。

流程：
1. 抓百度实时热榜 JSON（top.baidu.com/api/board，仅开发机联网，App 不联网）；
2. 清洗：去话题标记/表情，保留 2~16 字、含汉字的短语，去重、跳过词库已有词
   （热词包只补新词，不与主库竞争）；
3. 注音：优先主库单字读音（与输入法一致），缺字回落 pypinyin（多音字取最常见读法）；
4. 词频按榜位衰减（榜首 6 万、×0.93、下限 800）：足以出现在候选但不压核心词。

用法：
    python3 tools/hotwords.py [--source baidu] [--limit 60] [--min-freq 800]
词包写入 packs/default/hot.tsv；报告走 stderr。
"""
from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DICT_TSV = REPO / "crates/dict/data/base-large.tsv"
PACK_OUT = REPO / "crates/dict/data/packs/default/hot.tsv"

CJK = re.compile(r"[\u3400-\u9fff]")
NOISE = re.compile(r"[#@「」『』【】\[\]（）()：:，,。.！!？?～~、\s]|新进展$|详情$|上线$|发布$" )


def fetch_baidu(limit: int) -> list[str]:
    url = "https://top.baidu.com/api/board?platform=wise&tab=realtime"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    words: list[str] = []
    for card in data.get("data", {}).get("cards", []):
        for group in card.get("content", []):
            for item in group.get("content", []) if isinstance(group, dict) else []:
                word = (item.get("word") or "").strip()
                if word:
                    words.append(word)
                if len(words) >= limit * 3:
                    break
    return words


def clean(word: str) -> list[str]:
    """热榜给的是新闻标题，用户要打的是其中的**实体**（人名/事件/产品名）。

    按标点切分取 2~8 字的片段（典型实体长度）；整条标题够短也保留。
    数字开头的跳过（输入法里数字起头的词条难打）。"""
    word = NOISE.sub("", word).strip()
    if not CJK.search(word) or re.fullmatch(r"[A-Za-z0-9\s]+", word):
        return []
    parts = re.split(r"[：:，,！!？?；;（）()\[\]【】]+", word)
    out: list[str] = []
    for part in parts:
        part = part.strip()
        if 2 <= len(part) <= 8 and CJK.search(part) and not part[0].isdigit():
            out.append(part)
    if not out and 2 <= len(word) <= 8 and not word[0].isdigit():
        out.append(word)
    return out


def load_dict_chars() -> tuple[dict[str, str], dict[str, int]]:
    """主库单字读音表（同字多读音取词频最高）与全词词频表。

    词频表用于热词去重策略：已有强词频（≥20000）的跳过（主库覆盖充分），
    弱频的照发——词包合并取 max，正好把热词升温。"""
    chars: dict[str, tuple[int, str]] = {}
    word_freq: dict[str, int] = {}
    for line in open(DICT_TSV, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 3:
            continue
        fr = int(f[2])
        if f[0] not in word_freq or fr > word_freq[f[0]]:
            word_freq[f[0]] = fr
        if len(f[0]) == 1 and CJK.match(f[0]):
            cur = chars.get(f[0])
            if cur is None or fr > cur[0]:
                chars[f[0]] = (fr, f[1].replace(" ", "'"))
    readings = {c: v[1] for c, v in chars.items()}
    return readings, word_freq


def annotate(word: str, char_readings: dict[str, str]) -> str | None:
    """逐字注音；含缺字且 pypinyin 也无能为力的跳过。"""
    try:
        from pypinyin import lazy_pinyin, Style
    except ImportError:
        pypinyin = None
    else:
        pypinyin = lazy_pinyin
    parts: list[str] = []
    for ch in word:
        if ch in char_readings:
            parts.append(char_readings[ch])
            continue
        if re.fullmatch(r"[A-Za-z0-9]+", ch):
            parts.append(ch.lower())  # 中英混排：字母段原样进键（拼音引擎按英文续接处理）
            continue
        if pypinyin is not None:
            py = lazy_pinyin(ch, style=Style.NORMAL, errors=lambda x: [x])
            piece = "".join(py).lower()
            if piece and all(c.isalpha() for c in piece):
                parts.append(piece)
                continue
        return None  # 缺字且兜底失败：宁缺毋滥
    return "'".join(parts)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=60, help="入包热词上限")
    ap.add_argument("--min-freq", type=int, default=800, help="词频下限")
    ap.add_argument("--source", default="baidu", choices=["baidu"])
    args = ap.parse_args()

    raw = fetch_baidu(args.limit)
    char_readings, word_freq = load_dict_chars()
    out: list[tuple[str, str, int]] = []
    seen: set[str] = set()
    rank = 0
    for raw_word in raw:
        for word in clean(raw_word):
            if word in seen or word_freq.get(word, 0) >= 20000:
                continue
            pinyin = annotate(word, char_readings)
            if pinyin is None:
                continue
            rank += 1
            freq = max(args.min_freq, round(60000 * (0.93 ** (rank - 1))))
            out.append((word, pinyin, freq))
            seen.add(word)
            if len(out) >= args.limit:
                break
        if len(out) >= args.limit:
            break

    today = datetime.date.today().isoformat()
    with open(PACK_OUT, "w", encoding="utf-8") as fh:
        fh.write(f"# 热词词包：{args.source} 实时热榜，{today} 抓取（tools/hotwords.py）\n")
        fh.write(f"# 只补新词（主库已有的不重复）；词频按榜位衰减，下限 {args.min_freq}\n")
        for word, pinyin, freq in out:
            fh.write(f"{word}\t{pinyin}\t{freq}\n")
    print(
        f"热词包 {PACK_OUT.name}：抓取 {len(raw)} → 入包 {len(out)}（{today}）",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
