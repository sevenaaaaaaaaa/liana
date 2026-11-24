# 日语数据来源与许可证

> 快照日期：2026-11-24（本机实测，A 级：文件大小 / sha256 / 行数均为当日实测）
> 结论：两份上游数据都是 **CC BY-SA 4.0**；派生的词典、矩阵、评测语料继续按
> CC BY-SA 4.0 分发，并在本文件与仓库 README 中署名。

## 1. JMdict（词典）

| 项 | 值 |
|---|---|
| 下载地址 | <https://www.edrdg.org/pub/Nihongo/JMdict_e.gz> |
| 快照大小 | 10,612,416 字节（10.1 MiB，gzip） |
| 解压后 | 63,307,815 字节，219,217 个 `<entry>` |
| Last-Modified | 2026-11-24 03:30:25 GMT（EDRDG 每日重新生成） |
| sha256 | `8bac55a4fd3ea2b103348ced2098a61165a73aaea45754e6535057c71d7b14fa` |

### 许可证（EDRDG General Dictionary Licence Statement）

原文：<https://www.edrdg.org/edrdg/licence.html>（2026-11-24 抓取）

- 词典文件以 **Creative Commons Attribution-ShareAlike 4.0 International
  (CC BY-SA 4.0)** 提供；允许商用、允许随软件分发、不要求软件本身开源。
- 必须署名（见下），必须对衍生数据保持同样/兼容的许可证（ShareAlike）。
- 软件包必须在文档/关于页提供署名，并提供许可证链接；App 内要有 Sources/About
  入口（M1 只落数据层，产品 UI 的署名入口在 M4 六端收敛时补）。
- 许可证第 4 条要求「有定期更新数据的流程」；本文件的「更新流程」一节即是。

**署名文本（复制到 README / 关于页）**：

> Japanese dictionary data © James William Breen and the Electronic Dictionary
> Research and Development Group (EDRDG), licensed under CC BY-SA 4.0.
> Source: https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project

### 本仓库的派生文件

`crates/ja/data/jmdict.tsv` —— 由 `crates/ja/tools/prune_jmdict.py` 从上述快照生成：

- 选词：有 JMdict 优先标签（news1/2、ichi1/2、spec1/2、gai1/2、nf01..nf48）的词条，
  加上助词/助动词/接续词等语法词；按标签分 + 语料词频排序取前 3 万词条；
- 展开：动词 7 个常用活用形 + 3 个裸词干，イ形容词 4 形，ナ形容词 4 形；
- 输出：**70,540 行，2,438,217 字节（2.33 MiB）**，4 列
  `reading / surface / pos / weight`；
- 许可证：**CC BY-SA 4.0**（JMdict 的衍生作品）。

## 2. UD Japanese-GSD（连接矩阵与评测语料）

| 项 | 值 |
|---|---|
| 仓库 | <https://github.com/UniversalDependencies/UD_Japanese-GSD> |
| 许可证 | CC BY-SA 4.0（仓库 LICENSE.txt） |
| train | 40,583,344 字节，7,050 句，sha256 `99f67fd88257e7cfe81d81c4b8ee98aff85fc22bb525d907475a2856c8cfa9f3` |
| dev | 2,961,591 字节，507 句，sha256 `18d266e29336ef619787a928d89d20f2e64188be70d5b37829e3aadc5bb6b841` |
| test | 3,111,982 字节，sha256 `5f50ee6ed45c7ebda3787e593eaf5e9a225f25e53f6b4b32df778031862c843f` |

用途：

1. `matrix.bin`：train 的 UPOS 相邻词性 bigram 计数 → 18×18 成本矩阵
   （734 字节）。**只在 train 上统计**，dev/test 不参与，避免评测泄漏。
2. `xtask/data/corpus/liana-ja.tsv`：dev+test 的 200 句，取每句的假名读音
   （纯假名 token 用书写形；含汉字 token 用 UniDic 表层发音；名词用词条读音，
   避免「せんせー」这种长音写法）→ 期望输出为原句。**CC BY-SA 4.0**。
3. 语料词频 `ja-freq.tsv`（不签入）：train 的 LEMMA 计数，用于给
   `jmdict.tsv` 的 weight 补频。

**署名文本**：

> Universal Dependencies Japanese-GSD treebank, licensed CC BY-SA 4.0.
> Source: https://github.com/UniversalDependencies/UD_Japanese-GSD
> Morphological information (including readings) is based on UniDic.

## 2.5 Tatoeba 日语语料（M1.5 语言模型）

