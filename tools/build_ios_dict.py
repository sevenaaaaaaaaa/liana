#!/usr/bin/env python3
"""Build the bounded iOS dictionary tiers.

core: pick a frequency-ordered slice of base-large.tsv, always keeping every
single-character entry and the curated abbreviation priors. This keeps the
Rust dictionary small enough for the keyboard extension.
full: merge base-large with the official packs (same word+pinyin keeps the
larger frequency) for the fallback SQLite index.
"""
import argparse
from pathlib import Path

# core 词库里保留多少个常用字（GB2312 一二级字表约 6763，留出余量）。
CORE_CHARS = 9000


def read_rows(path):
    rows = {}
    text = path.read_text(encoding='utf-8')
    for line in text.splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) < 3:
            continue
        word, pinyin = fields[0].strip(), fields[1].strip()
        if not word or not pinyin:
            continue
        try:
            frequency = int(float(fields[2]))
        except ValueError:
            continue
        key = (word, pinyin)
        rows[key] = max(rows.get(key, 0), frequency)
    return rows


def merge_rows(rows, path):
    count = 0
    for key, frequency in read_rows(path).items():
        rows[key] = max(rows.get(key, 0), frequency)
        count += 1
    return count


def merge_dir(rows, directory):
    directory = Path(directory)
    paths = sorted(directory.glob('*.tsv'))
    total = 0
    for path in paths:
        total += merge_rows(rows, path)
    print('Merge %s: %d files, %d rows read' % (directory, len(paths), total))
    return total


def select_rows(source, limit):
    rows = read_rows(source)
    # Every character from the desktop dictionary stays available: a missing
    # glyph is much worse on a phone than a rare one taking a candidate slot.
    # 单字按字聚合，只保留最高频的两个读音，并且只留最常用的 CORE_CHARS 个字。
    # base-large 收了四万多个字（大量是 CJK 扩展区的生僻字，如「䫖」「䗞」），
    # 它们过去占掉 core 配额的一半，把三字/四字常用词挤出 iOS 词库——这正是
    # iOS 候选比 macOS 差的主因。生僻字仍留在 full 档的 SQLite 索引里。
    by_char = {}
    for (word, py), freq in rows.items():
        if len(word) != 1:
            continue
        readings = by_char.setdefault(word, [])
        readings.append((freq, py))
    hot_chars = sorted(by_char.items(), key=lambda kv: -max(f for f, _ in kv[1]))[:CORE_CHARS]
    chosen = {}
    for word, readings in hot_chars:
        readings.sort(reverse=True)
        for freq, py in readings[:2]:
            chosen[(word, py)] = freq
    priors = source.parents[2] / 'pinyin/data/jianpin.tsv'
    wanted = set()
    if priors.exists():
        for line in priors.read_text(encoding='utf-8').splitlines():
            if line and not line.startswith('#'):
                fields = line.split('\t')
                if len(fields) >= 2:
                    wanted.add(fields[1])
    for key, freq in rows.items():
        if key[0] in wanted:
            chosen[key] = freq
    for key, freq in sorted(rows.items(), key=lambda item: (-item[1], item[0])):
        if len(chosen) >= limit:
            break
        if len(key[0]) > 1:
            chosen[key] = freq
    print('Source %s: %d rows, %d single characters, %d chosen' % (
        source, len(rows), sum(1 for key in rows if len(key[0]) == 1), len(chosen)))
    return sorted(((word, py, freq) for (word, py), freq in chosen.items()),
                  key=lambda row: (row[1], -row[2], row[0]))


def merge_all(source, directories):
    rows = read_rows(source)
    print('Source %s: %d rows' % (source, len(rows)))
    for directory in directories:
        merge_dir(rows, directory)
    return sorted(((word, py, freq) for (word, py), freq in rows.items()),
                  key=lambda row: (row[1], -row[2], row[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--limit', type=int, default=100_000)
    parser.add_argument('--all', action='store_true',
                        help='write every merged row instead of selecting a slice')
    parser.add_argument('--merge-dir', action='append', default=[], type=Path,
                        help='merge every *.tsv in this directory (repeatable)')
    args = parser.parse_args()
    if not args.all and args.limit < 10_000:
        parser.error('The mobile vocabulary needs at least 10000 entries.')
    if args.all:
        rows = merge_all(args.source, args.merge_dir)
    else:
        if args.merge_dir:
            parser.error('--merge-dir is only valid together with --all')
        rows = select_rows(args.source, args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(''.join(
        '%s\t%s\t%d\n' % (word, pinyin, frequency)
        for word, pinyin, frequency in rows), encoding='utf-8')
    print('iOS vocabulary: %d entries -> %s' % (len(rows), args.output))


if __name__ == '__main__':
    main()
