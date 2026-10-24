use std::collections::HashSet;
use std::sync::Arc;

use liana_core::syllables::{is_syllable, is_syllable_prefix};
use liana_core::{Candidate, CandidateKind, CommentRole, Scheme};
use liana_dict::{Dictionary, Entry};

use crate::scheme::{Codes, MAX_SYLLABLE_LEN};

/// 一条词边最多覆盖的音节数。
pub const MAX_WORD_SYLLABLES: usize = 6;
/// 切分路径上限（防止长串在歧义处指数爆炸）。
pub const MAX_PATHS: usize = 256;
/// 单次解码允许的最大输入字符数。
pub const MAX_INPUT_CHARS: usize = 64;
/// 尾部无法成音节的残余最多按这么长当作未输完的尾巴保留。
const MAX_GARBAGE_TAIL: usize = 3;
/// 整句切分时每个「词」的惩罚（≈ ln 语料规模），使 N 个单字不敌一个常用词。
const WORD_PENALTY: f64 = 0.8;
/// 完全无法成词时的旁路惩罚（保留原样音节）。
const PASS_THROUGH_PENALTY: f64 = -40.0;
/// 候选排序中每个音节的长度加成（覆盖输入越多越靠前）。
const LEN_BONUS: f64 = 1.8;
/// 选择最佳切分时每个输入字符的覆盖加成（避免用更短的切分胜出）。
const COVERAGE_BONUS: f64 = 4.0;
/// 未输完音节时，补全候选每个已按键字符的加成（让 `nih`→你好 压过 `ni`→你）。
const COMPLETION_BONUS: f64 = 3.0;
/// 每个模糊/纠错代价的扣分（保证精确拼写优先）。
const FUZZY_PENALTY: f64 = 2.4;
/// 单音节完整输入时，词组前缀候选的降权（优先单字）。
const SINGLE_SYLLABLE_PREFIX_PENALTY: f64 = 3.5;
/// 单次解码参与打分/解码的路径数上限（按覆盖音节数取前 N 条）。
const MAX_RANKED_PATHS: usize = 32;
/// 参与词候选（decode_path）的路径数上限。
const MAX_DECODE_PATHS: usize = 64;
/// 启用拼写纠错的最大输入长度（长句不纠错，保证性能）。
const MAX_FUZZY_INPUT: usize = 12;
/// 纠错路径凑够这么多就停（左侧纠错已拿全，尾段纠错性价比最低）。
const CORRECTED_PATH_TARGET: usize = 40;
/// 锚定纠错只取精确切分的前这么多条路径做锚（后面的切分质量差，纠了也没人看）。
const ANCHOR_PATHS: usize = 24;
/// 前缀查询单次扫描上限（防止首字母输入扫描过大）。
const PREFIX_SCAN_LIMIT: usize = 8192;
/// 前缀查询时同一 key 下取多少条词条（是/时/事/使…）。
const PREFIX_PER_KEY: usize = 3;
/// 分隔符指定切分后，音节数不符候选的惩罚（`xi'an` 下 `xian` 系候选让位）。
const SYL_MISMATCH_PENALTY: f64 = 6.0;
/// 零模糊且全覆盖候选的加分：精确读音永远压过同覆盖的模糊读音
/// （`nve` 的「虐」不许被模糊 `lve` 的高频「略」劫持）。
const EXACT_FULL_BONUS: f64 = 2.5;
/// 常用简拼先验：表里的词比同层最高分再高这么多（个人学习的加分仍可反超）。
const JIANPIN_PRIOR_BONUS: f64 = 1.5;
/// 整句解码每个位置保留的路径数（按「到此为止的整句文本」区分）。
const BEAM: usize = 8;
/// 有搭配模型时，每个读音参与竞争的同音词数（没有模型时只取最高的一个，和纯词频一致）。
const LM_HOMOPHONES: usize = 4;
/// 搭配分超过这个值的部分才算证据（octagram 里「没搭配」与「有搭配」的分界）。
const LM_THRESHOLD: f64 = 8.0;
/// 搭配证据的权重（与 ln 词频同尺度；用 xtask accuracy 的整句 / 困难 / 词汇三套评测调出）。
const LM_WEIGHT: f64 = 0.35;
/// 只对覆盖最好的前几条切分跑带搭配模型的完整搜索，其余切分仍用纯词频（长输入保持流畅）。
const LM_PATHS: usize = 6;
/// 最多给出几条不同的整句候选。
const MAX_SENTENCES: usize = 3;
/// 常用简拼表（`data/jianpin.tsv`）。
const JIANPIN_TSV: &str = include_str!("../data/jianpin.tsv");

/// 放进某个位置的 beam：同一文本只留得分最高的切分，超出 BEAM 条时挤掉最低分。
fn push_beam(beam: &mut Vec<Hyp>, cand: Hyp) {
    if let Some(cur) = beam.iter_mut().find(|h| h.text == cand.text) {
        if cand.score > cur.score {
            *cur = cand;
        }
        return;
    }
    if beam.len() < BEAM {
        beam.push(cand);
        return;
    }
    let (worst, worst_score) = beam
        .iter()
        .enumerate()
        .map(|(i, h)| (i, h.score))
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .expect("beam 非空");
    if cand.score > worst_score {
        beam[worst] = cand;
    }
}

/// 某个简拼的先验词：`(词, 词库 key)`，按表里的先后。
fn jianpin_priors(abbr: &str) -> Vec<(&'static str, String)> {
    static TABLE: std::sync::OnceLock<
        std::collections::HashMap<&'static str, Vec<(&'static str, String)>>,
    > = std::sync::OnceLock::new();
    TABLE
        .get_or_init(|| {
            let mut map: std::collections::HashMap<&'static str, Vec<(&'static str, String)>> =
                std::collections::HashMap::new();
            for line in JIANPIN_TSV.lines() {
                if line.starts_with('#') || line.trim().is_empty() {
                    continue;
                }
                let mut f = line.split('\t');
                if let (Some(abbr), Some(word), Some(py)) = (f.next(), f.next(), f.next()) {
                    map.entry(abbr)
                        .or_default()
                        .push((word, py.split_whitespace().collect::<Vec<_>>().join("'")));
                }
            }
            map
        })
        .get(abbr)
        .cloned()
        .unwrap_or_default()
}
/// 简拼候选的惩罚：低于同长度的完整拼音，避免抢占正常输入。
const ABBR_PENALTY: f64 = 2.5;
/// 混拼候选的惩罚（命中更具体，惩罚略小）。
const MIXED_PENALTY: f64 = 1.5;
/// 简拼候选上限（`nh` 这类两字母输入命中很多）。
const ABBR_LIMIT: usize = 32;
/// 混拼候选上限。
const MIXED_LIMIT: usize = 64;
/// 超过这个长度的输入不再尝试混拼扫描（长串本来就是整句输入）。
const MAX_MIXED_QUERY: usize = 8;

/// 词库键形规范化：导入时 ü 行统一成 `v`（`lue`→`lve`、`nue`→`nve`），
/// 运行时切分允许两种拼法，查词键前必须归一，否则 `shenglue` 永远查不到 `sheng'lve`。
fn canon_syl(s: &str) -> &str {
    match s {
        "lue" => "lve",
        "nue" => "nve",
        _ => s,
    }
}

/// 查询串同规（前缀 / 简拼按纯字母匹配词库）。
fn canon_query(q: &str) -> String {
    q.replace("lue", "lve").replace("nue", "nve")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    Full,
    Shuangpin(Scheme),
}

