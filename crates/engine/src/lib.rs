//! 会话编排：持有输入缓冲、组合态与用户词模型，是平台前端唯一需要打交道的对象。

use std::sync::{Arc, Mutex};

use liana_core::backup::{self, BackupError};
use liana_core::{Candidate, CandidateKind, Composition, Decoder, Mode, UserModel};
use liana_dict::Dictionary;
use liana_emoji::EmojiDecoder;
use liana_en::EnDecoder;
use liana_ja::JaDecoder;
use liana_pinyin::{Layout, PinyinDecoder};
use liana_symbol::SymbolDecoder;

use evolution::EvolutionMemory;

pub mod app_mode;
pub mod evolution;
pub mod feed;
pub mod stats;
pub use app_mode::AppModeMemory;

/// 单次组合态最多返回的候选数（前端分页展示）。
pub const MAX_CANDIDATES: usize = 30;
/// 中英混输时最多掺入的英文候选数。
const MAX_MIXED_ENGLISH: usize = 5;
/// 中英混输里「精确英文词」判定的最短长度（避免 `he`/`an` 这类拼音噪声；3 字词 get/run/map 放行）。
const MIN_EXACT_ENGLISH: usize = 3;

// ——— AI 辅助短语（不做手动短语表，全部自动学习）———
/// 参与合并的最近上屏段数：窗口内的所有后缀组合都会被记一次。
const PHRASE_WINDOW: usize = 3;
/// 短语的按键序列上限，超出不再学（太长的句子复用率低）。
const MAX_PHRASE_KEYS: usize = 14;
/// 短语的字数上限。
const MAX_PHRASE_CHARS: usize = 8;
/// 触发短语补全的最短按键数。
const MIN_PHRASE_QUERY: usize = 3;
/// 按键完全命中时的最低学习次数。
const MIN_PHRASE_EXACT: u32 = 2;
/// 按键只是前缀（补全）时的最低学习次数——门槛更高，避免打一半就被抢。
const MIN_PHRASE_PREFIX: u32 = 3;
/// 短语候选的基础分（对齐整句候选的量级，见 `liana_pinyin` 的打分）。
const PHRASE_SCORE_EXACT: f64 = 18.0;
const PHRASE_SCORE_PREFIX: f64 = 12.0;

// ——— 知你教学层（ADR-0008）序列判定 ———
/// 上屏后多少秒内按下删除，算「选了又删」（强负信号）。
const DELETE_WINDOW_SECS: u64 = 10;
/// 删除后多少秒内的下一次选词，算「纠正后的真实意图」（+1.5）。
const RESELECT_WINDOW_SECS: u64 = 30;

/// 一次选词的评估记录（ADR-0008 E3）：傍晚小结拿它对比「学习开 vs 关」。
///
/// - `actual_top1`：选的是学习重排后的第 1 个候选吗；
/// - `base_top1`：剔除学习修正的基线排序里，这个词也是第 1 吗（反事实）；
///   两者之差就是今天学习的收益。学习关闭时基线 = 实际，收益读作 0。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionEval {
    pub actual_top1: bool,
    pub base_top1: bool,
    pub reselect: bool,
    pub alt_rank: bool,
}

pub struct Session {
    mode: Mode,
    buffer: String,
    comp: Composition,
    dict: Arc<Dictionary>,
    en: Arc<EnDecoder>,
    ja: JaDecoder,
    emoji: EmojiDecoder,
    symbol: SymbolDecoder,
    user: UserModel,
    /// 上一个上屏内容，用于二元组预测（只在内存、进程退出即消失）。
    last_committed: Option<String>,
    /// 最近几段上屏的 `(按键, 文本)`，用于自动合成短语。
    recent: Vec<(String, String)>,
    /// 候选是否转成繁体显示（学习与重排始终用简体原文）。
    traditional: bool,
    /// 与 `comp.candidates` 同下标的简体原文，仅在繁体显示时非空。
    origins: Vec<String>,
    /// 知你账本（ADR-0008）：FFI 注入进程级共享实例，独立使用时是私有账本。
    evolution: Arc<Mutex<EvolutionMemory>>,
    /// 营养库（ADR-0008 喂食层）：营养词的加分与按键召回都从这里出，
    /// 忘记即移除全部效果；跨会话一致性由前端重导入保证。
    nutrition: feed::NutritionLibrary,
    /// 知你学习开关（前端在激活时按用户设置同步）。
    evolution_enabled: bool,
    /// 决策上下文：前台应用 bundle id（前端在激活时同步）。
    evolution_app: Option<String>,
    /// 决策上下文：本地时段桶用的小时（0-23）。
    evolution_hour: u32,
    /// 知你的「当前时刻」缓存：重排衰减用，精度到分钟级足够（半衰 14 天）。
    evolution_now: u64,
    /// 最近一次选词的 (词, 特征)：等前端确认（含越级/删除/重选）后记账。
    pending_selection: Option<(String, Vec<String>)>,
    /// 学习重排前的基线顺序（简体原文，反事实评估用）；无重排语境时为 None。
    base_order: Option<Vec<String>>,
    /// 本次选词待确认的评估：(实际首选命中, 反事实首选命中)。
    pending_eval: Option<(bool, bool)>,
    /// 最近一次确认过的选词评估，前端取走即清。
    last_eval: Option<SelectionEval>,
    /// 上一次已记账的选词与特征：删除负奖励要落回当初的上下文。
    last_selection: Option<(String, Vec<String>)>,
    last_selection_at: u64,
    /// 同一次选词只罚一次删除（连按删除不会叠加负奖励）。
    last_selection_deleted: bool,
    /// 删除已发生，等待重选；附带武装时刻用于过期判定。
    reselect_armed_at: Option<u64>,
}

impl Session {
    pub fn new(dict: Arc<Dictionary>) -> Self {
        Self::with_mode(dict, Mode::Pinyin)
    }

    pub fn with_mode(dict: Arc<Dictionary>, mode: Mode) -> Self {
        let mut session = Self {
            mode,
            buffer: String::new(),
            comp: Composition::default(),
            dict,
            en: EnDecoder::embedded_shared(),
            ja: JaDecoder,
            emoji: EmojiDecoder,
            symbol: SymbolDecoder,
            user: UserModel::new(),
            last_committed: None,
            recent: Vec::new(),
            traditional: false,
            origins: Vec::new(),
            evolution: Arc::new(Mutex::new(EvolutionMemory::new())),
            nutrition: feed::NutritionLibrary::new(),
            evolution_enabled: true,
            evolution_app: None,
            evolution_hour: 0,
            evolution_now: 0,
            pending_selection: None,
            base_order: None,
            pending_eval: None,
            last_eval: None,
            last_selection: None,
            last_selection_at: 0,
            last_selection_deleted: false,
            reselect_armed_at: None,
        };
        session.refresh();
        session
    }

    /// 上一个上屏内容（候选预测上下文）。
    pub fn last_committed(&self) -> Option<&str> {
        self.last_committed.as_deref()
    }

