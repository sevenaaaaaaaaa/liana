#!/usr/bin/env python3
"""Build the read-only mobile T9/Wubi/glide index from pinned source data."""
import argparse
import hashlib
import json
import re
import sqlite3
from pathlib import Path

GROUPS = {letter: str(n) for n, group in enumerate(['abc','def','ghi','jkl','mno','pqrs','tuv','wxyz'], 2) for letter in group}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pinyin', type=Path)
    parser.add_argument('wubi', type=Path)
    parser.add_argument('english', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    vendor = args.wubi.parent.parent
    for package in ['Wubi86', 'Handwriting']:
        source = json.loads((vendor / package / 'SOURCE.json').read_text())
        for name, expected in source['files'].items():
            actual = hashlib.sha256((vendor / package / name).read_bytes()).hexdigest()
            if actual != expected:
                raise ValueError(f'Vendored resource hash mismatch: {package}/{name}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.unlink(missing_ok=True)
    db = sqlite3.connect(args.output)
    db.execute('CREATE TABLE words(word TEXT,code TEXT,digits TEXT,freq INTEGER,kind TEXT,first TEXT,last TEXT)')
    rows = []
    for line in args.pinyin.read_text().splitlines():
        fields = line.split('\t')
        if len(fields) < 3:
            continue
        word, code, frequency = fields[:3]
        code = re.sub('[^a-z]', '', code.lower().replace('ü','v'))
        if not code:
            continue
        rows.append((word,code,''.join(GROUPS.get(c,'') for c in code),int(frequency),'pinyin',code[0],code[-1]))
    body = False
    for line in args.wubi.read_text().splitlines():
        if line.strip() == '...':
            body = True
            continue
        if not body or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) < 2:
            continue
        word, code = fields[:2]
        if re.fullmatch('[a-y]{1,4}', code):
            try:
                frequency = int(float(fields[2].strip('%'))) if len(fields) > 2 else 1000
            except ValueError:
                frequency = 1000
            rows.append((word,code,'',max(1,frequency),'wubi',code[0],code[-1]))
    for rank,line in enumerate(args.english.read_text().splitlines()):
        word = line.split()[0] if line.split() else ''
        if re.fullmatch('[a-z]{2,24}',word):
            rows.append((word,word,'',max(1,50000-rank),'en',word[0],word[-1]))
    db.executemany('INSERT INTO words VALUES(?,?,?,?,?,?,?)',rows)
    db.executescript('CREATE INDEX code_lookup ON words(kind,code); CREATE INDEX digit_lookup ON words(kind,digits); CREATE INDEX glide_lookup ON words(kind,first,last,freq DESC);')
    db.commit()
    print('Mobile index:',dict(db.execute('SELECT kind,COUNT(*) FROM words GROUP BY kind')))
    db.close()

if __name__ == '__main__':
    main()