impl Layout {
    pub fn is_shuangpin(&self) -> bool {
        matches!(self, Layout::Shuangpin(_))
    }
}

/// 音节段。`syl == None` 表示尾部未输完的部分（不参与解码，提交时保留）。
#[derive(Clone, Debug)]
struct Seg {
    syl: Option<String>,
    /// 归一化字符序列中的区间终点（起点即上一段的终点）
    end: usize,
    /// 纠错代价：0 = 精确拼写；>0 = 模糊音 / 编辑距离纠错（每个代价扣 FUZZY_PENALTY）
    fuzzy: f64,
}

#[derive(Clone, Debug, Default)]
struct Hyp {
    /// 切分打分（含词惩罚，用于选择最佳切分）
    score: f64,
    /// 不加惩罚的 ln 频率之和（用于与词候选同尺度排序）
    sum_ln: f64,
    /// 路径里的词数（含旁路音节）：整句换算回「单词尺度」时用
    words: usize,
    /// 由真实词典词覆盖的音节数（旁路音节不计入长度加成）
    matched: usize,
    /// 旁路（未成词、原样保留）的音节数
    garbage: usize,
    text: String,
    pinyin: Vec<String>,
    /// 搭配加分之和（已计入 score；整句换算到候选尺度时单独加回）
    lm: f64,
}

pub struct PinyinDecoder {
    dict: Arc<Dictionary>,
    layout: Layout,
    codes: Codes,
}

impl PinyinDecoder {
    pub fn new(dict: Arc<Dictionary>, layout: Layout) -> Self {
        let codes = match layout {
            Layout::Shuangpin(s) => Codes::build(s),
            Layout::Full => Codes::default(),
        };
        Self {
            dict,
            layout,
            codes,
        }
    }

    pub fn layout(&self) -> Layout {
        self.layout
    }

    pub fn candidates(&self, input: &str) -> Vec<Candidate> {
        self.candidates_with(input, &|_| 0.0)
    }