    /// 清空预测上下文（例如前端切换焦点、退出输入状态时调用）。
    pub fn reset_context(&mut self) {
        self.last_committed = None;
        self.recent.clear();
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// 候选是否以繁体呈现。
    pub fn traditional(&self) -> bool {
        self.traditional
    }

    /// 切换简/繁显示。只影响呈现与上屏文本，用户词与重排仍以简体为准。
    pub fn set_traditional(&mut self, on: bool) {
        if self.traditional != on {
            self.traditional = on;
            self.refresh();
        }
    }

    pub fn buffer(&self) -> &str {
        &self.buffer
    }

    pub fn composition(&self) -> &Composition {
        &self.comp
    }

    pub fn user_model(&self) -> &UserModel {
        &self.user
    }

    pub fn user_model_mut(&mut self) -> &mut UserModel {
        &mut self.user
    }

    /// 导出用户数据备份包（带版本头与 CRC32，见 `liana_core::backup`）。
    ///
    /// 包内是明文 TSV：写盘时由前端用本机密钥加密，导出明文须用户二次确认。
    pub fn export_backup(&self) -> String {
        let body = self.user.export_tsv();
        let items = body.lines().filter(|l| !l.is_empty()).count();
        backup::pack(backup::KIND_USERDATA, items, &body)
    }

    /// 导入备份包。`merge` 为真时同名条目取较大次数（重复导入不翻倍），
    /// 否则以备份为准覆盖。校验失败时**不改动**任何现有数据。
    pub fn import_backup(&mut self, text: &str, merge: bool) -> Result<usize, BackupError> {
        let b = backup::unpack(text)?;
        if b.kind != backup::KIND_USERDATA {
            return Err(BackupError::NotBackup);
        }
        let n = if merge {
            self.user.merge_tsv(&b.body)
        } else {
            self.user.import_tsv(&b.body)
        };
        Ok(n)
    }

    /// 前端按键入口。只接受字母与 `'`、`;`（微软双拼 ing 键）；
    /// 下划线随时可入缓冲（代码标识符意图，getUser/get_user）；
    /// 英文串（纯字母组合解码不出中文）里允许续接网址/邮箱/版本号符号与数字。
    pub fn feed(&mut self, ch: char) -> bool {
        let identifier_underscore =
            ch == '_' && matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_) | Mode::English);
        let ok = ch.is_ascii_alphabetic() || ch == '\'' || ch == ';' || identifier_underscore;
        if !ok {
            // 英文串续接：example.ai、http://、someone@example.com、v1.2——
            // 符号与数字直接进组合，空格/回车由前端原样上屏。
            // url_prefix_like 额外放行 `www.`/`http:` 这类「首字符点」：否则 `www`
            // 会命中整词短拼候选（万维网）被当作中文，网址就打不下去。
            if matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_) | Mode::English)
                && (self.english_like() || self.url_prefix_like())
                && (ch.is_ascii_punctuation() || ch.is_ascii_digit())
            {
                self.buffer.push(ch);
                self.refresh();
                return true;
            }
            return false;
        }
        match self.mode {
            // 中文模式保留大小写：大写是「英文意图」信号，继续由解码器小写归一化
            Mode::Pinyin | Mode::Shuangpin(_) | Mode::English => self.buffer.push(ch),
            _ => self.buffer.push(ch.to_ascii_lowercase()),
        }
        self.refresh();
        true
    }

    /// 组合是否已是「英文串」：缓冲非空、模式可打中文、且没有任何**全覆盖**
    /// 的汉字候选——整串解码不出中文（`example`，部分覆盖的零星单字不算），
    /// 或全覆盖命中英文词（`hello`），或含下划线（`get_user`，标识符意图）。
    /// 中文组合（全覆盖汉字候选）绝不触发。
    fn english_like(&self) -> bool {
        let raw_len = self.buffer.chars().count();
        !self.buffer.is_empty()
            && matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_) | Mode::English)
            && (self.buffer.contains('_')
                || !self.comp.candidates.iter().any(|c| {
                    c.consumed == raw_len && c.text.chars().any(is_phrase_char)
                }))
    }

    /// 网址/邮箱常见前缀（`www`/`http`/`https`/`ftp`/`mailto`），或已含 `.` `/` `@` `:`
    /// 的纯 ASCII 串。用于让 `www.` 的首个 `.` 不被中文候选（万维网）阻断。
    fn url_prefix_like(&self) -> bool {
        if self.buffer.is_empty() || !self.buffer.is_ascii() {
            return false;
        }
        let b = self.buffer.to_ascii_lowercase();
        if b.contains(&['.', '/', '@', ':'][..]) {
            return true;
        }
        matches!(b.as_str(), "www" | "http" | "https" | "ftp" | "mailto")
    }

    pub fn backspace(&mut self) -> bool {
        if self.buffer.pop().is_some() {
            self.refresh();
            true
        } else {
            false
        }
    }

    pub fn clear(&mut self) {
        self.buffer.clear();
        self.comp = Composition::default();
        self.pending_selection = None;
        self.pending_eval = None;
        self.reselect_armed_at = None;
    }

    pub fn set_mode(&mut self, mode: Mode) {
        if self.mode != mode {
            self.mode = mode;
            self.clear();
        }
    }

    /// 选择候选词上屏；返回提交文本，剩余缓冲继续解码。
    pub fn select(&mut self, index: usize) -> Option<String> {
        let cand = self.comp.candidates.get(index)?.clone();
        let keys: String = self.buffer.chars().take(cand.consumed).collect();
        // 学习始终记简体原文：繁体只是呈现层，换回简体显示时重排仍然生效。
        let learned = self
            .origins
            .get(index)
            .cloned()
            .unwrap_or_else(|| cand.text.clone());
        // 教学层：特征必须按「选择瞬间」的上下文捕获——后面 learn_context 会改写它。
        self.pending_selection = self.evolution_pending(&learned);
        // E3 反事实评估：这个词在学习重排前的基线排序里是不是首选？
        let actual_top1 = index == 0;
        let base_top1 = self
            .base_order
            .as_ref()
            .and_then(|order| order.first())
            .map(|top| top == &learned)
            .unwrap_or(actual_top1);
        self.pending_eval = Some((actual_top1, base_top1));
        self.consume(cand.consumed);
        if self.mode != Mode::Emoji {
            self.user.record(&learned);
            // 短语要用「上一段」的按键，必须排在 learn_context 之前
            self.learn_phrase(&keys, &learned);
            self.learn_context(&learned);
        }
        Some(cand.text)
    }

    /// 把第 `index` 个候选提到第一位（前端用本机模型重排长句时调用）。
    ///
    /// 只在同一等价层内换位（覆盖的按键数相同、都不是原样上屏），不改学习记录；
    /// 返回是否换了位置。
    pub fn promote(&mut self, index: usize) -> bool {
        let cands = &self.comp.candidates;
        if index == 0 || index >= cands.len() || !same_tier(&cands[0], &cands[index]) {
            return false;
        }
        let cand = self.comp.candidates.remove(index);
        self.comp.candidates.insert(0, cand);
        if index < self.origins.len() {
            let origin = self.origins.remove(index);
            self.origins.insert(0, origin);
        }
        true
    }

    /// 原样上屏当前缓冲。
    pub fn commit_raw(&mut self) -> Option<String> {
        if self.buffer.is_empty() {
            return None;
        }
        let s = std::mem::take(&mut self.buffer);
        self.learn_context(&s);
        // 原样上屏不是选词：挂起的选词奖励、评估与重选期待一并作废。
        self.pending_selection = None;
        self.pending_eval = None;
        self.reselect_armed_at = None;
        self.refresh();
        Some(s)
    }

    /// 外部上屏（语音识别结果等）的学习入口：记词 + 更新二元组上下文。
    ///
    /// 与 `select`/`commit_raw` 的区别：外部文本没有按键序列，不进短语库
    /// （短语必须绑定按键才能被拼音召回），但 unigram 与上下文对
    /// 「说完接着打字」同样有效——语音上屏的词会给下一个打的词二元组加分。
    pub fn commit_external(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        self.user.record(text);
        self.learn_context(text);
    }

    // ──────────── 知你喂食层（ADR-0008 E2 接线） ────────────

    /// 营养库只读访问（FFI 列举用）。
    pub fn nutrition(&self) -> &feed::NutritionLibrary {
        &self.nutrition
    }

    /// 喂入一条营养词：按键串由词典的单字读音派生（缺字的词只享受加分）。
    /// 返回是否写入。
    pub fn nutrition_add(&mut self, term: &str, source: &str, strength: u32, now: u64) -> bool {
        let keys = derive_nutrition_keys(term, &self.dict);
        self.nutrition.add(term, &keys, source, strength, now)
    }

    /// 忘记一条营养词（加分与按键召回一并消失）。返回是否存在。
    pub fn nutrition_forget(&mut self, term: &str) -> bool {
        self.nutrition.forget(term)
    }

    /// 清空营养库。
    pub fn nutrition_forget_all(&mut self) {
        self.nutrition.forget_all();
    }

    /// 营养库 TSV 导出（词\t按键串\t出处\t强度\t加入时间）。
    pub fn nutrition_export(&self) -> String {
        self.nutrition.export_tsv()
    }

    /// 营养库 TSV 导入（覆盖同名条目），返回成功行数。
    pub fn nutrition_import(&mut self, tsv: &str) -> usize {
        self.nutrition.import_tsv(tsv)
    }

    // ──────────── 知你教学层（ADR-0008 E1 接线） ────────────

    /// 注入共享账本（FFI 层用：进程内所有会话共享一份「越用越懂你」）。
    pub fn set_evolution_memory(&mut self, memory: Arc<Mutex<EvolutionMemory>>) {
        self.evolution = memory;
    }

    /// 同步决策上下文与开关（前端在会话激活时调用）；`now` 同时刷新重排时钟。
    pub fn set_evolution_context(
        &mut self,
        app: Option<&str>,
        hour: u32,
        enabled: bool,
        now: u64,
    ) {
        self.evolution_app = app.map(str::to_string).filter(|a| !a.is_empty());
        self.evolution_hour = hour;
        self.evolution_enabled = enabled;
        self.evolution_now = now;
    }

    pub fn evolution_enabled(&self) -> bool {
        self.evolution_enabled
    }

    /// 当前上下文特征：词法窗（上次上屏）+ 应用 + 时段 + 主题指纹。
    fn evolution_features(&self) -> Vec<String> {
        let lex = self.last_committed.clone().unwrap_or_default();
        let mut features = evolution::context_features(
            &lex,
            self.evolution_app.as_deref(),
            self.evolution_hour,
        );
        features.extend(evolution::topic_features(&lex, 3));
        features
    }

    /// 选择瞬间的待记账项：词 + 当时的上下文特征。表情模式不参与。
    fn evolution_pending(&self, word: &str) -> Option<(String, Vec<String>)> {
        if !self.evolution_enabled || self.mode == Mode::Emoji || word.is_empty() {
            return None;
        }
        Some((word.to_string(), self.evolution_features()))
    }

    /// 前端确认了一次选词：`alt_rank` = 数字键选了第 2+ 候选；
    /// 删除后的窗口内重选记强正，其余按正常选词/越级选词记账。
    pub fn note_selection(&mut self, alt_rank: bool, now: u64) {
        let reselect = self
            .reselect_armed_at
            .is_some_and(|at| now.saturating_sub(at) <= RESELECT_WINDOW_SECS);
        // E3 评估：无论学习开关都产出——关闭时基线 = 实际，收益读作 0。
        if let Some((actual_top1, base_top1)) = self.pending_eval.take() {
            self.last_eval = Some(SelectionEval {
                actual_top1,
                base_top1,
                reselect,
                alt_rank,
            });
        }
        let Some((word, features)) = self.pending_selection.take() else {
            return;
        };
        if !self.evolution_enabled {
            return;
        }
        self.reselect_armed_at = None;
        let reward = if reselect {
            evolution::REWARD_RESELECT
        } else if alt_rank {
            evolution::REWARD_ALT_RANK
        } else {
            evolution::REWARD_SELECT
        };
        if let Ok(mut mem) = self.evolution.lock() {
            mem.reward(&word, &features, reward, now);
        }
        self.last_selection = Some((word, features));
        self.last_selection_at = now;
        self.last_selection_deleted = false;
    }

    /// 取走最近一次选词的评估（E3：前端记入统计即清除）；无待取时为 None。
    pub fn take_selection_eval(&mut self) -> Option<SelectionEval> {
        self.last_eval.take()
    }

    /// 前端看到「无组合态的删除键」：多半在删刚上屏的词——强负信号，
    /// 并武装重选期待。窗口外或已罚过的忽略。
    pub fn note_delete(&mut self, now: u64) {
        if !self.evolution_enabled || self.last_selection_deleted {
            return;
        }
        let Some((word, features)) = self.last_selection.clone() else {
            return;
        };
        if now.saturating_sub(self.last_selection_at) > DELETE_WINDOW_SECS {
            return;
        }
        if let Ok(mut mem) = self.evolution.lock() {
            mem.reward(&word, &features, evolution::REWARD_DELETED, now);
        }
        self.last_selection_deleted = true;
        self.reselect_armed_at = Some(now);
    }

    /// 导出知你账本 TSV（词\t特征\t亲和度\t观察数\t最后触摸）。
    pub fn export_evolution(&self) -> String {
        match self.evolution.lock() {
            Ok(mem) => mem.export_tsv(),
            Err(_) => String::new(),
        }
    }

    /// 导入知你账本 TSV，返回成功行数。
    pub fn import_evolution(&mut self, tsv: &str) -> usize {
        match self.evolution.lock() {
            Ok(mut mem) => mem.import_tsv(tsv),
            Err(_) => 0,
        }
    }

    /// 清空知你账本（权限中心的「一键忘记」）。
    pub fn forget_evolution(&mut self) {
        if let Ok(mut mem) = self.evolution.lock() {
            mem.forget_all();
        }
        self.last_selection = None;
        self.pending_selection = None;
        self.reselect_armed_at = None;
    }

    /// 自动学习短语：把最近几段上屏与本次拼接，窗口内的每个后缀组合各记一次。
    ///
    /// 这就是「AI 辅助短语」——没有手动短语表，用户重复打出来的搭配自己沉淀下来。
    fn learn_phrase(&mut self, keys: &str, text: &str) {
        if !matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_)) {
            self.recent.clear();
            return;
        }
        let keys: String = keys
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        // 英文、符号、表情不进短语库：它们不是「打出来的词」。
        if keys.is_empty() || !text.chars().all(is_phrase_char) {
            self.recent.clear();
            return;
        }
        for start in (0..self.recent.len()).rev() {
            let mut k = String::new();
            let mut t = String::new();
            for (pk, pt) in &self.recent[start..] {
                k.push_str(pk);
                t.push_str(pt);
            }
            k.push_str(&keys);
            t.push_str(text);
            if k.chars().count() <= MAX_PHRASE_KEYS && t.chars().count() <= MAX_PHRASE_CHARS {
                self.user.record_phrase(&k, &t);
                if let Some(init) = liana_core::syllables::pinyin_initials(&k) {
                    self.user.record_phrase(&init, &t);
                }
            }
        }
        self.recent.push((keys, text.to_string()));
        if self.recent.len() > PHRASE_WINDOW {
            self.recent.remove(0);
        }
    }

    fn learn_context(&mut self, text: &str) {
        if let Some(prev) = self.last_committed.take() {
            self.user.record_pair(&prev, text);
        }
        self.last_committed = Some(text.to_string());
    }

    fn consume(&mut self, n: usize) {
        let mut chars = self.buffer.chars();
        for _ in 0..n {
            if chars.next().is_none() {
                break;
            }
        }
        self.buffer = chars.as_str().to_string();
        while self.buffer.starts_with('\'') {
            self.buffer.remove(0);
        }
        self.refresh();
    }

    fn refresh(&mut self) {
        self.origins.clear();
        if self.buffer.is_empty() && self.mode != Mode::Emoji {
            self.comp = Composition::default();
            return;
        }
        // `u` 前缀进符号模式：普通话没有以 u 开头的音节，不会和拼音抢输入。
        let symbol_hit =
            if self.mode == Mode::Pinyin && self.buffer.starts_with(liana_symbol::TRIGGER) {
                let c = self.symbol.decode_buffer(&self.buffer);
                (!c.is_empty()).then_some(c)
            } else {
                None
            };
        if let Some(cands) = symbol_hit {
            self.finish(cands, self.buffer.clone());
            return;
        }
        let (mut cands, preedit) = match self.mode {
            Mode::Pinyin | Mode::Shuangpin(_) => {
                let layout = match self.mode {
                    Mode::Shuangpin(s) => Layout::Shuangpin(s),
                    _ => Layout::Full,
                };
                let d = PinyinDecoder::new(self.dict.clone(), layout);
                // 个人词频与营养词进入整句解码（不只是事后重排）
                let user = &self.user;
                let nutrition = &self.nutrition;
                let boost = |w: &str| user.decode_bonus(w) + nutrition.bonus(w);
                (d.candidates_with(&self.buffer, &boost), d.preedit(&self.buffer))
            }
            Mode::English => (self.en.decode(&self.buffer), self.buffer.clone()),
            Mode::Japanese => {
                let preedit =
                    liana_ja::to_hiragana(&self.buffer).unwrap_or_else(|| self.buffer.clone());
                (self.ja.decode(&self.buffer), preedit)
            }
            Mode::Emoji => (self.emoji.decode(&self.buffer), self.buffer.clone()),
        };
        if self.mode != Mode::Emoji {
            for c in &mut cands {
                c.score += self.user.bonus(&c.text);
                c.score += self.nutrition.bonus(&c.text);
                if let Some(prev) = &self.last_committed {
                    c.score += self.user.pair_bonus(prev, &c.text);
                }
            }
            if matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_)) {
                self.push_phrase_candidates(&mut cands);
                self.push_nutrition_candidates(&mut cands);
                self.push_english_candidates(&mut cands);
                self.suppress_partial_corrections(&mut cands);
            }
        }
        self.finish(cands, preedit);
    }

    /// 候选收尾：分层排序 → 知你重排 → 截断 → 简繁转换 → 落到组合态。
    fn finish(&mut self, mut cands: Vec<liana_core::Candidate>, preedit: String) {
        // 分层排序：literal 垫底、覆盖输入多的优先，用户词只在同层内重排。
        cands.sort_by(liana_core::Candidate::rank_cmp);
        // E3 反事实基线：重排前的顺序（简体原文空间，与 select 的 learned 同空间）。
        self.base_order = if self.evolution_enabled && self.mode != Mode::Emoji && !cands.is_empty()
        {
            Some(cands.iter().map(|c| c.text.clone()).collect())
        } else {
            None
        };
        self.apply_evolution_rerank(&mut cands);
        cands.truncate(MAX_CANDIDATES);
        if self.traditional {
            self.origins.clear();
            self.origins.reserve(cands.len());
            for c in &mut cands {
                let converted = liana_zhconv::s2t(&c.text);
                if converted == c.text {
                    self.origins.push(c.text.clone());
                } else {
                    self.origins.push(std::mem::replace(&mut c.text, converted));
                }
            }
        }
        self.comp = Composition {
            raw: self.buffer.clone(),
            preedit,
            candidates: cands,
        };
    }

    /// 知你重排：把学习修正施加在「等价层」内——同 literal 归属且同 consumed 的
    /// 连续段。封顶 ±3 加上只在层内换位，保证覆盖分层与「原样上屏垫底」的
    /// 不变式永不被学习打破（ADR-0008：学习只能微调，不能掀桌）。
    fn apply_evolution_rerank(&mut self, cands: &mut [Candidate]) {
        if !self.evolution_enabled || self.mode == Mode::Emoji || cands.len() < 2 {
            return;
        }
        let features = self.evolution_features();
        let now = self.evolution_now;
        let Ok(mem) = self.evolution.lock() else {
            return;
        };
        let mut start = 0;
        while start < cands.len() {
            let mut end = start + 1;
            while end < cands.len() && same_tier(&cands[start], &cands[end]) {
                end += 1;
            }
            if end - start > 1 {
                let mut pool: Vec<Candidate> = cands[start..end].to_vec();
                let mut scored: Vec<(String, f32)> = pool
                    .iter()
                    .map(|c| (c.text.clone(), c.score as f32))
                    .collect();
                mem.adjust(&mut scored, &features, now);
                let mut reordered = Vec::with_capacity(pool.len());
                for (text, _) in scored {
                    if let Some(pos) = pool.iter().position(|c| c.text == text) {
                        reordered.push(pool.remove(pos));
                    }
                }
                // 兜底：adjust 不会增删条目，这里理论上是空的。
                reordered.extend(pool);
                cands[start..end].clone_from_slice(&reordered);
            }
            start = end;
        }
    }

    /// 短语补全：把学到的短语按当前按键前缀召回。
    ///
    /// 按键完全命中（学过 2 次）时按整句量级给分；只是前缀（学过 3 次）时给较低分，
    /// 让它出现在前几位但不抢正常整句的首位。
    fn push_phrase_candidates(&self, cands: &mut Vec<liana_core::Candidate>) {
        use liana_core::{Candidate, CandidateKind};
        let raw: String = self
            .buffer
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        let consumed = self.buffer.chars().count();
        if raw.chars().count() < MIN_PHRASE_QUERY {
            return;
        }
        for (keys, text, count) in self.user.phrase_matches(&raw, 5) {
            let exact = keys.len() == raw.len();
            let min = if exact {
                MIN_PHRASE_EXACT
            } else {
                MIN_PHRASE_PREFIX
            };
            if count < min {
                continue;
            }
            let score = if exact {
                PHRASE_SCORE_EXACT
            } else {
                PHRASE_SCORE_PREFIX
            } + (count as f64).ln();
            // 解码器已经给出同样的词时只提分，不塞重复候选
            if let Some(existing) = cands
                .iter_mut()
                .find(|c| c.text == text && c.consumed == consumed)
            {
                existing.score = existing.score.max(score);
                continue;
            }
            cands.push(
                Candidate::new(text, consumed, CandidateKind::Phrase, score).with_comment("短语"),
            );
        }
    }

    /// 营养词按键召回：喂过的词按派生拼音召回（教一次，处处可用）。
    ///
    /// 按键完全命中时给整句量级的分；只是前缀时给补全分。与短语候选同一套
    /// 去重规则：解码器已给出同样的词时只提分，不塞重复候选。
    fn push_nutrition_candidates(&self, cands: &mut Vec<liana_core::Candidate>) {
        use liana_core::{Candidate, CandidateKind};
        let raw: String = self
            .buffer
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        let consumed = self.buffer.chars().count();
        if raw.chars().count() < MIN_PHRASE_QUERY {
            return;
        }
        for (keys, term, strength) in self.nutrition.prefix_matches(&raw, 5) {
            let exact = keys.len() == raw.len();
            let score = if exact {
                feed::NUTRITION_SCORE_EXACT
            } else {
                feed::NUTRITION_SCORE_PREFIX
            } + (strength.max(1) as f64).ln();
            if let Some(existing) = cands
                .iter_mut()
                .find(|c| c.text == term && c.consumed == consumed)
            {
                existing.score = existing.score.max(score);
                continue;
            }
            cands.push(
                Candidate::new(term, consumed, CandidateKind::Phrase, score).with_comment("营养词"),
            );
        }
    }

    /// 中英混输：中文模式里掺入英文候选。
    ///
    /// 触发条件：输入无法完整解成中文（有残余）、本身是长度 ≥3 的英文词、
    /// 是词库逐段命中的代码标识符（getUser / get_user）、或用户按了 Shift
    /// （大写意图）。两字母短拼（he/an）不触发，避免拼音噪声。
    ///
    /// 锚定插入：有全覆盖中文在场时，最优英文候选（精确词/标识符）的分数
    /// 顶到中文最高分之下 0.5——排进候选窗首屏（紧随中文首选），不再沉底
    /// 十几位开外。选过一次后 user.bonus 按文本加分，同前缀下次更靠前。
    fn push_english_candidates(&self, cands: &mut Vec<liana_core::Candidate>) {
        use liana_core::CandidateKind;
        let raw = self.buffer.as_str();
        let has_real_zh = cands.iter().any(|c| c.kind != CandidateKind::Literal);
        let lower = raw.to_ascii_lowercase();
        let upper_intent = raw.chars().any(|c| c.is_ascii_uppercase());
        let identifier = self.en.decode_identifier(raw);
        let exact_word = lower.chars().count() >= MIN_EXACT_ENGLISH && self.en.contains(&lower);
        if has_real_zh && !exact_word && identifier.is_none() && !upper_intent {
            return;
        }
        let consumed = raw.chars().count();
        // 全覆盖中文候选的最高分（锚定插入的基准）
        let zh_top = cands
            .iter()
            .filter(|c| c.consumed == consumed && c.text.chars().any(is_phrase_char))
            .map(|c| c.score)
            .reduce(f64::max);
        let mut incoming: Vec<_> = self
            .en
            .decode_for_mix(raw)
            .into_iter()
            .take(MAX_MIXED_ENGLISH)
            .collect();
        // 标识符候选：词表里没有这种形态（getUser），单独立一条
        if let Some(text) = identifier {
            incoming.push(
                liana_core::Candidate::new(text, consumed, CandidateKind::Word, 9.0)
                    .with_comment("标识符"),
            );
        }
        for mut c in incoming {
            c.consumed = consumed;
            c.score = c.score.max(-100.0);
            if let Some(top) = zh_top {
                let is_best = c.text.to_lowercase() == lower
                    || c.comment.as_deref() == Some("标识符");
                if is_best && c.score < top {
                    if c.comment.is_none() {
                        c.comment = Some("英文".into());
                    }
                    c.score = top - 0.5;
                }
            }
            cands.push(c);
        }
    }

    /// 打得准就不出纠错：输入存在「全拼恰好覆盖的真实词候选」时（= 没打错），
    /// 丢掉部分覆盖的纠错候选——nihao 里的 里[li]/机[ji]、shuru 里的 是[shi]
    /// 这类噪声是候选注释的最大来源（用户反馈：只有常见错别字/特别发音才需要标注）。
    /// 整词纠错（gao→好、si→四，consumed == 输入全长）与补全（输入法 shu ru fa）
    /// 不受影响。kernel 层做不了这个判断（需要「真实词」信号），所以放在这里。
    fn suppress_partial_corrections(&self, cands: &mut Vec<liana_core::Candidate>) {
        use liana_core::CommentRole;
        let raw_len = self.buffer.chars().count();
        let well_typed = cands.iter().any(|c| {
            c.comment_role == CommentRole::ExactReading
                && c.consumed == raw_len
                && c.text.chars().any(is_phrase_char)
        });
        if well_typed {
            cands.retain(|c| {
                c.comment_role != CommentRole::CorrectedReading || c.consumed == raw_len
            });
        }
    }
}

    /// 能进短语库的字符：中日韩文字。英文、数字、符号、表情都排除在外。
