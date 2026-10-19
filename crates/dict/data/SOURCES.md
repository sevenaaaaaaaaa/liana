# 词典数据来源与许可

## `base-large.tsv`（随包分发的主词库，20 万词条）

由以下来源合并、按全局同一尺度归一化并剪枝生成（单音节条目全量保留）：

| 来源 | 说明 | 许可 |
|---|---|---|
| [rime-ice / cn_dicts/8105.dict.yaml](https://github.com/iDvel/rime-ice) | 通用规范汉字表（单字 + 权重） | GPL-3.0-only |
| rime-ice / cn_dicts/base.dict.yaml | 常用词库 | GPL-3.0-only |
| rime-ice / cn_dicts/ext.dict.yaml | 扩展词汇 | GPL-3.0-only |
| rime-ice / cn_dicts/41448.dict.yaml | GB2312 生僻字 | GPL-3.0-only |
| rime-ice / cn_dicts/others.dict.yaml | 补充词条 | GPL-3.0-only |
| `data/base.tsv`（本项目） | 人工校准的常用词/短句频次，×100 权重优先 | AGPL-3.0-only |

### 词频重排（2026-10）

rime-ice 的权重为配合其语法模型设计，常用词大量挤在同一档（大家/等级/点击/好的≈500k），
单独做 unigram 排序时首选经常不对。现行 `base-large.tsv` 的词频由 `tools/reweight_dict.py`
重排：以 [wordfreq](https://github.com/rspeer/wordfreq)（多语料融合词频，数据 CC BY-SA 4.0，
可单向兼容 GPL-3.0）为主信号，rime-ice 权重做单调校准兜底与多音字读音分摊，
再叠加本项目维护的 `modern.tsv`（当代平台名/科技词/网络用语，AGPL-3.0-only）。
词频尺度为 10^(zipf-0.6)（「的」≈1e7）。

```bash
pip install wordfreq
python3 tools/reweight_dict.py <上一步生成的 base-large.tsv> crates/dict/data/base.tsv \
    crates/dict/data/modern.tsv > /tmp/new.tsv && mv /tmp/new.tsv crates/dict/data/base-large.tsv
cargo run --release -p xtask -- accuracy --hard   # 困难评测集 + 学习能力
```

rime-ice 的许可证全文见 `LICENSE-rime-ice.txt`（GPL-3.0-only）。本项目按 AGPL-3.0-only
分发，与 GPL-3.0 的兼容性见 AGPL-3.0 第 13 条；词库数据本身仍为 GPL-3.0-only。

## 重新生成

```bash
# 1. 下载 rime-ice 词库（任选镜像）
RI=https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts
mkdir -p /tmp/rime-ice && cd /tmp/rime-ice
for f in 8105 base ext 41448 others; do curl -sSLO "$RI/$f.dict.yaml"; done

# 2. 合并（×100 的人工校准词表保证首屏常用词优先）
cd <repo>
cargo run --release -p xtask -- dict import-rime-multi \
    -o /tmp/base-large.ifd --tsv crates/dict/data/base-large.tsv --max-entries 200000 \
    /tmp/rime-ice/8105.dict.yaml:1 \
    /tmp/rime-ice/base.dict.yaml:1 \
    /tmp/rime-ice/ext.dict.yaml:1 \
    /tmp/rime-ice/41448.dict.yaml:10000 \
    /tmp/rime-ice/others.dict.yaml:10000 \
    crates/dict/data/base.tsv:100

# 3. 校验
cargo run --release -p liana-pinyin --example dump -- /tmp/base-large.ifd
```

## `packs/`（官方词包）

`packs/default/*.tsv` 在构建 `base.ifd` 时自动合并进基础词库（`xtask dict build` 读取输入文件同目录的
`packs/default`，同词同音取较大词频——词包只补词、抬词频，不压低已有词；`--no-packs` 可关闭）。
`packs/optional/*.tsv`（人名、诗词、法律、医学、动物）暂不合并，留给用户按需开启。

| 词包 | 来源 | 许可 |
|---|---|---|
| apps / companies / slang / places-extra | `packs/src/*.txt`：本项目人工维护的应用、公司品牌、口语新词、商圈景点与多音字地名，按档位给词频 | AGPL-3.0-only |
| idioms | [chinese-xinhua](https://github.com/pwxcoo/chinese-xinhua) 成语表（含拼音）+ THUOCL 成语频次 | MIT（`packs/LICENSE-chinese-xinhua.txt`） |
| it / finance / places / food / car，optional/* | [清华 THUOCL](https://github.com/thunlp/THUOCL) 各领域词表，只取基础词库没有的词，按重合词把文档频次校准到同一尺度后打 6 折 | MIT（`packs/LICENSE-THUOCL.txt`） |

重新生成（需要 `pip install pypinyin`）：

```bash
git clone --depth 1 https://github.com/thunlp/THUOCL /tmp/THUOCL
curl -sSL -o /tmp/idiom.json https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/idiom.json
python3 tools/build_vocab_packs.py --thuocl /tmp/THUOCL/data --idioms /tmp/idiom.json
cargo run --release -p xtask -- accuracy --hard --cases xtask/data/accuracy-vocab.tsv
```

常用简拼先验（`crates/pinyin/data/jianpin.tsv`，本项目维护）不在词库里，由解码器内置。

## `base.lm`（整句搭配模型，不入库，构建时生成）

由 [万象 RIME-LMDG](https://github.com/amzxyz/RIME-LMDG) 的语法模型 `wanxiang-lts-zh-hans.gram`
（作者 amzxyz，[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）抽取常用字的 2～4 字搭配并重新编码（LMC2 格式），
作为整句解码的上下文打分。设计见 `docs/adr/0012-collocation-language-model.md`。

```bash
curl -fL -o /tmp/wanxiang-lts-zh-hans.gram https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram
cargo run --release -p xtask -- lm build /tmp/wanxiang-lts-zh-hans.gram -o base.lm --max-len 4 --band4 17.5,99
cargo run --release -p xtask -- accuracy --hard --cases xtask/data/accuracy-sentences.tsv --lm base.lm
```

macOS `build.sh` 会自动完成以上步骤（原始模型缓存在 `~/Library/Caches/Liana-build`）。

## `base.tsv`（内置兜底词库）

本项目人工维护的 367 条高频词/短语，供 `cargo test`、无外部词典的兜底场景使用，
并在大词典生成时作为高优先权重来源参与合并。