    /// 带个人词频的解码：`boost(词)` 返回该词的对数加分（用户常用词），
    /// 直接参与整句 Viterbi——常打的「回复」在长句里也会压过「恢复」，
    /// 而不只是在单词候选上重排。
    pub fn candidates_with(&self, input: &str, boost: &dyn Fn(&str) -> f64) -> Vec<Candidate> {
        let (chars, orig) = normalize(input);
        if chars.is_empty() {
            return Vec::new();
        }
        let limit = chars.len().min(MAX_INPUT_CHARS);
        let chars = &chars[..limit];
        let orig = &orig[..limit];
        let raw: String = input
            .chars()
            .filter(|c| c.is_ascii_alphabetic() || *c == ';')
            .collect();

        // 分隔符是用户的硬指令：`xi'an` 的 `'` 表示「这里必须切」。
        // 跨越分隔符的切分路径直接淘汰（现 [xian] 让位 西安 [xi][an]）。
        let mut boundaries: Vec<usize> = Vec::new();
        for (i, &oi) in orig.iter().enumerate() {
            if i + 1 < orig.len() && input[oi + 1..].starts_with('\'') {
                boundaries.push(i + 1);
            }
        }
        let mut paths = self.segment(chars);
        if !boundaries.is_empty() {
            paths.retain(|p| {
                boundaries
                    .iter()
                    .all(|b| p.iter().any(|s| s.syl.is_some() && s.end == *b))
            });
        }
        let ends_complete = paths.iter().any(|p| p.iter().all(|s| s.syl.is_some()));
        let mut out: Vec<Candidate> = Vec::new();
        let mut best: Option<(Vec<Hyp>, usize, usize, f64)> = None;
        // 只处理覆盖最好的前 N 条路径：路径数上限放宽后仍保持性能
        // （长输入会产生大量等价切分，全部跑 Viterbi 会拖慢到毫秒级）
        let mut ranked: Vec<(usize, usize, f64)> = paths
            .iter()
            .enumerate()
            .map(|(i, p)| {
                // 覆盖量按「字母数」计，不按段数：[zuo][tian]（2 段全覆盖）必须
                // 与 [zuo][ti][an]（3 段）同权重，否则整词路径被逐字切分挤出
                // 候选窗口，Viterbi 永远看不到「昨天」。
                let used: usize = p
                    .iter()
                    .take_while(|s| s.syl.is_some())
                    .map(|s| s.end)
                    .max()
                    .unwrap_or(0);
                let cost: f64 = p.iter().map(|s| s.fuzzy).sum();
                (i, used, cost)
            })
            .collect();
        ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.2.total_cmp(&b.2)));
        let by_coverage: Vec<usize> = ranked.iter().map(|(idx, _, _)| *idx).collect();
        // 正常取覆盖最高的前 N 条；再额外补上「纠错代价最小」的几条，
        // 否则 zhuan→zhun 这类覆盖面较小的纠错路径会被覆盖更高的垃圾切分挤出
        let mut chosen: Vec<usize> = ranked
            .iter()
            .take(MAX_RANKED_PATHS)
            .map(|(idx, _, _)| *idx)
            .collect();
        ranked.sort_by(|a, b| a.2.total_cmp(&b.2).then(b.1.cmp(&a.1)));
        for (idx, _, _) in ranked.iter().filter(|(_, _, c)| *c > 0.0).take(8) {
            if !chosen.contains(idx) {
                chosen.push(*idx);
            }
        }
        // 词候选：覆盖前 64 条 + 纠错筛选条（每条最多 6 次字典查询），
        // 保证纠错词能露出，同时避免长输入的全部路径都生成候选
        let mut decode_set: Vec<usize> =
            by_coverage.iter().take(MAX_DECODE_PATHS).copied().collect();
        for idx in &chosen {
            if !decode_set.contains(idx) {
                decode_set.push(*idx);
            }
        }
        for idx in decode_set {
            self.decode_path(orig, &paths[idx], &mut out);
        }
        for (rank, idx) in chosen.iter().copied().enumerate() {
            let path = &paths[idx];
            let usable: Vec<&Seg> = path.iter().take_while(|s| s.syl.is_some()).collect();
            if usable.is_empty() {
                continue;
            }
            let hyps = self.viterbi(&usable, boost, rank < LM_PATHS);
            if let Some(h) = hyps.first() {
                let consumed = orig[usable.last().expect("非空").end - 1] + 1;
                let path_fuzzy: f64 = usable.iter().map(|s| s.fuzzy).sum();
                let cover = (
                    h.score - path_fuzzy * FUZZY_PENALTY + COVERAGE_BONUS * consumed as f64,
                    consumed,
                    usable.len(),
                    path_fuzzy,
                );
                let better = best
                    .as_ref()
                    .is_none_or(|(cur, cur_consumed, _, cur_fuzzy)| {
                        cover.0
                            > cur[0].score - cur_fuzzy * FUZZY_PENALTY
                                + COVERAGE_BONUS * *cur_consumed as f64
                    });
                if better {
                    best = Some((hyps, consumed, usable.len(), path_fuzzy));
                }
            }
        }
        let full_cover = best
            .as_ref()
            .is_some_and(|(_, consumed, _, _)| *consumed >= orig.len());
        if let Some((hyps, consumed, syls, path_fuzzy)) = best {
            let kind = if syls == 1 {
                CandidateKind::Char
            } else {
                CandidateKind::Sentence
            };
            // 最优整句之外，再给出几条不同的整句（有搭配模型时同音的另一种说法常在这里）；
            // 只有一个音节时就是单字，不出备选
            let take = if syls == 1 { 1 } else { MAX_SENTENCES };
            for (_, hyp) in hyps
                .into_iter()
                .enumerate()
                .filter(|(r, h)| *r == 0 || h.garbage == 0)
                .take(take)
            {
                // 旁路音节重罚：避免「词 + 未成词残字」凑出的伪整句（如 专区+du）压过真词；
                // 路径的模糊代价也计入整句——模糊读音的整句不得压过精确读音的词。
                // sum_ln 是各词 ln(词频) 之和；每多一个词就多算了一次归一化常数 ln Z，
                // 必须扣回去，整句才和单个词处在同一尺度（否则「吗上」会压过「马上」）。
                let ln_z = self.dict.log_total();
                let sum_ln = hyp.sum_ln - hyp.words.saturating_sub(1) as f64 * ln_z;
                let score = sum_ln + LEN_BONUS * hyp.matched as f64 + 1.0 + hyp.lm
                    - hyp.garbage as f64 * 30.0
                    - path_fuzzy * FUZZY_PENALTY;
                let mut c = Candidate::new(hyp.text, consumed, kind, score);
                if !hyp.pinyin.is_empty() {
                    c = c.with_reading(hyp.pinyin.join(" "));
                }
                out.push(c);
            }
        }
        out.push(Candidate::new(
            raw,
            chars.len(),
            CandidateKind::Literal,
            -1000.0,
        ));
        let single_complete =
            ends_complete && paths.iter().any(|p| p.len() == 1 && p[0].syl.is_some());
        let expected_syls = (!boundaries.is_empty()).then_some(boundaries.clone());
        self.push_prefix_candidates(
            chars,
            orig,
            !ends_complete,
            single_complete,
            expected_syls,
            &mut out,
        );
        self.push_abbreviation_candidates(chars, orig, full_cover, &mut out);
        dedupe_and_sort(&mut out);
        out.truncate(30);
        self.mark_exact_readings(input, &mut out);
        out
    }

    /// 读音与用户所打完全一致的候选（`nihao` → 你好 [ni hao]）降级为
    /// [`CommentRole::ExactReading`]，前端据此在「仅纠错时显示」模式下隐藏拼音；
    /// 模糊音、纠错、简拼、混拼、补全的读音保持 `CorrectedReading`。
    fn mark_exact_readings(&self, input: &str, out: &mut [Candidate]) {
        for c in out.iter_mut() {
            if c.comment_role != CommentRole::CorrectedReading {
                continue;
            }
            let Some(reading) = c.comment.as_deref() else {
                continue;
            };
            let typed: String = input
                .chars()
                .take(c.consumed)
                .filter(char::is_ascii_alphabetic)
                .map(|ch| ch.to_ascii_lowercase())
                .collect();
            if self.reading_matches(&typed, reading) {
                c.comment_role = CommentRole::ExactReading;
            }
        }
    }

    /// `typed`（纯小写字母）是否就是 `reading`（空格/撇号分隔的拼音）的原样拼写。
    /// ü/v、lue/lve、nue/nve 视为同一拼法；双拼按两键一码逐音节核对。
    fn reading_matches(&self, typed: &str, reading: &str) -> bool {
        let syls: Vec<String> = reading
            .split([' ', '\''])
            .filter(|s| !s.is_empty())
            .map(|s| s.to_lowercase().replace('ü', "v"))
            .collect();
        if syls.is_empty() || typed.is_empty() {
            return false;
        }
        let joined: String = syls.concat();
        if canon_query(typed) == canon_query(&joined) {
            return true;
        }
        if self.layout.is_shuangpin() && typed.len() == syls.len() * 2 {
            return syls.iter().enumerate().all(|(i, syl)| {
                let want = canon_syl(syl);
                self.codes
                    .syllables(&typed[i * 2..i * 2 + 2])
                    .iter()
                    .any(|s| canon_syl(s) == want)
            });
        }
        false
    }

    /// 简拼 / 混拼候选：全拼模式只打几个字母也能整词命中。
    ///
    /// - 简拼：每个音节取首字母（`nh` → 你好、`bj` → 北京）；
    /// - 混拼：整音节与首字母任意混打（`nhao` → 你好）。
    ///
    /// 仅在输入无法被完整拼音覆盖时才做混拼扫描（避免每键全表匹配）。
    fn push_abbreviation_candidates(
        &self,
        chars: &[char],
        orig: &[usize],
        full_cover: bool,
        out: &mut Vec<Candidate>,
    ) {
        if !matches!(self.layout, Layout::Full) || chars.len() < 2 {
            return;
        }
        let query = canon_query(&chars.iter().collect::<String>());
        let consumed = orig.last().map(|i| i + 1).unwrap_or(chars.len());
        let qlen = chars.len() as f64;

        for hit in self.dict.lookup_initials(&query, 1, ABBR_LIMIT) {
            let score = (hit.entry.freq as f64).ln() + LEN_BONUS * qlen - ABBR_PENALTY;
            out.push(
                Candidate::new(
                    hit.entry.word.clone(),
                    consumed,
                    word_kind(hit.entry),
                    score,
                )
                .with_reading(hit.key.replace('\'', " ")),
            );
        }

        if !full_cover && chars.len() <= MAX_MIXED_QUERY {
            for hit in self.dict.lookup_mixed(&query, MIXED_LIMIT) {
                let score = (hit.entry.freq as f64).ln() + LEN_BONUS * f64::from(hit.entry.syls)
                    - MIXED_PENALTY;
                out.push(
                    Candidate::new(
                        hit.entry.word.clone(),
                        consumed,
                        word_kind(hit.entry),
                        score,
                    )
                    .with_reading(hit.key.replace('\'', " ")),
                );
            }
        }

        // 常用简拼先验：整段输入正好是表里的简拼时，表里的词排到同层候选最前面
        // （只调层内顺序；词必须在词库里、读音一致，个人学习仍可覆盖）
        let raw: String = chars.iter().collect();
        let priors = jianpin_priors(&raw);
        if !priors.is_empty() && consumed == chars.len() {
            let top = out
                .iter()
                .filter(|c| c.consumed == consumed)
                .map(|c| c.score)
                .fold(f64::NEG_INFINITY, f64::max);
            let base = if top.is_finite() { top } else { 0.0 };
            for (rank, (word, key)) in priors.iter().enumerate() {
                let Some(entry) = self.dict.lookup(key).iter().find(|e| e.word == *word) else {
                    continue;
                };
                out.retain(|c| !(c.text == *word && c.consumed == consumed));
                out.push(
                    Candidate::new(
                        *word,
                        consumed,
                        word_kind(entry),
                        base + JIANPIN_PRIOR_BONUS - rank as f64 * 0.1,
                    )
                    .with_reading(key.replace('\'', " ")),
                );
            }
        }
    }

    /// 前缀候选：把输入当作词库拼音的未输完前缀（`n` → 你/那…，`nih` → 你好…）。
    ///
    /// 仅在尾部音节未输完时给予补全加成，避免 `shi`（完整音节）被 `时候` 抢占。
    fn push_prefix_candidates(
        &self,
        chars: &[char],
        orig: &[usize],
        partial_tail: bool,
        single_complete: bool,
        expected_syls: Option<Vec<usize>>,
        out: &mut Vec<Candidate>,
    ) {
        let query = self.prefix_query(chars);
        if query.is_empty() {
            return;
        }
        let consumed = orig.last().map(|i| i + 1).unwrap_or(chars.len());
        for hit in self
            .dict
            .lookup_prefix(&query, PREFIX_PER_KEY, PREFIX_SCAN_LIMIT)
        {
            let covered = covered_syllables(hit.key, &query);
            let mut score = (hit.entry.freq as f64).ln() + LEN_BONUS * covered as f64;
            // 分隔符在场：词的音节边界必须包含用户指定的全部切分点
            // （`xi'an` 要求边界 {2}：西安 ✓；现在 [xian|zai] 边界 {4} ✗）。
            if let Some(ref expected) = expected_syls {
                if !expected.iter().all(|b| key_boundaries(hit.key).contains(b)) {
                    score -= SYL_MISMATCH_PENALTY;
                }
            }
            let extends = hit.entry.letters as usize > query.len();
            if partial_tail && extends {
                score += COMPLETION_BONUS * consumed as f64;
            }
            // 单个完整音节：词组前缀降权，保证单字候选优先（输入「xi」先给 西/希，而不是 希望）
            if single_complete && extends {
                score -= SINGLE_SYLLABLE_PREFIX_PENALTY;
            }
            let kind = if hit.entry.syls <= 1 {
                CandidateKind::Char
            } else {
                CandidateKind::Word
            };
            out.push(
                Candidate::new(hit.entry.word.clone(), consumed, kind, score)
                    .with_reading(hit.key.replace('\'', " ")),
            );
        }
    }

    /// 构造前缀查询串（纯字母的全拼形式）。
    ///
    /// 双拼按键先按两键一音节解回全拼；末尾落单或无法解码的部分原样保留。
    fn prefix_query(&self, chars: &[char]) -> String {
        match self.layout {
            Layout::Full => canon_query(&chars.iter().collect::<String>()),
            Layout::Shuangpin(_) => {
                let mut out = String::new();
                let mut i = 0;
                while i + 2 <= chars.len() {
                    let code: String = chars[i..i + 2].iter().collect();
                    match self.codes.syllables(&code).first() {
                        Some(syl) => {
                            out.push_str(syl);
                            i += 2;
                        }
                        None => break,
                    }
                }
                if i < chars.len() {
                    out.extend(chars[i..].iter());
                }
                canon_query(&out)
            }
        }
    }

    /// 预编辑串（按当前切分显示，未输完的尾巴原样保留）。
    pub fn preedit(&self, input: &str) -> String {
        let (chars, _) = normalize(input);
        match self.layout {
            Layout::Full => greedy_full(&chars),
            Layout::Shuangpin(_) => {
                let mut s = chunk_decode(&chars, &self.codes);
                if chars.len() > MAX_INPUT_CHARS {
                    s.truncate(s.len());
                }
                s
            }
        }
    }

    /// 生成切分路径。双拼模式下同时保留「整串按全拼解释」的路径（宽容输入）。
    fn segment(&self, chars: &[char]) -> Vec<Vec<Seg>> {
        let mut paths = match self.layout {
            Layout::Shuangpin(_) => segment_shuangpin(chars, &self.codes),
            Layout::Full => Vec::new(),
        };
        for p in segment_full(chars) {
            if paths.len() >= MAX_PATHS {
                break;
            }
            let sig: Vec<&str> = p.iter().map(|s| s.syl.as_deref().unwrap_or("")).collect();
            let dup = paths.iter().any(|q| {
                q.len() == p.len()
                    && q.iter()
                        .zip(sig.iter())
                        .all(|(a, b)| a.syl.as_deref().unwrap_or("") == *b)
            });
            if !dup {
                paths.push(p);
            }
        }
        paths.truncate(MAX_PATHS);
        paths
    }

    fn decode_path(&self, orig: &[usize], path: &[Seg], out: &mut Vec<Candidate>) {
        let usable: Vec<&Seg> = path.iter().take_while(|s| s.syl.is_some()).collect();
        if usable.is_empty() {
            return;
        }

        // 覆盖输入前缀的词候选
        let mut key = String::new();
        for k in 1..=usable.len().min(MAX_WORD_SYLLABLES) {
            if k > 1 {
                key.push('\'');
            }
            key.push_str(canon_syl(usable[k - 1].syl.as_deref().unwrap_or_default()));
            let consumed = orig[usable[k - 1].end - 1] + 1;
            let display = key.replace('\'', " ");
            let fuzzy_cost: f64 = usable[..k].iter().map(|s| s.fuzzy).sum();
            for e in self.dict.lookup(&key) {
                let kind = if e.syls <= 1 {
                    CandidateKind::Char
                } else {
                    CandidateKind::Word
                };
                let mut score = (e.freq as f64).ln() + LEN_BONUS * f64::from(e.syls)
                    - fuzzy_cost * FUZZY_PENALTY;
                if consumed == orig.len() && fuzzy_cost == 0.0 {
                    score += EXACT_FULL_BONUS;
                }
                out.push(
                    Candidate::new(e.word.clone(), consumed, kind, score)
                        .with_reading(display.clone()),
                );
            }
        }
    }

    /// Viterbi：按「词惩罚」选择最佳切分，返回唯一最佳假设。
    /// 整句解码：按音节切分做 beam search，返回得分最高的几条整句（高分在前）。
    ///
    /// 每个词按 ln(f/Z) 计分（unigram），WORD_PENALTY 偏好更长的词；有字级搭配模型时，
    /// 词与词交界处再按上下文加分，并让同音词的前几个都参与竞争（「到的」才有机会压过「道德」）。
    /// 没有搭配模型时，beam 的最优路径与逐位置单一最优的 Viterbi 完全相同。
    fn viterbi(&self, segs: &[&Seg], boost: &dyn Fn(&str) -> f64, rich: bool) -> Vec<Hyp> {
        let n = segs.len();
        let ln_z = self.dict.log_total();
        let lm = self.dict.collocations().filter(|_| rich);
        let homophones = if lm.is_some() { LM_HOMOPHONES } else { 1 };
        let mut dp: Vec<Vec<Hyp>> = vec![Vec::new(); n + 1];
        dp[0].push(Hyp::default());
        for i in 0..n {
            let bases = std::mem::take(&mut dp[i]);
            for k in 1..=MAX_WORD_SYLLABLES.min(n - i) {
                let mut key = String::new();
                for (j, s) in segs[i..i + k].iter().enumerate() {
                    if j > 0 {
                        key.push('\'');
                    }
                    key.push_str(canon_syl(s.syl.as_deref().unwrap_or_default()));
                }
                let fuzzy_cost: f64 = segs[i..i + k].iter().map(|s| s.fuzzy).sum();
                let entries = self.dict.lookup(&key);
                // 候选词：(文本, 词分, ln 词频, 覆盖音节数)
                let words: Vec<(String, f64, f64, usize)> = if entries.is_empty() {
                    if k == 1 {
                        let raw = segs[i].syl.clone().unwrap_or_default();
                        vec![(raw, PASS_THROUGH_PENALTY, 0.0, 0)]
                    } else {
                        continue;
                    }
                } else {
                    // 同读音按「词频 + 个人加分」排，只看前几条保持性能；并列时保留词典靠前的那条
                    let mut scored: Vec<(&Entry, f64)> = entries
                        .iter()
                        .take(8)
                        .map(|e| (e, (e.freq as f64).ln() + boost(&e.word)))
                        .collect();
                    scored.sort_by(|a, b| b.1.total_cmp(&a.1));
                    scored
                        .into_iter()
                        .take(homophones)
                        .map(|(e, ln)| (e.word.clone(), ln - ln_z - WORD_PENALTY, ln, k))
                        .collect()
                };
                let pys: Vec<String> = key.split('\'').map(str::to_string).collect();
                for base in &bases {
                    for (text, wscore, sum_ln, matched) in &words {
                        let pass_through = entries.is_empty();
                        let bonus = match lm {
                            Some(lm) if !pass_through && !base.text.is_empty() => {
                                lm.junction(&base.text, text, LM_THRESHOLD as f32) as f64
                                    * LM_WEIGHT
                            }
                            _ => 0.0,
                        };
                        let mut pinyin = base.pinyin.clone();
                        if pass_through {
                            pinyin.push(text.clone());
                        } else {
                            pinyin.extend(pys.iter().cloned());
                        }
                        let cand = Hyp {
                            score: base.score + wscore - fuzzy_cost * FUZZY_PENALTY + bonus,
                            sum_ln: base.sum_ln + sum_ln,
                            words: base.words + 1,
                            matched: base.matched + matched,
                            garbage: base.garbage + usize::from(pass_through),
                            text: format!("{}{}", base.text, text),
                            pinyin,
                            lm: base.lm + bonus,
                        };
                        push_beam(&mut dp[i + k], cand);
                    }
                }
            }
        }
        let mut done = std::mem::take(&mut dp[n]);
        done.sort_by(|a, b| b.score.total_cmp(&a.score));
        done
    }
}