fn is_phrase_char(c: char) -> bool {
    matches!(c, '\u{3400}'..='\u{9fff}' | '\u{f900}'..='\u{faff}')
}

/// 是否 CJK 表意文字（FFI 的 englishLike 判定与内核同源）。
pub fn is_cjk_char(c: char) -> bool {
    is_phrase_char(c)
}

/// 知你重排的等价层：literal 归属相同且覆盖的按键数相同。
/// 与 `Candidate::rank_cmp` 的层级键一致，层内换位永远不会跨层。
fn same_tier(a: &Candidate, b: &Candidate) -> bool {
    (a.kind == CandidateKind::Literal) == (b.kind == CandidateKind::Literal)
        && a.consumed == b.consumed
}

/// 给营养词派生按键串：逐字查词典里的最高频读音并拼接。
/// 含生僻字（词典无读音）时返回空串——该词不做按键召回，只享受加分。
fn derive_nutrition_keys(term: &str, dict: &Dictionary) -> String {
    let readings = dict.char_pinyin();
    let mut keys = String::new();
    for ch in term.trim().chars() {
        match readings.get(&ch) {
            Some(syl) => keys.push_str(syl),
            None => return String::new(),
        }
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(mode: Mode) -> Session {
        Session::with_mode(Arc::new(Dictionary::embedded()), mode)
    }

    fn type_str(s: &mut Session, text: &str) {
        for ch in text.chars() {
            s.feed(ch);
        }
    }

    #[test]
    fn pinyin_type_and_commit() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "nihao");
        assert_eq!(s.composition().raw, "nihao");
        assert_eq!(s.composition().preedit, "ni hao");
        assert_eq!(s.composition().candidates[0].text, "你好");
        assert_eq!(s.select(0).as_deref(), Some("你好"));
        assert!(s.buffer().is_empty());
        assert!(s.composition().is_empty());
    }

    #[test]
    fn promote_moves_within_tier_only() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "shi");
        let comp = s.composition().clone();
        let same = comp
            .candidates
            .iter()
            .position(|c| {
                c.consumed == comp.candidates[0].consumed
                    && c.text != comp.candidates[0].text
                    && c.kind != CandidateKind::Literal
            });
        let i = same.expect("shi 应有同层的其他候选");
        {
            let text = comp.candidates[i].text.clone();
            assert!(s.promote(i));
            assert_eq!(s.composition().candidates[0].text, text);
            assert_eq!(s.select(0).as_deref(), Some(text.as_str()));
        }
        assert!(!s.promote(0));
    }

    #[test]
    fn select_keeps_remaining_buffer() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "ni");
        let c = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "你")
            .expect("应有「你」");
        assert_eq!(s.select(c).as_deref(), Some("你"));
        assert!(s.buffer().is_empty());

        type_str(&mut s, "nihao");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "你" && c.consumed == 2)
            .expect("应有消费 2 字符的「你」");
        assert_eq!(s.select(idx).as_deref(), Some("你"));
        assert_eq!(s.buffer(), "hao");
        assert_eq!(s.composition().candidates[0].text, "好");
    }

    #[test]
    fn backspace_and_clear() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "ni");
        assert!(s.backspace());
        assert_eq!(s.buffer(), "n");
        assert!(s.backspace());
        assert!(!s.backspace());
        type_str(&mut s, "hao");
        s.clear();
        assert!(s.composition().is_empty());
    }

    #[test]
    fn ignores_non_letter_keys() {
        let mut s = session(Mode::Pinyin);
        assert!(!s.feed(' '));
        assert!(!s.feed('1'));
        assert!(s.feed('n'));
        assert!(s.feed('\''));
        assert!(s.feed(';'));
    }

    #[test]
    fn commit_raw_returns_typed_text() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "zzz");
        assert_eq!(s.commit_raw().as_deref(), Some("zzz"));
        assert!(s.commit_raw().is_none());
    }

    #[test]
    fn external_commit_feeds_voice_then_typing_context() {
        let mut s = session(Mode::Pinyin);
        // 语音上屏「北京」→ 记词
        s.commit_external("北京");
        assert_eq!(s.user_model().count("北京"), 1);

        // 接着打「世界」→ 二元组 北京→世界 被记录（语音喂给打字）
        type_str(&mut s, "shijie");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "世界")
            .expect("应有「世界」");
        s.select(idx);

        // 反向：先打字后语音，同样形成二元组
        s.commit_external("啊");
        assert!(s.user_model().pair_count("世界", "啊") > 0, "先打字后语音也要形成二元组");
    }

    #[test]
    fn external_commit_ignores_blank() {
        let mut s = session(Mode::Pinyin);
        s.commit_external("");
        s.commit_external(" \n\t");
        assert!(s.user_model().is_empty(), "空白文本不该进用户词库");
        assert_eq!(s.last_committed(), None, "空白文本不该改上下文");
    }

    #[test]
    fn shuangpin_modes_work() {
        let mut s = session(Mode::Shuangpin(liana_core::Scheme::Flypy));
        type_str(&mut s, "nihc");
        assert_eq!(s.composition().candidates[0].text, "你好");
        assert_eq!(s.composition().preedit, "ni hao");

        s.set_mode(Mode::Shuangpin(liana_core::Scheme::Mspy));
        type_str(&mut s, "hk");
        assert!(s.composition().candidates.iter().any(|c| c.text == "好"));
    }

    #[test]
    fn candidates_keep_coverage_tiers() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "nihao");
        let c = &s.composition().candidates;
        let zh: Vec<_> = c
            .iter()
            .filter(|x| x.kind != liana_core::CandidateKind::Literal)
            .collect();
        let first_partial = zh.iter().position(|x| x.consumed < 5).unwrap_or(zh.len());
        assert!(first_partial > 0, "应有覆盖全部输入的候选");
        assert!(
            zh[..first_partial].iter().all(|x| x.consumed == 5),
            "覆盖全部的候选必须排在最前: {:?}",
            zh.iter().map(|x| (&x.text, x.consumed)).collect::<Vec<_>>()
        );
        assert!(
            zh[first_partial..].iter().all(|x| x.consumed < 5),
            "部分覆盖的候选不能插队: {:?}",
            zh.iter().map(|x| (&x.text, x.consumed)).collect::<Vec<_>>()
        );
        assert_eq!(
            c.last().map(|x| x.kind),
            Some(liana_core::CandidateKind::Literal),
            "原样上屏永远垫底"
        );
    }

    #[test]
    fn bigram_context_boosts_next_word() {
        let mut s = session(Mode::Pinyin);

        // 训练「北京 → 世界」：两次上屏形成二元组
        for _ in 0..3 {
            type_str(&mut s, "beijing");
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == "北京")
                .expect("应有「北京」");
            s.select(idx);
            type_str(&mut s, "shijie");
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == "世界")
                .expect("应有「世界」");
            s.select(idx);
        }
        assert!(s.user_model().pair_count("北京", "世界") > 0);

        // 上下文是「北京」时，世界应得到加分
        type_str(&mut s, "beijing");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "北京")
            .expect("应有「北京」");
        s.select(idx);
        assert_eq!(s.last_committed(), Some("北京"));
        type_str(&mut s, "shijie");
        let with_ctx = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "世界")
            .expect("应有「世界」")
            .score;

        // 上下文换成别的词后，同一候选分数应更低
        s.reset_context();
        s.clear();
        type_str(&mut s, "nihao");
        s.select(0);
        type_str(&mut s, "shijie");
        let without_ctx = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "世界")
            .expect("应有「世界」")
            .score;
        assert!(
            with_ctx > without_ctx,
            "有上下文 {with_ctx} 应高于无上下文 {without_ctx}"
        );
    }

    #[test]
    fn mixed_input_completes_english_word() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "hello");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "hello", "{c:?}");
        assert_eq!(c[0].consumed, 5);
        assert_eq!(s.select(0).as_deref(), Some("hello"));
    }

    #[test]
    fn mixed_input_keeps_case_intent() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "Hello");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "Hello", "{c:?}");
    }

    #[test]
    fn mixed_input_does_not_noise_short_pinyin() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "he");
        let c = &s.composition().candidates;
        assert_ne!(c[0].text, "he", "短拼音不应被英文词抢占: {c:?}");
        assert_eq!(s.composition().preedit, "he");
    }

    #[test]
    fn mixed_input_exact_long_word_beats_partial_chinese() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "test");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "test", "{c:?}");
    }

    #[test]
    fn mixed_input_pinyin_solvable_english_near_top() {
        // date：da'te 拼音可解，但 date 也是词库英文词——应进候选窗首屏
        // （旧实现沉底十几位开外，用户看不见，只能切模式）
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "date");
        let c = &s.composition().candidates;
        let pos = c.iter().position(|x| x.text.to_lowercase() == "date");
        assert!(pos.is_some_and(|p| p <= 3), "date 应在首屏（≤第 4 位）: {c:?}");
    }

    #[test]
    fn mixed_input_three_letter_word_mixes() {
        // get：3 字母英文词也要触发（此前 ≥4 才行，get/run/map 全被挡）
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "get");
        let c = &s.composition().candidates;
        assert!(
            c.iter().take(4).any(|x| x.text.to_lowercase() == "get"),
            "get 应进首屏: {c:?}"
        );
    }

    #[test]
    fn identifier_snake_case_candidate() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "get_user");
        let c = &s.composition().candidates;
        assert!(
            c.iter().take(4).any(|x| x.text == "get_user"),
            "get_user 应以标识符候选出现在首屏: {c:?}"
        );
    }

    #[test]
    fn identifier_camel_case_candidate() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "getUser");
        let c = &s.composition().candidates;
        assert!(
            c.iter().take(4).any(|x| x.text == "getUser"),
            "getUser 应以标识符候选出现在首屏: {c:?}"
        );
    }

    #[test]
    fn underscore_feeds_into_buffer_anytime() {
        let mut s = session(Mode::Pinyin);
        assert!(s.feed('_'), "下划线是标识符意图，应随时入缓冲");
        type_str(&mut s, "get");
        assert_eq!(s.buffer(), "_get");
    }

    #[test]
    fn emoji_mode_featured_and_filter() {
        let mut s = session(Mode::Emoji);
        let c = &s.composition().candidates;
        assert!(!c.is_empty());
        assert_eq!(c[0].text, "😀");

        type_str(&mut s, "daku");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "😭", "{c:?}");
        assert_eq!(s.select(0).as_deref(), Some("😭"));
        assert!(s.buffer().is_empty());
        assert_eq!(s.user_model().count("😭"), 0, "表情不进用户词库");
    }

    #[test]
    fn english_mode_keeps_case() {
        let mut s = session(Mode::English);
        type_str(&mut s, "Hel");
        assert_eq!(s.composition().candidates[0].text, "Help");
    }

    #[test]
    fn japanese_mode_previews_kana() {
        let mut s = session(Mode::Japanese);
        type_str(&mut s, "nihon");
        assert_eq!(s.composition().preedit, "にほん");
        assert_eq!(s.composition().candidates[0].text, "にほん");
    }

    #[test]
    fn user_model_reranks_after_repeated_selection() {
        let mut s = session(Mode::Pinyin);
        s.clear();
        type_str(&mut s, "shi");
        assert_ne!(s.composition().candidates[0].text, "时", "初始不应是「时」");
        for _ in 0..12 {
            s.clear();
            type_str(&mut s, "shi");
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == "时")
                .expect("应有「时」");
            s.select(idx);
        }
        s.clear();
        type_str(&mut s, "shi");
        assert_eq!(
            s.composition().candidates[0].text,
            "时",
            "重复选择后应被重排到首位（当前首位: {}）",
            s.composition().candidates[0].text
        );
    }

    #[test]
    fn traditional_converts_candidates_but_learns_simplified() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "xuexi");
        let simplified = s.composition().candidates[0].text.clone();
        assert_eq!(simplified, "学习");
        s.clear();

        s.set_traditional(true);
        assert!(s.traditional());
        type_str(&mut s, "xuexi");
        assert_eq!(s.composition().candidates[0].text, "學習");
        assert_eq!(s.select(0).as_deref(), Some("學習"));
        assert_eq!(s.user_model().count("学习"), 1, "学习应记在简体词条上");
        assert_eq!(s.user_model().count("學習"), 0);

        // 关掉开关后回到简体，之前的学习仍然生效
        s.set_traditional(false);
        type_str(&mut s, "xuexi");
        assert_eq!(s.composition().candidates[0].text, "学习");
    }

    #[test]
    fn traditional_keeps_english_and_emoji_untouched() {
        let mut s = session(Mode::Pinyin);
        s.set_traditional(true);
        type_str(&mut s, "hello");
        assert_eq!(s.composition().candidates[0].text, "hello");

        s.set_mode(Mode::Emoji);
        type_str(&mut s, "daku");
        assert_eq!(s.composition().candidates[0].text, "😭");
    }

    #[test]
    fn symbol_mode_triggers_on_u_prefix() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "u");
        let c = &s.composition().candidates;
        assert!(!c.is_empty());
        assert!(
            c.iter()
                .all(|x| x.kind == liana_core::CandidateKind::Symbol),
            "{c:?}"
        );

        s.clear();
        type_str(&mut s, "uduihao");
        assert_eq!(s.composition().candidates[0].text, "✓");
        assert_eq!(s.select(0).as_deref(), Some("✓"));
        assert!(s.buffer().is_empty(), "符号上屏后应吃掉整个缓冲");
    }

    #[test]
    fn symbol_prefix_falls_back_to_pinyin_when_no_match() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "uzzzz");
        let c = &s.composition().candidates;
        assert!(
            c.iter()
                .all(|x| x.kind != liana_core::CandidateKind::Symbol),
            "无命中应退回普通管线: {c:?}"
        );
        assert!(!c.is_empty());
    }

    #[test]
    fn symbol_prefix_does_not_break_normal_pinyin() {
        let mut s = session(Mode::Pinyin);
        // wu / nu 等以 u 结尾或含 u 的音节不受影响
        type_str(&mut s, "wu");
        assert!(
            s.composition()
                .candidates
                .iter()
                .any(|c| c.kind == liana_core::CandidateKind::Char
                    || c.kind == liana_core::CandidateKind::Word),
            "{:?}",
            s.composition().candidates
        );
    }

    #[test]
    fn phrase_is_learned_from_consecutive_commits() {
        let mut s = session(Mode::Pinyin);
        let sequence = [("beijing", "北京"), ("shijie", "世界")];
        for _ in 0..2 {
            s.reset_context();
            for (keys, text) in sequence {
                type_str(&mut s, keys);
                let idx = s
                    .composition()
                    .candidates
                    .iter()
                    .position(|c| c.text == text)
                    .unwrap_or_else(|| panic!("应有「{text}」"));
                s.select(idx);
            }
        }
        assert_eq!(
            s.user_model().phrase_count("beijingshijie", "北京世界"),
            2,
            "连续上屏应沉淀成短语"
        );

        // 窗口是最近 3 段：第三段进来后，两段与三段组合都要记上
        s.reset_context();
        for (keys, text) in [("nihao", "你好"), ("beijing", "北京"), ("shijie", "世界")] {
            type_str(&mut s, keys);
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == text)
                .unwrap_or_else(|| panic!("应有「{text}」"));
            s.select(idx);
        }
        assert_eq!(s.user_model().phrase_count("nihaobeijing", "你好北京"), 1);
        assert_eq!(
            s.user_model().phrase_count("nhbj", "你好北京"),
            1,
            "全拼短语应同时记下简拼，方便下次少打几个字母"
        );
        assert_eq!(
            s.user_model()
                .phrase_count("nihaobeijingshijie", "你好北京世界"),
            0,
            "超过字数/按键上限的组合不学"
        );
    }

    #[test]
    fn learned_phrase_completes_on_prefix() {
        let mut s = session(Mode::Pinyin);
        // 手工灌入一个学过 4 次的短语，避免依赖具体词库候选
        for _ in 0..4 {
            s.user_model_mut().record_phrase("zaoshanghao", "早上好");
        }
        type_str(&mut s, "zaosh");
        let c = &s.composition().candidates;
        let hit = c
            .iter()
            .find(|x| x.text == "早上好")
            .expect("前缀应补全出短语");
        assert_eq!(hit.kind, liana_core::CandidateKind::Phrase);
        assert_eq!(hit.comment.as_deref(), Some("短语"));
        assert_eq!(
            hit.comment_role,
            liana_core::CommentRole::Label,
            "标签注释不受「仅纠错时显示拼音」影响"
        );
        assert_eq!(hit.consumed, 5, "短语候选吃掉当前全部按键");
    }

    #[test]
    fn rare_phrase_does_not_surface() {
        let mut s = session(Mode::Pinyin);
        s.user_model_mut().record_phrase("zaoshanghao", "早上好");
        type_str(&mut s, "zaosh");
        assert!(
            !s.composition()
                .candidates
                .iter()
                .any(|x| x.kind == liana_core::CandidateKind::Phrase),
            "只学过一次不应冒出来: {:?}",
            s.composition().candidates
        );
    }

    #[test]
    fn english_and_symbol_commits_do_not_pollute_phrases() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "hello");
        s.select(0);
        type_str(&mut s, "uduihao");
        s.select(0);
        type_str(&mut s, "nihao");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "你好")
            .expect("应有「你好」");
        s.select(idx);
        assert_eq!(s.user_model().phrase_len(), 0, "非中文上屏不该进短语库");
    }

    #[test]
    fn backup_roundtrip_and_rejects_damaged_package() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "nihao");
        s.select(0);
        s.user_model_mut().record_phrase("nihaoshijie", "你好世界");
        let pack = s.export_backup();
        assert!(pack.contains("#kind: userdata"), "{pack}");

        let mut fresh = session(Mode::Pinyin);
        let n = fresh.import_backup(&pack, false).expect("应能导入");
        assert!(n >= 2, "导入条目数: {n}");
        assert_eq!(fresh.user_model().count("你好"), 1);
        assert_eq!(
            fresh.user_model().phrase_count("nihaoshijie", "你好世界"),
            1
        );

        // 重复合并不翻倍
        fresh.import_backup(&pack, true).unwrap();
        assert_eq!(fresh.user_model().count("你好"), 1);

        // 损坏的包一律拒绝，且不动现有数据
        let broken = pack.replace("你好\t1", "你好\t999");
        assert!(fresh.import_backup(&broken, false).is_err());
        assert!(fresh.import_backup("随便一段文本", false).is_err());
        assert_eq!(fresh.user_model().count("你好"), 1);
    }

    #[test]
    fn switching_mode_clears_buffer() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "ni");
        s.set_mode(Mode::English);
        assert!(s.buffer().is_empty());
        assert_eq!(s.mode(), Mode::English);
    }

    // ──────────── 知你教学层接线（E1） ────────────

    /// 同层内重排：奖励把「先」顶到「现」前面；不同 consumed 的层纹丝不动。
    #[test]
    fn evolution_rerank_moves_learned_word_within_tier() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("com.apple.Notes"), 10, true, 1_000);
        let mut cands = vec![
            Candidate::new("现", 4, CandidateKind::Word, 10.0),
            Candidate::new("先", 4, CandidateKind::Word, 9.0),
            Candidate::new("县", 2, CandidateKind::Char, 8.0),
            Candidate::new("xian", 4, CandidateKind::Literal, -1000.0),
        ];
        // 同一上下文里两次选「先」：奖励写进每个特征，跨特征求和越过 1.0 分差
        let feats = s.evolution_features();
        for t in [1_000u64, 1_100] {
            s.evolution
                .lock()
                .unwrap()
                .reward("先", &feats, evolution::REWARD_SELECT, t);
        }
        s.apply_evolution_rerank(&mut cands);
        assert_eq!(cands[0].text, "先", "{cands:?}");
        assert_eq!(cands[1].text, "现");
        // 部分覆盖层与 literal 层顺序不动
        assert_eq!(cands[2].text, "县");
        assert_eq!(cands[3].text, "xian");
    }

    /// 选词 → 删除的完整序列：上屏 +1 记账、删除 −2 翻负、重选 +1.5。
    #[test]
    fn select_delete_reselect_sequence_is_rewarded() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("com.apple.Notes"), 10, true, 1_000);
        type_str(&mut s, "shi");
        let top = s.composition().candidates[0].text.clone();
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == top)
            .unwrap();
        s.select(idx);
        s.note_selection(false, 1_005);

        // 选后立刻删除（窗口内）：强负
        s.note_delete(1_008);
        let tsv = s.export_evolution();
        let neg: Vec<_> = tsv
            .lines()
            .filter(|l| {
                l.starts_with(&(top.clone() + "\t"))
                    && l.split('\t').nth(2).unwrap().parse::<f32>().unwrap() < 0.0
            })
            .collect();
        assert!(!neg.is_empty(), "删除应给 {top} 留下负亲和度: {tsv}");

        // 删除后换个词重选：强正 1.5（v = 0.35 * 1.5 = 0.525）
        type_str(&mut s, "shi");
        let alt_idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text != top)
            .unwrap();
        let alt = s.composition().candidates[alt_idx].text.clone();
        s.select(alt_idx);
        s.note_selection(false, 1_020);
        let tsv = s.export_evolution();
        let reselected = tsv
            .lines()
            .filter(|l| l.starts_with(&alt))
            .any(|l| l.split('\t').nth(2).unwrap().parse::<f32>().unwrap() > 0.5);
        assert!(reselected, "重选应记 1.5 强正（0.5250）: {tsv}");
    }

    /// 删除窗口外：删除键只是普通编辑，不产生负奖励、也不武装重选。
    #[test]
    fn delete_outside_window_is_ignored() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("com.apple.Notes"), 10, true, 1_000);
        type_str(&mut s, "shi");
        s.select(0);
        s.note_selection(false, 1_000);
        s.note_delete(1_000 + DELETE_WINDOW_SECS + 1);
        let tsv = s.export_evolution();
        assert!(
            !tsv.lines().any(|l| l
                .split('\t')
                .nth(2)
                .and_then(|v| v.parse::<f32>().ok())
                .is_some_and(|v| v < 0.0)),
            "窗口外的删除不该有负奖励: {tsv}"
        );
        // 重选期待未武装：下一次选词按普通 +1 记账（0.3500 而非 0.5250）
        type_str(&mut s, "shi");
        s.select(0);
        s.note_selection(false, 2_000);
        let tsv = s.export_evolution();
        assert!(
            !tsv.lines().any(|l| l.contains("\t0.5250\t")),
            "重选期待应在窗口外过期: {tsv}"
        );
    }

    /// 关闭知你：不重排、不记账。
    #[test]
    fn disabled_evolution_is_identity() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("com.apple.Notes"), 10, false, 1_000);
        let mut cands = vec![
            Candidate::new("现", 4, CandidateKind::Word, 10.0),
            Candidate::new("先", 4, CandidateKind::Word, 9.0),
        ];
        let feats = s.evolution_features();
        s.evolution
            .lock()
            .unwrap()
            .reward("先", &feats, evolution::REWARD_SELECT, 1_000);
        s.evolution
            .lock()
            .unwrap()
            .reward("先", &feats, evolution::REWARD_SELECT, 1_100);
        s.apply_evolution_rerank(&mut cands);
        assert_eq!(cands[0].text, "现", "关闭时不得重排");

        type_str(&mut s, "shi");
        let before = s.export_evolution();
        s.select(0);
        s.note_selection(false, 1_200);
        s.note_delete(1_300);
        assert_eq!(s.export_evolution(), before, "关闭时不得记账（直接注入的底账保持原样）");
    }

    /// 覆盖分层不变式：对部分覆盖候选狂加奖励也不能让它越级。
    #[test]
    fn coverage_tiers_survive_heavy_rewards() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("com.apple.Terminal"), 22, true, 1_000);
        type_str(&mut s, "nihao");
        let partial = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.consumed < 5 && c.kind != CandidateKind::Literal)
            .expect("应有部分覆盖候选");
        for i in 0..6u64 {
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.consumed < 5 && c.kind != CandidateKind::Literal)
                .unwrap_or(partial);
            s.select(idx);
            s.note_selection(true, 1_000 + i * 10);
            // 重新打出同样的输入（select 会消费缓冲）
            s.clear();
            type_str(&mut s, "nihao");
        }
        let c = &s.composition().candidates;
        let zh: Vec<_> = c
            .iter()
            .filter(|x| x.kind != CandidateKind::Literal)
            .collect();
        let first_partial = zh.iter().position(|x| x.consumed < 5).unwrap_or(zh.len());
        assert!(first_partial > 0);
        assert!(
            zh[..first_partial].iter().all(|x| x.consumed == 5),
            "全覆盖候选必须仍在最前: {:?}",
            zh.iter().map(|x| (x.text.clone(), x.consumed)).collect::<Vec<_>>()
        );
        assert_eq!(c.last().map(|x| x.kind), Some(CandidateKind::Literal));
    }

    // ──────────── 知你喂食层接线（E2） ────────────

    /// 营养词加分：喂过的词在候选里分数变高；忘记后回落。
    #[test]
    fn nutrition_bonus_lifts_candidate() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "beijing");
        let baseline = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "北京")
            .expect("应有「北京」")
            .score;

        assert!(s.nutrition_add("北京", "会议纪要.txt", 3, 1_000));
        s.clear();
        type_str(&mut s, "beijing");
        let fed = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "北京")
            .expect("应有「北京」")
            .score;
        assert!(fed > baseline, "营养词应获得词典级加分: {baseline} → {fed}");

        s.nutrition_forget("北京");
        s.clear();
        type_str(&mut s, "beijing");
        let forgotten = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "北京")
            .unwrap()
            .score;
        assert_eq!(forgotten, baseline, "忘记后加分应完全消失");
    }

    /// 按键串派生：词典有的字拼出音节串；含缺字的词派生为空（只加分不召回）。
    #[test]
    fn nutrition_keys_derive_from_dict() {
        let mut s = session(Mode::Pinyin);
        assert!(s.nutrition_add("北京高", "测试文档", 2, 1_000));
        let entry = s.nutrition().get("北京高").expect("应已入库");
        assert_eq!(entry.keys, "beijinggao", "{entry:?}");

        // 「界」不在内置小词典里：含它的词派生失败，但词本身仍入库享受加分
        assert!(s.nutrition_add("世界级", "测试文档", 2, 1_100));
        let entry = s.nutrition().get("世界级").expect("应已入库");
        assert_eq!(entry.keys, "", "缺字词不做按键召回: {entry:?}");
        assert!(s.nutrition().bonus("世界级") > 0.0);
    }

    /// 喂过的词按派生拼音整键召回（解码器已能给出同一词时只提分、不重复出候选）。
    #[test]
    fn nutrition_phrase_recall_on_exact_keys() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "beijinggao");
        let baseline = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "北京高" && c.consumed == 10)
            .expect("单字组合应给出「北京高」")
            .score;
        s.clear();

        assert!(s.nutrition_add("北京高", "会议纪要", 2, 1_000));
        type_str(&mut s, "beijinggao");
        let hit = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "北京高" && c.consumed == 10)
            .expect("整键输入应召回营养词");
        let expected_lift = feed::NUTRIENT_BONUS + 2.0f64.ln();
        assert!(
            hit.score >= baseline + expected_lift - 1e-9,
            "营养词应吃到词典级加分: {baseline} → {}",
            hit.score
        );
    }

    /// 营养库 TSV 走 Session 导入导出闭环；清空即全忘。
    #[test]
    fn nutrition_tsv_roundtrip_via_session() {
        let mut s = session(Mode::Pinyin);
        assert!(s.nutrition_add("北京高", "会议纪要", 2, 1_000));
        let tsv = s.nutrition_export();
        assert!(tsv.contains("北京高\t"), "{tsv}");

        let mut fresh = session(Mode::Pinyin);
        assert_eq!(fresh.nutrition_import(&tsv), 1);
        assert!(fresh.nutrition().bonus("北京高") > 0.0);
        assert_eq!(fresh.nutrition().get("北京高").unwrap().keys, "beijinggao");

        fresh.nutrition_forget_all();
        assert!(fresh.nutrition().is_empty());
    }

    // ──────────── 英文串续接（网址/邮箱/版本号直打） ────────────

    /// 纯字母串解码不出中文 → . : / @ 数字全部续进组合，原样上屏。
    #[test]
    fn english_string_continues_with_url_chars() {
        let mut s = session(Mode::Pinyin);
        for ch in "example.ai/corp?v=1.2".chars() {
            assert!(s.feed(ch), "{ch}");
        }
        assert_eq!(s.buffer(), "example.ai/corp?v=1.2");
        // 组合里全是字面候选，没有任何全覆盖汉字
        assert_eq!(s.commit_raw().as_deref(), Some("example.ai/corp?v=1.2"));
    }

    /// 邮箱：字母 + @ + 域名一路续接；中文组合则拒绝符号（走前端首选+标点）。
    #[test]
    fn email_continues_but_chinese_composition_rejects() {
        let mut s = session(Mode::Pinyin);
        for ch in "someone@example.com".chars() {
            assert!(s.feed(ch), "{ch}");
        }
        assert_eq!(s.commit_raw().as_deref(), Some("someone@example.com"));

        let mut t = session(Mode::Pinyin);
        type_str(&mut t, "nihao");
        assert!(
            !t.feed('.'),
            "中文组合（有全覆盖汉字候选）必须拒绝符号，交给前端首选+标点"
        );
    }

    /// 部分覆盖的零星单字不算中文读法：`lov`→咯(consumed 2) 不阻断续接。
    #[test]
    fn partial_cjk_candidates_do_not_block_continuation() {
        let mut s = session(Mode::Pinyin);
        for ch in "lov".chars() {
            s.feed(ch);
        }
        assert!(s.feed('.'), "lov 只剩字面候选，应视为英文串");
        assert_eq!(s.buffer(), "lov.");
    }

    /// `www` 会命中整词短拼候选（万维网），但仍应能续接 `.` 打成网址。
    #[test]
    fn www_prefix_continues_as_url() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "www");
        assert!(s.feed('.'), "www 后应可续接 .（网址意图）");
        assert_eq!(s.buffer(), "www.");
        for ch in "nownexts.com".chars() {
            assert!(s.feed(ch), "{ch}");
        }
        assert_eq!(s.buffer(), "www.nownexts.com");
        assert_eq!(s.commit_raw().as_deref(), Some("www.nownexts.com"));
    }

    /// 无重排语境：选中首选 → 实际/反事实都命中；选非首选 → 都不命中。
    #[test]
    fn selection_eval_without_rerank_is_consistent() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("eval.test"), 10, true, 1_000);
        type_str(&mut s, "nihao");
        let top = s.composition().candidates[0].text.clone();
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == top)
            .unwrap();
        s.select(idx);
        s.note_selection(false, 1_010);
        let eval = s.take_selection_eval().expect("应产出评估");
        assert!(eval.actual_top1);
        assert!(eval.base_top1, "无学习影响时基线 = 实际");
        assert!(!eval.reselect && !eval.alt_rank);
        assert!(s.take_selection_eval().is_none(), "取走即清");

        // 数字键选非首选：alt_rank=true，首选双双不命中
        type_str(&mut s, "nihao");
        let alt_idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text != top && c.kind != CandidateKind::Literal)
            .expect("应有非首选候选");
        s.select(alt_idx);
        s.note_selection(true, 1_020);
        let eval = s.take_selection_eval().unwrap();
        assert!(!eval.actual_top1);
        assert!(!eval.base_top1);
        assert!(eval.alt_rank);
    }

    /// 核心场景：学习把 A 顶到首选（基线首选是别的词）→ 反事实不命中，
    /// 收益 = 基线纠错率 − 实际纠错率 > 0。
    #[test]
    fn selection_eval_detects_learning_gain() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("eval.test"), 10, true, 1_000);
        // 建立词法窗：上屏「你好」，让后续选词的重排特征里有 lex 项
        type_str(&mut s, "nihao");
        s.select(0);
        s.note_selection(false, 1_010);
        assert!(s.take_selection_eval().unwrap().base_top1);

        // 基线首选（账本还只有 1 次观察，不参与重排）
        type_str(&mut s, "shi");
        let base_top = s.composition().candidates[0].text.clone();
        let consumed = s.composition().candidates[0].consumed;
        // 找同层（同 consumed）里离首选最近的其他候选，把账本灌满让它翻上去
        let challenger = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.consumed == consumed && c.text != base_top)
            .map(|c| c.text.clone())
            .expect("同层应有其他候选");
        let feats = s.evolution_features();
        {
            let mut mem = s.evolution.lock().unwrap();
            for i in 0..6u64 {
                mem.reward(&challenger, &feats, evolution::REWARD_SELECT, 1_020 + i);
            }
        }
        s.clear();
        type_str(&mut s, "shi");
        assert_eq!(
            s.composition().candidates[0].text,
            challenger,
            "灌满账本后 challenger 应被重排到首选（基线首选是 {base_top}）"
        );
        s.select(0);
        s.note_selection(false, 1_100);
        let eval = s.take_selection_eval().unwrap();
        assert!(eval.actual_top1, "用户选的就是重排后的首选");
        assert!(!eval.base_top1, "基线排序里它不是首选——这就是学习收益");
        assert!(!eval.reselect);
    }

    /// 学习关闭：基线 = 实际，评估照常产出（收益读作 0）。
    #[test]
    fn selection_eval_when_disabled_equals_baseline() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("eval.test"), 10, false, 1_000);
        type_str(&mut s, "nihao");
        s.select(0);
        s.note_selection(false, 1_010);
        let eval = s.take_selection_eval().unwrap();
        assert_eq!(eval.actual_top1, eval.base_top1);
    }

    /// 原样上屏与清空会作废挂起的评估。
    #[test]
    fn selection_eval_invalidated_by_raw_commit_and_clear() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("eval.test"), 10, true, 1_000);
        type_str(&mut s, "nihao");
        s.select(0); // 挂起评估
        s.commit_raw().is_none();
        assert!(s.take_selection_eval().is_none(), "commit_raw 不产出评估");

        type_str(&mut s, "nihao");
        s.select(0);
        s.clear();
        assert!(s.take_selection_eval().is_none(), "clear 应作废挂起评估");
    }

    /// 账本 TSV 走 Session 导出/导入闭环。
    #[test]
    fn evolution_tsv_roundtrip_via_session() {
        let mut s = session(Mode::Pinyin);
        s.set_evolution_context(Some("com.apple.Notes"), 10, true, 1_000);
        let mut cands = vec![
            Candidate::new("现", 4, CandidateKind::Word, 10.0),
            Candidate::new("先", 4, CandidateKind::Word, 9.0),
        ];
        let feats = s.evolution_features();
        for t in [1_000u64, 1_100] {
            s.evolution
                .lock()
                .unwrap()
                .reward("先", &feats, evolution::REWARD_SELECT, t);
        }
        let tsv = s.export_evolution();
        assert!(tsv.contains("先\t"));

        let mut fresh = session(Mode::Pinyin);
        fresh.set_evolution_context(Some("com.apple.Notes"), 10, true, 1_200);
        assert!(fresh.import_evolution(&tsv) >= 2, "每个特征一行");
        fresh.apply_evolution_rerank(&mut cands);
        assert_eq!(cands[0].text, "先");

        fresh.forget_evolution();
        assert!(fresh.export_evolution().is_empty());
    }

