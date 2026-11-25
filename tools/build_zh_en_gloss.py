#!/usr/bin/env python3
"""从 CC-CEDICT 生成「中文→英文」候选对照表（crates/gloss/data/zh-en.tsv）。

为什么要这张表：用户要的是「打中文，候选里直接出英文」。内核原来只有
`en-glossary.tsv`（540 条）与 `multilang.tsv`（100 条），够不上日常用词；
CC-CEDICT 有 12.5 万词条，是本机能拿到的最大离线中英表。

用法：
  curl -L -o /tmp/cedict.txt.gz https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz
  gzip -dc /tmp/cedict.txt.gz > /tmp/cedict.txt
  python3 tools/build_zh_en_gloss.py /tmp/cedict.txt crates/gloss/data/zh-en.tsv --limit 30000

裁剪规则（都是为了「候选里那一格能看」）：
- 释义去掉括号补充语，只取第一义项，超过 3 个词或 24 字符的丢弃；
- 丢弃 variant/surname/abbr/see also 这类字典编排语（用户要的是词义，不是词源）；
- 与主词库 base-large.tsv 取交集并按词频排序，最后按 --limit 截断——
  查不到的词不如不给，给一个生僻义反而会污染候选栏。
许可：CC-CEDICT 为 CC BY-SA 4.0（见 crates/dict/data/SOURCES.md 的署名段）。
"""

import argparse
import re
import sys
from pathlib import Path

ENTRY = re.compile(r"^(\S+) (\S+) \[([^\]]*)\] /(.*)/$")
PAREN = re.compile(r"\([^)]*\)")
# 打分时忽略的虚词：不然 "easy to" 靠 to 的 3000 万词频压过 "good"。
STOPWORDS = frozenset(
    "to of a an the and or in on for with that this it as at by from up out into over".split()
)

DROP_MARKERS = (
    "variant of",
    "old variant",
    "surname",
    "abbr. for",
    "see also",
    "see ",
    "used in",
    "classifier",
    "CL:",
    "Japanese variant",
    "Taiwan pr.",
    "erhua variant",
)


def clean(definition: str) -> str | None:
    text = PAREN.sub("", definition).strip()
    if not text:
        return None
    low = text.lower()
    if any(marker.lower() in low for marker in DROP_MARKERS):
        return None
    # 词义里常见的 "to do something" 保留（动词就是这个词义），但去掉多余的并列。
    text = text.split(";")[0].strip().rstrip(",")
    if not text or not text.isascii():
        return None
    # 候选栏那一格放 "to be" 没人要：去掉动词不定式前缀，留下词本身。
    if text.startswith("to ") and len(text.split()) <= 2:
        text = text[3:]
    return text


def load_en_freqs(path: Path) -> dict[str, int]:
    """英文词频：用来在多个释义里挑「最像日常词」的那条。

    没有它就只能按顺序或长度猜：密码 的 CEDICT 首义是 cipher，谢谢 的长度规则
    会挑到 thank —— 都是字典顺序，不是用户嘴里的词。
    """
    freqs: dict[str, int] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            try:
                freqs[parts[0].lower()] = int(parts[1])
            except ValueError:
                continue
    return freqs


def load_freqs(dict_path: Path) -> dict[str, int]:
    freqs: dict[str, int] = {}
    with dict_path.open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            word, _pinyin, freq = parts[0], parts[1], parts[2]
            try:
                freqs[word] = int(freq)
            except ValueError:
                continue
    return freqs


def build(cedict: Path, freqs: dict[str, int], en_freqs: dict[str, int],
          limit: int) -> list[tuple[str, str, int]]:
    best: dict[str, str] = {}
    with cedict.open(encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            match = ENTRY.match(line.rstrip("\n"))
            if not match:
                continue
            _traditional, simplified, _pinyin, raw_defs = match.groups()
            # 只收多字词：单字的英文释义歧义太大（好 → good/well/so），
            # 放进候选栏只是噪音；用户打单字时中文候选本来就够用。
            if len(simplified) < 2 or simplified not in freqs:
                continue
            gloss = None
            best_score = -1.0
            for raw in raw_defs.split("/"):
                candidate = clean(raw)
                if not candidate:
                    continue
                if len(candidate) > 24 or len(candidate.split()) > 3:
                    continue
                # 用英文词频给释义打分：取释义里最常用的那个词做代表。
                # 「password」压过「cipher」、「work」压过「operate」、「thank you」压过「thank」。
                # 只看中心词（最后一个非虚词）："to be happy" 的中心词是 happy，
                # 不能让 be 的词频替它拿主意；"like" 自己就是中心词。
                words = [w.strip(".,!?").lower() for w in candidate.split()]
                head = next((w for w in reversed(words) if w and w not in STOPWORDS), "")
                score = en_freqs.get(head, 0)
                if score > best_score or (score == best_score and gloss and len(candidate) < len(gloss)):
                    gloss, best_score = candidate, score
            if not gloss:
                continue
            if simplified not in best or len(gloss) < len(best[simplified]):
                best[simplified] = gloss
    rows = [(word, gloss, freqs[word]) for word, gloss in best.items()]
    rows.sort(key=lambda row: (-row[2], row[0]))
    return rows[:limit]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("cedict", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--limit", type=int, default=30000)
    parser.add_argument("--freqs", type=Path, default=Path("crates/dict/data/base-large.tsv"))
    parser.add_argument("--en-freqs", type=Path, default=Path("crates/en/data/words.txt"))
    args = parser.parse_args()

    freqs = load_freqs(args.freqs)
    en_freqs = load_en_freqs(args.en_freqs)
    rows = build(args.cedict, freqs, en_freqs, args.limit)
    if not rows:
        print("没有生成任何条目：检查 CC-CEDICT 路径与词库交集", file=sys.stderr)
        return 1
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        handle.write("# 中文→英文候选对照（由 tools/build_zh_en_gloss.py 从 CC-CEDICT 生成，勿手改）\n")
        handle.write("# 来源：CC-CEDICT （https://www.mdbg.net/chinese/dictionary?page=cc-cedict），许 CC BY-SA 4.0\n")
        handle.write("# 格式：中文<TAB>英文；按词频降序，共 %d 条\n" % len(rows))
        for word, gloss, _freq in rows:
            handle.write(f"{word}\t{gloss}\n")
    size = args.out.stat().st_size
    print(f"写出 {len(rows)} 条（全为多字词），{size / 1024:.0f} KB -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