fn dedupe_and_sort(out: &mut Vec<Candidate>) {
    out.sort_by(Candidate::rank_cmp);
    let mut seen: HashSet<(String, usize)> = HashSet::new();
    out.retain(|c| seen.insert((c.text.clone(), c.consumed)));
}

/// 词条按音节数分候选类型。
fn word_kind(entry: &Entry) -> CandidateKind {
    if entry.syls <= 1 {
        CandidateKind::Char
    } else {
        CandidateKind::Word
    }
}

/// key（`ni'hao`）的前缀查询串覆盖了几个完整音节。
/// 词键的内部音节边界（按字母位置）：`xi'an` → {2}。
fn key_boundaries(key: &str) -> std::collections::HashSet<usize> {
    let mut bounds = std::collections::HashSet::new();
    let mut pos = 0;
    for syl in key.split('\'') {
        pos += syl.len();
        bounds.insert(pos);
    }
    bounds
}

fn covered_syllables(key: &str, query: &str) -> usize {
    let mut pos = 0;
    let mut n = 0;
    for syl in key.split('\'') {
        if pos + syl.len() > query.len() {
            break;
        }
        pos += syl.len();
        n += 1;
    }
    n
}

/// 归一化输入：只保留小写字母与 `;`（微软 ing 键），返回字符序列与「归一化 → 原始」索引。
pub fn normalize(input: &str) -> (Vec<char>, Vec<usize>) {
    let mut chars = Vec::new();
    let mut orig = Vec::new();
    for (i, c) in input.chars().enumerate() {
        if c.is_ascii_alphabetic() {
            chars.push(c.to_ascii_lowercase());
            orig.push(i);
        } else if c == ';' {
            chars.push(';');
            orig.push(i);
        }
    }
    (chars, orig)
}