| 项 | 值 |
|---|---|
| 下载地址 | <https://downloads.tatoeba.org/exports/per_language/jpn/jpn_sentences.tsv.bz2> |
| 快照 | 3,419,087 字节，248,730 句 / 4,485,832 字 |
| sha256 | `1fbe53db3663dbb0bd80ff45ec8b1f633e6d4df92d93e57c1e208f251eea6b79` |
| 许可证 | **CC BY 2.0 FR**（Tatoeba 句子） |

用途：

1. `crates/ja/data/.cache/ja-surface-freq.tsv`：最长匹配切词后的表面频次，
   给词典 weight 补真实书写分布（不签入）；
2. `crates/ja/data/charlm.bin`：字符 4-gram 语言模型（200,000 个 4-gram，
   **1.9 MiB**），用于 Viterbi 20-best 重排；只保留统计量，不复制句子。

**署名文本**：

> Tatoeba Japanese sentence corpus, licensed CC BY 2.0 FR.
> Source: https://tatoeba.org / https://downloads.tatoeba.org/

## 3. 体积结论（M1-8 第一步）

| 产物 | 大小 | 结论 |
|---|---:|---|
| JMdict_e.gz（原始） | 10.1 MiB | 不进仓库（`.cache/`，已 gitignore） |
| jmdict.tsv（剪枝后） | 2.33 MiB | 进仓库，`include_str!` 内嵌 |
| matrix.bin | 734 B | 进仓库，`include_bytes!` 内嵌 |
| charlm.bin（M1.5） | 1.9 MiB | 进仓库，`include_bytes!` 内嵌 |
| liana-ja.tsv（200 句评测） | 36 KiB | 进仓库 |
| liana-ja-words.tsv（500 词评测） | 约 12 KiB | 进仓库 |

- 数据合计约 **4.3 MiB**，远低于规划里 15MB 的风险线，也低于 iOS 包体 +8MB 的止损线；
  **结论：随包内嵌，不做按需下载。**
- 运行时按需解析（`OnceLock`，首次切到日语才加载），不占中文/英文路径的内存。

## 4. 更新流程（许可证第 4 条要求）

每季度或每次发版前：

```sh
bash crates/ja/tools/fetch_data.sh          # 下载 JMdict_e.gz + UD train/dev/test
python3 crates/ja/tools/corpus_stats.py \
    --conllu crates/ja/data/.cache/ja_gsd-ud-train.conllu \
    --output crates/ja/data/.cache/ja-freq.tsv
python3 crates/ja/tools/prune_jmdict.py --stats
python3 crates/ja/tools/build_matrix.py \
    --conllu crates/ja/data/.cache/ja_gsd-ud-train.conllu \
    --output crates/ja/data/matrix.bin
python3 crates/ja/tools/make_eval_corpus.py \
    --conllu crates/ja/data/.cache/ja_gsd-ud-dev.conllu \
    --conllu crates/ja/data/.cache/ja_gsd-ud-test.conllu \
    --output xtask/data/corpus/liana-ja.tsv --count 200
python3 crates/ja/tools/make_word_eval.py \
    --conllu crates/ja/data/.cache/ja_gsd-ud-dev.conllu \
    --conllu crates/ja/data/.cache/ja_gsd-ud-test.conllu \
    --output xtask/data/corpus/liana-ja-words.tsv --count 500
python3 crates/ja/tools/tatoeba_freq.py
python3 crates/ja/tools/build_charlm.py --max 200000
cargo test -p liana-ja
cargo run -q -p xtask -- eval-corpus --lang ja
```

更新后把新的 sha256、行数、日期写回本文件。

## 5. 已知缺口

- 词表上限 3 万词条（按标签+词频选取）；未登录词只能输出假名或逐字汉字。
- 连接矩阵是 **词性 bigram**；词级 bigram 试过（Tatoeba 最长匹配切词，53,928 对），
  在整句评测上反而把字准确率从 85.8% 拉到 84.5%，已回滚，未进仓库。
- 当前口径（M1.5 验收，见 `docs/adr/0014-ja-m1-acceptance-and-ngram.md`）：
  - 字准确率 **85.8%**（目标 ≥90%，差 4.2pt）；
  - 词级 Top-1 **85.2%**（目标 ≥85%，已达标）；
  - 整句 Top-1 22.5% / Top-3 26.5%（长期目标，不作 M1 门槛）。
- 下一步若要把字准确率推到 90%：需要词级/字级 n-gram 与更好的切词对齐（或神经语言模型），
  词性 bigram + 字符重排的天花板大致就在这里。
- 评测语料来自 Wikipedia 风格的 UD 文本，长句和专名比例偏高；它测的是
  「整句能不能全对」，比字准确率严格得多。
