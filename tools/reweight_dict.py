#!/usr/bin/env python3
"""用真实语料词频重排 base-large.tsv。

背景：rime-ice 的权重为配合其语法模型设计，常用词大量挤在同一档
（大家/等级/点击/好的/觉得 都≈500k），单靠它做 unigram 排序时首选经常不对。
这里用 wordfreq（多语料融合：字幕、维基、新闻、社交，CC BY-SA 4.0）给出的
真实词频做主信号，rime-ice 权重做兜底与读音分配：

1. 单调校准：按 rime 权重的对数分箱，取每箱 wordfreq 对数中位数，得到
   rime→语料尺度的映射，wordfreq 里查不到的词（多为「好的」这类被分词器
   拆开的短语）按校准后的 rime 值给分，不会被误判成冷门词。
2. 融合：两者都有时 log f = 0.75·log(语料) + 0.25·log(校准rime)。
3. 多音字/多读音词：语料给的是字形频率，按 rime 各读音权重占比分摊
   （「了」le 拿走几乎全部，liao 只分到一点）。
4. 本项目人工校准词表 base.tsv 中的词条取 max(新值, 旧值)，保持首屏优先。
5. 输出词频 = 10^(zipf-0.6)，「的」≈1e7，最低为 1。

用法：
    pip install wordfreq
    python3 tools/reweight_dict.py crates/dict/data/base-large.tsv crates/dict/data/base.tsv \
        crates/dict/data/modern.tsv \
        > /tmp/new.tsv && mv /tmp/new.tsv crates/dict/data/base-large.tsv
"""
import math
import sys
from collections import defaultdict
from statistics import median

from wordfreq import get_frequency_dict

from clean_junk_dict import clean_rows

ALPHA = 0.75


def load_tsv(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 2:
            continue
        freq = float(f[2]) if len(f) > 2 and f[2].strip() else 1.0
        rows.append((f[0], f[1], max(freq, 1.0)))
    return rows


def main():
    large, base = sys.argv[1], sys.argv[2]
    modern_path = sys.argv[3] if len(sys.argv) > 3 else None
    rows = load_tsv(large)
    modern = {}
    if modern_path:
        for w, p, fr in load_tsv(modern_path):
            modern[(w, p)] = fr
        have = {(w, p) for w, p, _ in rows}
        for (w, p), fr in modern.items():
            if (w, p) not in have:
                rows.append((w, p, 1.0))
    manual = {(w, p.replace("'", " ")): fr for w, p, fr in load_tsv(base)}
    wf = get_frequency_dict("zh", "best")

    # 单读音词条用于校准（避免多音字干扰）
    readings = defaultdict(list)
    for i, (w, p, fr) in enumerate(rows):
        readings[w].append(i)
    bins = defaultdict(list)
    for w, idx in readings.items():
        if len(idx) == 1 and w in wf:
            lr = math.log10(rows[idx[0]][2])
            bins[round(lr * 4) / 4].append(math.log10(wf[w]))
    keys = sorted(bins)
    table = []
    last = -99.0
    for k in keys:
        if len(bins[k]) < 20:
            continue
        m = max(median(bins[k]), last)  # 保持单调
        table.append((k, m))
        last = m

    def calib(lr):
        if lr <= table[0][0]:
            return table[0][1] - (table[0][0] - lr)
        if lr >= table[-1][0]:
            return table[-1][1] + (lr - table[-1][0])
        for (k0, v0), (k1, v1) in zip(table, table[1:]):
            if k0 <= lr <= k1:
                t = (lr - k0) / (k1 - k0) if k1 > k0 else 0
                return v0 + t * (v1 - v0)
        return table[-1][1]

    out = []
    for w, idx in readings.items():
        total = sum(rows[i][2] for i in idx)
        for i in idx:
            _, p, fr = rows[i]
            share = fr / total
            lr = calib(math.log10(fr))  # 已是语料尺度的 log10 概率
            if w in wf:
                lw = math.log10(wf[w] * share)
                lp = ALPHA * lw + (1 - ALPHA) * lr
            else:
                lp = lr
            zipf = lp + 9
            new = max(1, round(10 ** (zipf - 0.6)))
            if (w, p) in manual:
                new = max(new, round(fr))
            if (w, p) in modern:
                new = max(new, round(modern[(w, p)]))
            out.append((i, w, p, new))
    out.sort()
    # 精准度专项 P0-3：输出前清洗双虚字分词伪影（到的/是在/是有 类），
    # 规则与报告见 tools/clean_junk_dict.py。
    cleaned, details = clean_rows([(w, p, new) for _, w, p, new in out], wf)
    print(f"伪影清洗：删除 {len(details)} 条", file=sys.stderr)
    for w, p, new in cleaned:
        print(f"{w}\t{p}\t{new}")
    print(f"校准分箱 {len(table)} 个；语料命中 {sum(1 for w in readings if w in wf)}/{len(readings)} 词形",
          file=sys.stderr)


if __name__ == "__main__":
    main()