fn segment_full(chars: &[char]) -> Vec<Vec<Seg>> {
    let n = chars.len();
    let mut out: Vec<Vec<Seg>> = Vec::new();
    if n == 0 {
        return out;
    }
    let mut cur: Vec<Seg> = Vec::new();
    // 第一步：纯精确切分（一次 DFS）。纠错不参与切分探索——曾试过「按纠错
    // 位置逐波 DFS」，但每开一波就是一整棵切分树的代价（实测 117µs → 4-10ms），
    // 逐键路径承受不起。
    go_full(0, n, chars, &mut cur, &mut out);
    fn go_full(i: usize, n: usize, chars: &[char], cur: &mut Vec<Seg>, out: &mut Vec<Vec<Seg>>) {
        if out.len() >= MAX_PATHS {
            return;
        }
        if i == n {
            out.push(cur.clone());
            return;
        }
        // 长音节优先：更自然的切分（zhuan+que+du）先被探索，避免短音节组合
        // 占满路径上限。
        for len in (1..=MAX_SYLLABLE_LEN.min(n - i)).rev() {
            let s: String = chars[i..i + len].iter().collect();
            if is_syllable(&s) {
                cur.push(Seg {
                    syl: Some(s),
                    end: i + len,
                    fuzzy: 0.0,
                });
                go_full(i + len, n, chars, cur, out);
                cur.pop();
                if out.len() >= MAX_PATHS {
                    return;
                }
            }
        }
        let rest: String = chars[i..].iter().collect();
        if !is_syllable(&rest) && (is_syllable_prefix(&rest) || rest.len() <= MAX_GARBAGE_TAIL) {
            cur.push(Seg {
                syl: None,
                end: n,
                fuzzy: 0.0,
            });
            out.push(cur.clone());
            cur.pop();
        }
    }
    // 第二步：锚定纠错——在已有精确路径上逐段替换为纠错变体，纯构造、零 DFS。
    // 只锚前 ANCHOR_PATHS 条路径（后面的切分质量差，纠了也没人看）；
    // 含纠错路径凑够 CORRECTED_PATH_TARGET 就停（逐键预算）。
    if n <= MAX_FUZZY_INPUT {
        let mut corrected = 0;
        'anchor: for path in out.iter().take(ANCHOR_PATHS).cloned().collect::<Vec<_>>() {
            for seg_idx in 0..path.len() {
                let (s, end, start) = match &path[seg_idx] {
                    Seg {
                        syl: Some(s),
                        end,
                        ..
                    } => (s.clone(), *end, if seg_idx == 0 { 0 } else { path[seg_idx - 1].end }),
                    _ => continue,
                };
                if end - start < 2 {
                    continue;
                }
                for (canon, cost) in fuzzy_variants(&s) {
                    let mut p = path.clone();
                    p[seg_idx].syl = Some(canon);
                    p[seg_idx].fuzzy = f64::from(cost);
                    out.push(p);
                    corrected += 1;
                    if corrected >= CORRECTED_PATH_TARGET || out.len() >= MAX_PATHS {
                        break 'anchor;
                    }
                }
            }
        }
        // 整串音节级兜底：输入本身就是打错的一个音节（yign→ying、xan→xian）。
        // 锚定纠错只纠「合法切分里的段」，整段打错时锚不到；锚段纠出了别结果
        // 也不代表整段没错，所以不管锚定有没有产出都试。
        // 限音节长度内（≤6）且必须含元音：简拼缩写（bj/nh/wm）天然全声母、
        // 永不含元音，兜底不会污染简拼候选（否则 bj 邻近键纠出 bu，压过「北京」）。
        // 混在正常输入中间的错段（nihao+kian）暂不支持。
        if n >= 2 && n <= MAX_SYLLABLE_LEN {
            let whole: String = chars.iter().collect();
            if whole.contains(['a', 'e', 'i', 'o', 'u', 'v']) && !is_syllable(&whole) {
                for (canon, cost) in fuzzy_variants(&whole) {
                    out.push(vec![Seg {
                        syl: Some(canon),
                        end: n,
                        fuzzy: f64::from(cost),
                    }]);
                    corrected += 1;
                    if corrected >= CORRECTED_PATH_TARGET {
                        break;
                    }
                }
            }
        }
    }
    // 锚定与整串兜底可能产出相同读音的路径，按读音键去重
    let mut seen = std::collections::HashSet::new();
    out.retain(|p| {
        seen.insert(format!(
            "{}|{}",
            p.iter()
                .map(|s| s.syl.clone().unwrap_or_else(|| "_".to_string()))
                .collect::<Vec<_>>()
                .join("+"),
            p.last().map_or(0, |s| s.end)
        ))
    });
    out
}
/// 生成纠错候选音节（代价 1）：相邻换位、单字符删除、邻近键错按、漏打介音、
/// n↔ng、常见声母/韵母混淆。
fn fuzzy_variants(chunk: &str) -> Vec<(String, u8)> {
    let chars: Vec<char> = chunk.chars().collect();
    let mut out: Vec<(String, u8)> = Vec::new();
    fn push(s: String, cost: u8, original: &str, out: &mut Vec<(String, u8)>) {
        if s != original && is_syllable(&s) {
            out.push((s, cost));
        }
    }
    for i in 0..chars.len().saturating_sub(1) {
        let mut v = chars.clone();
        v.swap(i, i + 1);
        push(v.iter().collect(), 1, chunk, &mut out);
    }
    // 邻近键错按：手滑打到左右/上下邻键（gao↔hao、kian→jian、zian→xian），
    // 是机械打字里最高频的一类错误；is_syllable 校验把无关替换自然过滤
    for (i, c) in chars.iter().enumerate() {
        let Some((_, neigh)) = NEIGHBORS.iter().find(|(k, _)| *k == *c) else {
            continue;
        };
        for r in neigh.chars() {
            let mut v = chars.clone();
            v[i] = r;
            push(v.iter().collect(), 1, chunk, &mut out);
        }
    }
    // 漏打介音：声母和韵腹之间少敲了 i/u（xan→xian/xuan、gan→guan），
    // 换位、删除、声韵混淆都覆盖不到这类；介音只补 i/u，且只在声母后补
    for i in 1..chars.len() {
        if !is_initial(chars[i - 1]) || !matches!(chars[i], 'a' | 'e' | 'o') {
            continue;
        }
        for m in ['i', 'u'] {
            let mut v = chars.clone();
            v.insert(i, m);
            push(v.iter().collect(), 1, chunk, &mut out);
        }
    }
    // 只允许删除元音（zhuan→zhun 这类多打了一个元音）；
    // 删除辅音多半是「n/h/s 还没输完」（nih、nhao、wos），交给前缀补全
    // 元音删除的禁区：üe 韵家族（含 v 或 ue 结尾，如 nve/lue/que）删掉一个
    // 元音就变成完全不同的高频音节（nve→nv「女」、lue→le「了」），
    // 会劫持精确读音；zhuan→zhun 这类鼻尾缩短的纠错不受影响。
    let ue_family = chunk.contains('v') || chunk.ends_with("ue");
    for (i, c) in chars.iter().enumerate() {
        if !matches!(c, 'a' | 'e' | 'i' | 'o' | 'u' | 'v') {
            continue;
        }
        if ue_family {
            break;
        }
        let mut v = chars.clone();
        v.remove(i);
        push(v.iter().collect(), 1, chunk, &mut out);
    }
    if chunk.ends_with('n') {
        push(format!("{chunk}g"), 1, chunk, &mut out);
    }
    if chunk.ends_with("ng") {
        push(chunk[..chunk.len() - 1].to_string(), 1, chunk, &mut out);
    }
    const PAIRS: [(&str, &str); 14] = [
        ("zh", "z"),
        ("ch", "c"),
        ("sh", "s"),
        ("n", "l"),
        ("l", "n"),
        ("f", "h"),
        ("r", "l"),
        ("an", "ang"),
        ("en", "eng"),
        ("in", "ing"),
        ("ian", "iang"),
        ("uan", "uang"),
        ("ong", "eng"),
        ("ong", "iong"),
    ];
    for (a, b) in PAIRS {
        if let Some(pos) = chunk.find(a) {
            let mut t = chunk.to_string();
            t.replace_range(pos..pos + a.len(), b);
            push(t, 1, chunk, &mut out);
        }
        if let Some(pos) = chunk.find(b) {
            let mut t = chunk.to_string();
            t.replace_range(pos..pos + b.len(), a);
            push(t, 1, chunk, &mut out);
        }
    }
    out.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.len().cmp(&a.0.len())));
    out.dedup_by(|a, b| a.0 == b.0);
    out.truncate(8);
    out
}

