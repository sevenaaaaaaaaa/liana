#!/usr/bin/env python3
"""Build a bounded mobile vocabulary while preserving common characters and abbreviation priors."""
import argparse
from pathlib import Path


def select_rows(source: Path, limit: int):
    rows = {}
    for line in source.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) < 3:
            continue
        word, pinyin = fields[:2]
        try:
            frequency = int(fields[2])
        except ValueError:
            continue
        key = (word, pinyin)
        rows[key] = max(rows.get(key, 0), frequency)
    # Rare characters in the desktop dictionary often carry an artificial frequency of 50.
    chosen = {key: freq for key, freq in rows.items() if len(key[0]) == 1 and freq >= 100}
    priors = source.parents[2] / 'pinyin/data/jianpin.tsv'
    wanted = set()
    if priors.exists():
        for line in priors.read_text().splitlines():
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
    return sorted(((word, py, freq) for (word, py), freq in chosen.items()), key=lambda row: (row[1], -row[2], row[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--limit', type=int, default=50_000)
    args = parser.parse_args()
    if args.limit < 10_000:
        parser.error('The mobile vocabulary needs at least 10000 entries.')
    rows = select_rows(args.source, args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(''.join(f'{word}\t{pinyin}\t{frequency}\n' for word, pinyin, frequency in rows))
    print(f'iOS vocabulary: {len(rows)} entries -> {args.output}')


if __name__ == '__main__':
    main()
