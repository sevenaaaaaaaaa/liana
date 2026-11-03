#!/usr/bin/env python3
"""清洗 base-large.tsv 里的分词伪影词条（精准度专项 P0-3）。

背景：词库源自雾凇（八股文式语料词库）+ wordfreq 重加权，语料分词会把
「到+的」「是+在」这类跨词边界组合当成词条收进来（到的/是在/是有/还时/
是间…）。它们与真词同键竞争（道德/实在/石油/还是/时间），在候选列表里形成
可见的伪词噪声，还可能被个人学习一次选中后长期占位。

判据（数据驱动，不靠人工枚举）：一个二字词条若**两字都是高频虚字**且
**wordfreq 词表里不存在**，它就是分词伪影——真词（我的/过于/让她）几乎都能
在 wordfreq 里查到。伪影只在造成伤害时删除：

- R1 同键挤压：同拼音键下存在含实字的对手词条（词频 ≥ 本条 × 0.5）→ 删除。
  例：到的/道德、是在/实在、是有/石油、还时/还是、是间/时间。
- R2 同族内卷：同键下多个伪影 → 与最高频对手差 4 倍以上的删除。
  例：拿么、哪么 让位给 那么；让他/让她 并存（差不到 4 倍）。

删除是安全的：这些组合的文本仍可由单字拼装得到（到的 = 到+的），删词条只
去掉「伪词位」；解码端已有纯单字拼装惩罚（kernel SINGLE_CHAR_ASSEMBLY_PENALTY）
压住伪整句抢首选，源头与解码端互补。

依赖：pip install wordfreq（与 reweight_dict.py 相同）。
用法：python3 tools/clean_junk_dict.py [输入.tsv] > 输出.tsv（报告走 stderr）
"""
import sys
from collections import defaultdict

from wordfreq import get_frequency_dict

FUNC = set(
    "的了是在有不我没你他她它这那哪个们呢吧吗啊呀嘛么就都很也还和与及或并但被把给"
    "让往向从对比到说没要会能地得着过之所以于以其又才只每再最太更越等却倒即便些咋啦"
)
WHITELIST = {"我的", "你的", "他的", "她的", "它的", "是的", "说的", "别的", "总的", "似的"}
RIVAL_FACTOR = 1.0  # 对手词频不低于伪影才算「真词在前、伪词贴下」的可见污染
R2_RATIO = 4.0


def is_func_pair(word: str) -> bool:
    return len(word) == 2 and all(c in FUNC for c in word)


def clean_rows(rows, wf):
    """rows: [(word, pinyin, freq)] → (清洗后 rows, 删除明细)。保持输入顺序。"""
    by_key = defaultdict(list)
    for idx, (w, p, fr) in enumerate(rows):
        by_key[p].append(idx)

    def artifact(i):
        w, _, _ = rows[i]
        return is_func_pair(w) and w not in wf and w not in WHITELIST

    drop = set()
    # R1：伪影与含实字的对手同键，且对手词频 ≥ 本条 × 0.5
    for p, idxs in by_key.items():
        content = [(rows[i][0], rows[i][2]) for i in idxs if not is_func_pair(rows[i][0])]
        for i in idxs:
            if not artifact(i):
                continue
            _, _, fr = rows[i]
            if any(rf >= fr * RIVAL_FACTOR for _, rf in content):
                drop.add(i)
    # R2：同键多个伪影 → 与最高频者差 4 倍以上才删（让他/让她 并存，拿么/哪么 让位）
    for p, idxs in by_key.items():
        arts = [i for i in idxs if artifact(i) and i not in drop]
        if len(arts) <= 1:
            continue
        top = max(rows[i][2] for i in arts)
        for i in arts:
            if rows[i][2] * R2_RATIO < top:
                drop.add(i)

    kept = [row for i, row in enumerate(rows) if i not in drop]
    details = sorted((rows[i][0], rows[i][1], rows[i][2]) for i in drop)
    return kept, details


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "crates/dict/data/base-large.tsv"
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 3:
            continue
        rows.append((f[0], f[1], int(f[2])))

    wf = get_frequency_dict("zh", "best")
    kept, details = clean_rows(rows, wf)
    for w, p, fr in details:
        print(f"删除 {w}\t{p}\t{fr}", file=sys.stderr)
    print(
        f"输入 {len(rows)} 条，删除 {len(details)} 条（双虚字伪影），输出 {len(kept)} 条",
        file=sys.stderr,
    )
    for w, p, fr in kept:
        print(f"{w}\t{p}\t{fr}")


if __name__ == "__main__":
    main()