/// 声母字母（不含自成音节的 y/w 和韵母专用 v），用于介音补全的位置判断。
fn is_initial(c: char) -> bool {
    matches!(
        c,
        'b' | 'c' | 'd' | 'f' | 'g' | 'h' | 'j' | 'k' | 'l' | 'm' | 'n' | 'p' | 'q' | 'r' | 's'
            | 't' | 'x' | 'z'
    )
}

/// QWERTY 邻近键表：横邻 + 上下邻。错按几乎都落在这圈键里。
const NEIGHBORS: &[(char, &str)] = &[
    ('q', "wa"),
    ('w', "qeasd"),
    ('e', "wrsd"),
    ('r', "etdf"),
    ('t', "ryfg"),
    ('y', "tugh"),
    ('u', "yihj"),
    ('i', "uojk"),
    ('o', "ipkl"),
    ('p', "ol"),
    ('a', "qwsz"),
    ('s', "adwezx"),
    ('d', "sferxc"),
    ('f', "dgrtcv"),
    ('g', "fhtyvb"),
    ('h', "gjyubn"),
    ('j', "hkuinm"),
    ('k', "jliom"),
    ('l', "kop"),
    ('z', "asx"),
    ('x', "zcsd"),
    ('c', "xdfv"),
    ('v', "cfgb"),
    ('b', "vngh"),
    ('n', "bmhj"),
    ('m', "nkj"),
];

fn segment_shuangpin(chars: &[char], codes: &Codes) -> Vec<Vec<Seg>> {
    let mut out: Vec<Vec<Seg>> = Vec::new();
    let mut cur: Vec<Seg> = Vec::new();
    go_sp(0, chars, codes, &mut cur, &mut out);
    fn go_sp(i: usize, chars: &[char], codes: &Codes, cur: &mut Vec<Seg>, out: &mut Vec<Vec<Seg>>) {
        let n = chars.len();
        if out.len() >= MAX_PATHS {
            return;
        }
        if i == n {
            out.push(cur.clone());
            return;
        }
        if i + 2 <= n {
            let code: String = chars[i..i + 2].iter().collect();
            for syl in codes.syllables(&code).to_vec() {
                cur.push(Seg {
                    syl: Some(syl.to_string()),
                    end: i + 2,
                    fuzzy: 0.0,
                });
                go_sp(i + 2, chars, codes, cur, out);
                cur.pop();
                if out.len() >= MAX_PATHS {
                    return;
                }
            }
        }
        if n - i == 1 {
            cur.push(Seg {
                syl: None,
                end: n,
                fuzzy: 0.0,
            });
            out.push(cur.clone());
            cur.pop();
        }
    }
    out
}

fn greedy_full(chars: &[char]) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let mut matched = None;
        for len in (1..=MAX_SYLLABLE_LEN.min(chars.len() - i)).rev() {
            let s: String = chars[i..i + len].iter().collect();
            if is_syllable(&s) {
                matched = Some((s, len));
                break;
            }
        }
        match matched {
            Some((s, len)) => {
                parts.push(s);
                i += len;
            }
            None => {
                parts.push(chars[i].to_string());
                i += 1;
            }
        }
    }
    parts.join(" ")
}