/// 「打得准就不出纠错」端到端守卫：完整全拼解码出真实词后，
    /// 部分覆盖的纠错候选整体消失（候选注释噪声的最大来源）。
    #[test]
    #[test]
    fn well_typed_input_drops_partial_corrections() {
        let mut s = session(Mode::Pinyin);
        for input in ["nihao", "shuru", "diannao", "xihuan"] {
            s.clear();
            type_str(&mut s, input);
            let raw_len = input.chars().count();
            let cands = &s.composition().candidates;
            let well_typed = cands.iter().any(|c| {
                c.comment_role == liana_core::CommentRole::ExactReading
                    && c.consumed == raw_len
                    && c.text.chars().any(is_phrase_char)
            });
            assert!(well_typed, "{input} 应是打得准的输入: {cands:?}");
            let noise: Vec<_> = cands
                .iter()
                .filter(|c| {
                    c.comment_role == liana_core::CommentRole::CorrectedReading
                        && c.consumed < raw_len
                })
                .collect();
            assert!(noise.is_empty(), "{input} 不应再有部分覆盖纠错候选: {noise:?}");
        }
    }

    /// 整词纠错（gao→好）与补全（输入法 shu ru fa）不受抑制影响。
    #[test]
    #[test]
    fn whole_word_corrections_survive() {
        let mut s = session(Mode::Pinyin);
        // 整词纠错：gao 打成想要 hao——候选全长、词典词，保留
        s.clear();
        type_str(&mut s, "gao");
        let cands = &s.composition().candidates;
        assert!(
            cands.iter().take(4).any(|c| c.text == "好"),
            "gao 的整词纠错「好」应保留在首屏: {cands:?}"
        );
        // 补全：shur → 输入法（全长 consumed，词典词），保留
        s.clear();
        type_str(&mut s, "shur");
        let cands = &s.composition().candidates;
        assert!(
            cands.iter().any(|c| c.text == "输入法"),
            "补全候选「输入法」应保留: {cands:?}"
        );
    }
}

