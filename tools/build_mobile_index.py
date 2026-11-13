#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the read-only mobile T9/Wubi/glide index from pinned source data."""
import argparse
import hashlib
import json
import re
import sqlite3
from pathlib import Path

GROUPS = {letter: str(n) for n, group in enumerate(['abc','def','ghi','jkl','mno','pqrs','tuv','wxyz'], 2) for letter in group}

# 常见姓氏（单姓 + 常见复姓）。只用于给「人名」词条打类别标签，
# 覆盖词包里漏收但确实是姓名的词（例如 李华），避免在 Swift 侧硬编码具体词。
SURNAMES = set(
    '赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍郤璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公'
)
COMPOUND_SURNAMES = {
    '欧阳', '司马', '诸葛', '上官', '东方', '皇甫', '尉迟', '公孙', '慕容', '长孙',
    '宇文', '司徒', '司空', '令狐', '夏侯', '闻人', '贺兰', '南宫', '独孤', '轩辕',
    '端木', '百里', '东郭', '西门', '南门', '呼延', '羊舌', '微生', '梁丘', '左丘',
    '东门', '濮阳', '太史', '申屠', '公羊', '万俟', '澹台', '公冶', '宗政', '淳于',
    '单于', '太叔', '仲孙', '钟离', '赫连', '拓跋', '夹谷', '谷梁', '段干', '鲜于',
}
# 这些结尾更像地名/器物/抽象词，避免把「李子」「王国」「黄山」误标成人名。
STOP_SUFFIX = set(
    '省市县区路街镇村山河湖海岛州城港湾园寺庙桥站门口江川原庄屯堡营寨岭峰谷林田塘岸滩洲都邑郡府道巷弄里坊苑厦楼阁塔亭台池泉溪潭洞岩崖石沙漠野郊乡县朝天地人年月日时分秒号栋幢室层单元米克吨元角分国族界岁级班校院厂店馆所局厅部委办处科股队团会党军民警兵工农商学医理文化用品物事情话语文报书刊网端软件机箱表盘杯壶瓶袋包柜桌椅床垫被褥衣裤鞋帽袜巾纸笔墨尺刀剪针线绳带锁钥匙灯电火水油气车船飞机票证卡钱款额率税利息债券股票基金险保'
) | set('子儿头们性化者长')


def _is_person_name(word: str) -> bool:
    word = word.strip()
    if not (2 <= len(word) <= 4):
        return False
    if any(not ('\u4e00' <= ch <= '\u9fff') for ch in word):
        return False
    if word[-1] in STOP_SUFFIX:
        return False
    if word[:2] in COMPOUND_SURNAMES:
        return len(word) >= 3
    return word[0] in SURNAMES


def _read_tag_words(path: Path):
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        word = line.split('\t')[0].strip()
        if word and len(word) <= 64:
            yield word


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pinyin', type=Path)
    parser.add_argument('wubi', type=Path)
    parser.add_argument('english', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--tag', action='append', default=[], metavar='NAME=PATH[,PATH...]',
                        help='给词条打类别标签（可重复），例如 place=a.tsv,b.tsv')
    parser.add_argument('--person-surnames', action='store_true',
                        help='用常见姓氏规则补齐人名标签（覆盖词包漏收的姓名）')
    args = parser.parse_args()
    tag_specs = []
    for spec in args.tag:
        if '=' not in spec:
            parser.error('--tag expects NAME=PATH[,PATH...]')
        name, raw_paths = spec.split('=', 1)
        name = name.strip()
        paths = [Path(value.strip()) for value in raw_paths.split(',') if value.strip()]
        if not name or not paths:
            parser.error('--tag expects NAME=PATH[,PATH...]')
        tag_specs.append((name, paths))

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

    # 类别标签：只给词库里真实存在的词打标，查询走 tags(word,tag) 主键。
    known = {row[0] for row in rows}
    tags = set()
    for name, paths in tag_specs:
        for path in paths:
            if not path.exists():
                raise SystemExit(f'tag source missing: {path}')
            for word in _read_tag_words(path):
                if word in known:
                    tags.add((word, name))
    if args.person_surnames:
        for word in known:
            if _is_person_name(word):
                tags.add((word, 'person'))
    db.execute('CREATE TABLE tags(word TEXT, tag TEXT, PRIMARY KEY(word, tag))')
    if tags:
        db.executemany('INSERT OR IGNORE INTO tags VALUES(?,?)', sorted(tags))
    db.commit()
    print('Mobile index:',dict(db.execute('SELECT kind,COUNT(*) FROM words GROUP BY kind')))
    print('Mobile tags:',dict(db.execute('SELECT tag,COUNT(*) FROM tags GROUP BY tag')))
    db.close()


if __name__ == '__main__':
    main()