fn chunk_decode(chars: &[char], codes: &Codes) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if i + 2 <= chars.len() {
            let code: String = chars[i..i + 2].iter().collect();
            let syls = codes.syllables(&code);
            if let Some(first) = syls.first() {
                parts.push((*first).to_string());
                i += 2;
                continue;
            }
        }
        parts.push(chars[i].to_string());
        i += 1;
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict() -> Arc<Dictionary> {
        Arc::new(Dictionary::embedded())
    }

    fn first(decode: &PinyinDecoder, input: &str) -> String {
        decode.candidates(input)[0].text.clone()
    }

    #[test]
    fn collocations_pick_homophone_by_context() {
        let mut dict = Dictionary::new();
        dict.insert("shi'hou", "时候", 50000);
        dict.insert("dao'de", "道德", 20000);
        dict.insert("dao'de", "到的", 5000);
        let without = PinyinDecoder::new(Arc::new(clone_dict(&dict)), Layout::Full);
        assert_eq!(first(&without, "shihoudaode"), "时候道德");
        dict.set_collocations(Some(Arc::new(liana_dict::lm::Collocations::build([
            ("时候到".to_string(), 15.6),
            ("候到".to_string(), 12.0),
        ]))));
        let with = PinyinDecoder::new(Arc::new(dict), Layout::Full);
        let cands = with.candidates("shihoudaode");
        assert_eq!(cands[0].text, "时候到的");
        // 另一种说法作为备选整句保留
        assert!(cands.iter().any(|c| c.text == "时候道德"));
    }

    fn clone_dict(d: &Dictionary) -> Dictionary {
        let mut out = Dictionary::new();
        out.merge(d);
        out
    }

    #[test]
    fn jianpin_prior_beats_raw_frequency() {
        let mut dict = Dictionary::new();
        dict.insert("mei'ti", "媒体", 42000);
        dict.insert("ming'tian", "明天", 31000);
        dict.insert("dong'shi'hui", "董事会", 6000);
        dict.insert("dan'shi", "但是", 170000);
        let d = PinyinDecoder::new(Arc::new(dict), Layout::Full);
        assert_eq!(first(&d, "mt"), "明天");
        // sh 当作一个声母：dsh → 但是（纯首字母查询本身找不到它）
        assert_eq!(first(&d, "dsh"), "但是");
    }

    #[test]
    fn full_pinyin_common_words() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        assert_eq!(first(&d, "nihao"), "你好");
        assert_eq!(first(&d, "beijing"), "北京");
        assert_eq!(first(&d, "shurufa"), "输入法");
        assert_eq!(first(&d, "zhongguo"), "中国");
        assert_eq!(first(&d, "woshi"), "我是");
    }

    #[test]
    fn consumed_counts_chars() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        assert_eq!(d.candidates("nihao")[0].consumed, 5);
        let c = d
            .candidates("nihaoma")
            .into_iter()
            .find(|c| c.text == "你")
            .expect("应包含「你」");
        assert_eq!(c.consumed, 2);
    }

    #[test]
    fn trailing_partial_is_not_consumed() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let cands = d.candidates("nihm");
        assert!(
            cands
                .iter()
                .filter(|c| c.kind != CandidateKind::Literal)
                .all(|c| c.consumed <= 2),
            "{cands:?}"
        );
        assert!(cands.iter().any(|c| c.text == "你"));
        assert_eq!(d.preedit("nihm"), "ni h m");
    }

    #[test]
    fn literal_fallback_always_present() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let cands = d.candidates("zzz");
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].text, "zzz");
        assert_eq!(cands[0].kind, CandidateKind::Literal);
        assert_eq!(cands[0].consumed, 3);
    }

    #[test]
    fn shuangpin_flypy_types_words() {
        let d = PinyinDecoder::new(dict(), Layout::Shuangpin(Scheme::Flypy));
        assert_eq!(first(&d, "nihc"), "你好");
        assert_eq!(first(&d, "vsgo"), "中国");
        assert_eq!(first(&d, "uurufa"), "输入法");
        assert_eq!(first(&d, "aj"), "安");
        assert_eq!(d.preedit("nihc"), "ni hao");
    }

    #[test]
    fn shuangpin_falls_back_to_full_spelling() {
        let d = PinyinDecoder::new(dict(), Layout::Shuangpin(Scheme::Flypy));
        assert_eq!(first(&d, "nihao"), "你好");
    }

    #[test]
    fn input_longer_than_cap_is_bounded() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let long = "ni".repeat(80);
        let cands = d.candidates(&long);
        assert!(!cands.is_empty());
    }

    #[test]
    fn apostrophe_is_ignored_for_decoding_but_counted() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let c = d
            .candidates("xi'an")
            .into_iter()
            .find(|c| c.text == "西安")
            .expect("应包含「西安」");
        assert_eq!(c.consumed, 5, "含撇号在内的消费数应为 5");
    }

    #[test]
    fn single_letter_shows_chinese_chars() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let cands = d.candidates("n");
        assert_eq!(cands[0].text, "你", "单字母 n 的首选应是「你」: {cands:?}");
        assert!(cands.iter().any(|c| c.text == "那"));
        assert!(cands.iter().all(|c| c.consumed == 1));
    }

    #[test]
    fn partial_syllable_completes_word() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let nih = d.candidates("nih");
        assert_eq!(nih[0].text, "你好", "nih 首选应是「你好」: {nih:?}");
        assert_eq!(nih[0].consumed, 3);
        let beij = d.candidates("beij");
        assert_eq!(beij[0].text, "北京", "beij 首选应是「北京」: {beij:?}");
    }

    #[test]
    fn complete_syllable_keeps_exact_candidate_first() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let shi = d.candidates("shi");
        assert_eq!(shi[0].text, "是", "shi 首选应仍是「是」: {shi:?}");
        assert!(
            shi.iter().any(|c| c.text == "时候"),
            "时候应作为前缀候选出现"
        );
    }

    fn fuzzy_dict() -> Arc<Dictionary> {
        let mut d = Dictionary::new();
        d.insert("zhun'que'du", "准确度", 200_000);
        d.insert("zhun'que", "准确", 250_000);
        d.insert("zhuan'qu", "专区", 300_000);
        d.insert("ying", "应", 500_000);
        d.insert("yin", "因", 400_000);
        d.insert("zhuang", "装", 400_000);
        d.insert("zhuan", "转", 500_000);
        d.insert("shuang'pin", "双拼", 100_000);
        Arc::new(d)
    }

    #[test]
    fn fuzzy_edit_distance_correction() {
        // 用户示例：zhunquedu 误打成 zhuanquedu（多打了一个 a）
        let d = PinyinDecoder::new(fuzzy_dict(), Layout::Full);
        let c = d.candidates("zhuanquedu");
        assert_eq!(c[0].text, "准确度", "{c:?}");
        assert_eq!(c[0].comment.as_deref(), Some("zhun que du"));
    }

    #[test]
    fn fuzzy_adjacent_transposition() {
        // ing 打成 ign（n/g 反了）；uang 打成 uagn
        let d = PinyinDecoder::new(fuzzy_dict(), Layout::Full);
        let exact = d.candidates("ying");
        let typo = d.candidates("yign");
        assert!(
            typo.iter().any(|c| c.text == exact[0].text),
            "yign 应纠回 {}: {typo:?}",
            exact[0].text
        );
        assert_eq!(
            d.candidates("zhuang")[0].text,
            d.candidates("zhuagn")[0].text
        );
    }

    #[test]
    fn fuzzy_keeps_exact_first() {
        let d = PinyinDecoder::new(fuzzy_dict(), Layout::Full);
        assert_eq!(d.candidates("zhuang")[0].text, "装");
        assert_eq!(d.candidates("zhuan")[0].text, "转");
        assert_eq!(d.candidates("shuangpin")[0].text, "双拼");
    }

    #[test]
    fn fuzzy_keyboard_adjacency() {
        // gao 是 hao 的横邻键错按；kian 是 jian 的邻近键错按
        let mut d = Dictionary::new();
        d.insert("hao", "好", 500_000);
        d.insert("gao", "高", 400_000);
        d.insert("jian", "见", 300_000);
        let d = PinyinDecoder::new(Arc::new(d), Layout::Full);
        let c = d.candidates("gao");
        assert_eq!(c[0].text, "高", "精确拼写必须排第一: {c:?}");
        assert!(
            c.iter().any(|x| x.text == "好"),
            "gao 应纠出 hao 的「好」: {c:?}"
        );
        let kian = d.candidates("kian");
        assert!(
            kian.iter().any(|x| x.text == "见"),
            "kian 应纠回 jian: {kian:?}"
        );
    }

    #[test]
    fn fuzzy_missing_medial() {
        // xan：声母后漏了介音，可补 i（xian）或 u（xuan）
        let mut d = Dictionary::new();
        d.insert("xian", "先", 500_000);
        d.insert("xuan", "选", 450_000);
        let d = PinyinDecoder::new(Arc::new(d), Layout::Full);
        let c = d.candidates("xan");
        assert!(c.iter().any(|x| x.text == "先"), "xan 应纠回 xian: {c:?}");
        assert!(c.iter().any(|x| x.text == "选"), "xan 应纠回 xuan: {c:?}");
    }

    #[test]
    fn single_syllable_prefers_char() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let xi = d.candidates("xi");
        assert_eq!(xi[0].kind, CandidateKind::Char, "单音节应先给单字: {xi:?}");
        assert_eq!(xi[0].consumed, 2);
        assert!(
            xi.iter().any(|c| c.kind == CandidateKind::Word),
            "词组仍应出现在后面"
        );
    }

    #[test]
    fn shuangpin_prefix_completion() {
        let d = PinyinDecoder::new(dict(), Layout::Shuangpin(Scheme::Flypy));
        let nih = d.candidates("nih");
        assert_eq!(nih[0].text, "你好", "小鹤 nih 首选应是「你好」: {nih:?}");
    }

    #[test]
    fn initials_abbreviation_matches_words() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let nh = d.candidates("nh");
        assert_eq!(nh[0].text, "你好", "nh 首选应是「你好」: {nh:?}");
        assert_eq!(nh[0].consumed, 2);
        let bj = d.candidates("bj");
        assert_eq!(bj[0].text, "北京", "bj 首选应是「北京」: {bj:?}");
        let wm = d.candidates("wm");
        assert_eq!(wm[0].text, "我们", "wm 首选应是「我们」: {wm:?}");
    }

    #[test]
    fn mixed_abbreviation_matches_words() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let nhao = d.candidates("nhao");
        assert_eq!(nhao[0].text, "你好", "nhao 首选应是「你好」: {nhao:?}");
        assert_eq!(nhao[0].consumed, 4);
    }

    fn role_of(cands: &[Candidate], text: &str) -> CommentRole {
        cands
            .iter()
            .find(|c| c.text == text)
            .unwrap_or_else(|| panic!("应包含「{text}」: {cands:?}"))
            .comment_role
    }

    #[test]
    fn exact_reading_is_marked_redundant() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let c = d.candidates("nihao");
        assert_eq!(c[0].text, "你好");
        assert_eq!(c[0].comment.as_deref(), Some("ni hao"));
        assert_eq!(c[0].comment_role, CommentRole::ExactReading);
        // 分隔符 / 大写不影响判定
        let c = d.candidates("Ni'hao");
        assert_eq!(role_of(&c, "你好"), CommentRole::ExactReading);
        // 部分消费：nihaoma 里的「你」只吃了 ni
        let c = d.candidates("nihaoma");
        assert_eq!(role_of(&c, "你"), CommentRole::ExactReading);
    }

    #[test]
    fn corrected_reading_is_kept() {
        // 编辑距离纠错：zhuan → zhun
        let d = PinyinDecoder::new(fuzzy_dict(), Layout::Full);
        let c = d.candidates("zhuanquedu");
        assert_eq!(c[0].text, "准确度");
        assert_eq!(c[0].comment_role, CommentRole::CorrectedReading);
        // 模糊音：zhong 打成 zong
        let mut fz = Dictionary::new();
        fz.insert("zhong'guo", "中国", 500_000);
        let d = PinyinDecoder::new(Arc::new(fz), Layout::Full);
        let c = d.candidates("zongguo");
        assert_eq!(role_of(&c, "中国"), CommentRole::CorrectedReading, "{c:?}");
        let c = d.candidates("zhongguo");
        assert_eq!(role_of(&c, "中国"), CommentRole::ExactReading);
    }

    #[test]
    fn abbreviation_reading_is_kept() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let c = d.candidates("nh");
        assert_eq!(c[0].text, "你好");
        assert_eq!(c[0].comment_role, CommentRole::CorrectedReading);
        let c = d.candidates("nhao");
        assert_eq!(role_of(&c, "你好"), CommentRole::CorrectedReading);
        let c = d.candidates("wdmz");
        assert!(
            c.iter()
                .filter(|c| c.kind != CandidateKind::Literal)
                .all(|c| c.comment_role != CommentRole::ExactReading),
            "简拼不应被当作精确读音: {c:?}"
        );
    }

    #[test]
    fn shuangpin_exact_reading() {
        // 小鹤：ni → ni，hc → hao
        let d = PinyinDecoder::new(dict(), Layout::Shuangpin(Scheme::Flypy));
        let c = d.candidates("nihc");
        assert_eq!(role_of(&c, "你好"), CommentRole::ExactReading, "{c:?}");
    }

    #[test]
    fn literal_has_no_reading() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let c = d.candidates("nihao");
        let lit = c
            .iter()
            .find(|c| c.kind == CandidateKind::Literal)
            .expect("原文候选");
        assert_eq!(lit.comment_role, CommentRole::Label);
    }

    #[test]
    fn full_pinyin_still_wins_over_abbreviation() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        assert_eq!(d.candidates("ni")[0].text, "你");
        assert_eq!(d.candidates("nihao")[0].text, "你好");
        assert_eq!(d.candidates("shi")[0].text, "是");
    }
}

#[cfg(test)]
mod perf {
    use super::*;
    use std::sync::Arc;
    use std::time::Instant;

    /// 纠错引入的逐键回归守卫：最坏情况（12 字符全纠错输入）平均解码必须
    /// 保持在毫秒级以下。阈值故意放宽到 2ms，只拦数量级劣化，不追抖动。
    #[test]
    fn perf_worst_case_typo_decode() {
        let mut d = Dictionary::new();
        d.insert("zhun'que'du", "准确度", 200_000);
        d.insert("jian'she'", "建设", 300_000);
        let d = PinyinDecoder::new(Arc::new(d), Layout::Full);
        let inputs = ["zhuanquedu", "kiansheu", "xianjihao", "gaojignshe"];
        let t = Instant::now();
        let mut n = 0usize;
        for _ in 0..250 {
            for input in inputs {
                n += d.candidates(input).len();
            }
        }
        let el = t.elapsed();
        println!("1000 次解码（含纠错）共 {el:?}，平均 {} µs/次", el.as_micros() / 1000);
        assert!(n > 0);
        assert!(el.as_micros() < 2_000_000, "解码过慢: {el:?}");
    }
}
