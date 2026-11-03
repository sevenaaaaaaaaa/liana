//! 用户词学习模型。M0 仅内存；M1 起由前端加密落盘（密钥在系统钥匙串）。
//!
//! 这是「L0 内置统计模型」：词频 + 二元组（上一个上屏词 → 当前候选）重排，
//! 零下载、零额外内存开销（上限受 `MAX_PAIRS` 约束，超出后衰减）。

use std::collections::HashMap;

/// 二元组条数上限；超出后丢弃只出现过一次的组合并把计数减半。
const MAX_PAIRS: usize = 20_000;
/// 自动学习的短语条数上限，同样用「丢一次性条目 + 计数减半」控制规模。
const MAX_PHRASES: usize = 5_000;
/// 网址/邮箱习惯条数上限（用户原样上屏过的 ASCII 令牌的字母段）。
const MAX_DOT_HABITS: usize = 2_000;
/// 钉选候选上限（微信式「固定首位」；最近的排最前）。
const MAX_PINS: usize = 100;
/// 屏蔽候选上限（「不再显示」；只对多字词生效，防误伤单字结构）。
const MAX_BANS: usize = 1_000;

#[derive(Default, Debug, Clone)]
pub struct UserModel {
    counts: HashMap<String, u32>,
    /// prev -> next -> 次数
    pairs: HashMap<String, HashMap<String, u32>>,
    pair_len: usize,
    /// 按键序列 -> 短语 -> 次数。这就是「AI 辅助短语」的底账：
    /// 不提供手动短语表，连续上屏形成的搭配自动沉淀在这里。
    phrases: HashMap<String, HashMap<String, u32>>,
    phrase_len: usize,
    /// 网址/邮箱习惯：字母段 -> 次数。用户原样上屏过含「.」「@」的 ASCII
    /// 令牌（baidu.com、someone@example.com、v1.2）后，其字母段记在这里；
    /// 下次打同样前缀按「.」时直接续接组合，而不是被当成句号。
    dot_habits: HashMap<String, u32>,
    /// 钉选的候选（最近的在前）：排序时提到所在层首位。
    pins: Vec<String>,
    /// 屏蔽的候选：排序前直接从候选列表剔除。
    bans: std::collections::HashSet<String>,
}

impl UserModel {
    pub fn new() -> Self {
        Self::default()
    }

    /// 用户选词后调用，用于下次重排。
    pub fn record(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        let c = self.counts.entry(text.to_string()).or_insert(0);
        *c = c.saturating_add(1);
    }

    /// 记录「上一个上屏词 → 本次上屏词」，用于下一句的候选预测。
    pub fn record_pair(&mut self, prev: &str, next: &str) {
        if prev.is_empty() || next.is_empty() || prev == next {
            return;
        }
        let entry = self
            .pairs
            .entry(prev.to_string())
            .or_default()
            .entry(next.to_string())
            .or_insert(0);
        if *entry == 0 {
            self.pair_len += 1;
        }
        *entry = entry.saturating_add(1);
        if self.pair_len > MAX_PAIRS {
            self.decay_pairs();
        }
    }

    fn decay_pairs(&mut self) {
        self.pairs.retain(|_, nexts| {
            nexts.retain(|_, c| {
                if *c > 1 {
                    *c /= 2;
                    true
                } else {
                    false
                }
            });
            !nexts.is_empty()
        });
        self.pair_len = self.pairs.values().map(HashMap::len).sum();
    }

    /// 记录一条自动学到的短语：`keys` 是形成它的按键序列（小写、去分隔符）。
    pub fn record_phrase(&mut self, keys: &str, text: &str) {
        if keys.is_empty() || text.is_empty() {
            return;
        }
        let entry = self
            .phrases
            .entry(keys.to_string())
            .or_default()
            .entry(text.to_string())
            .or_insert(0);
        if *entry == 0 {
            self.phrase_len += 1;
        }
        *entry = entry.saturating_add(1);
        if self.phrase_len > MAX_PHRASES {
            self.decay_phrases();
        }
    }

    /// 记录一次「明确选择」：同一个按键串的纠正要让新词压过旧词。
    /// 与 record_phrase 的区别是首次就给到比同键其它词更高的计数，
    /// 这样「选错一次 → 改选一次」立刻生效，不用连选两次。
    pub fn record_choice(&mut self, keys: &str, text: &str) {
        if keys.is_empty() || text.is_empty() {
            return;
        }
        let other_max = self
            .phrases
            .get(keys)
            .map(|texts| {
                texts
                    .iter()
                    .filter(|(t, _)| t.as_str() != text)
                    .map(|(_, c)| *c)
                    .max()
                    .unwrap_or(0)
            })
            .unwrap_or(0);
        let entry = self
            .phrases
            .entry(keys.to_string())
            .or_default()
            .entry(text.to_string())
            .or_insert(0);
        if *entry == 0 {
            self.phrase_len += 1;
        }
        // 明确选择一次就按「两次」计：同一按键串的其它词立刻让位；
        // 连续改选时新词始终比旧词高一次，保证一次点击就能翻回来。
        *entry = (*entry)
            .saturating_add(1)
            .max(other_max.saturating_add(1))
            .max(2);
        if self.phrase_len > MAX_PHRASES {
            self.decay_phrases();
        }
    }

    fn decay_phrases(&mut self) {
        self.phrases.retain(|_, texts| {
            texts.retain(|_, c| {
                if *c > 1 {
                    *c /= 2;
                    true
                } else {
                    false
                }
            });
            !texts.is_empty()
        });
        self.phrase_len = self.phrases.values().map(HashMap::len).sum();
    }

    pub fn phrase_count(&self, keys: &str, text: &str) -> u32 {
        self.phrases
            .get(keys)
            .and_then(|m| m.get(text))
            .copied()
            .unwrap_or(0)
    }

    pub fn phrase_len(&self) -> usize {
        self.phrase_len
    }

    /// 按按键前缀召回短语，返回 `(keys, text, 次数)`，次数降序。
    ///
    /// 短语总量受 `MAX_PHRASES` 约束，这里的线性扫描在每次按键上都足够快。
    pub fn phrase_matches(&self, prefix: &str, limit: usize) -> Vec<(&str, &str, u32)> {
        if prefix.is_empty() || limit == 0 {
            return Vec::new();
        }
        let mut hits: Vec<(&str, &str, u32)> = Vec::new();
        for (keys, texts) in &self.phrases {
            if !keys.starts_with(prefix) {
                continue;
            }
            for (text, c) in texts {
                hits.push((keys.as_str(), text.as_str(), *c));
            }
        }
        // 次数优先，其次短的按键序列（更贴近当前输入）
        hits.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.len().cmp(&b.0.len())));
        hits.truncate(limit);
        hits
    }

    pub fn count(&self, text: &str) -> u32 {
        self.counts.get(text).copied().unwrap_or(0)
    }

    pub fn pair_count(&self, prev: &str, next: &str) -> u32 {
        self.pairs
            .get(prev)
            .and_then(|m| m.get(next))
            .copied()
            .unwrap_or(0)
    }

    pub fn pair_len(&self) -> usize {
        self.pair_len
    }

    /// 重排加分：对数增长，避免个别词完全压过语言模型。
    pub fn bonus(&self, text: &str) -> f64 {
        let c = self.count(text);
        // 选一次就要能跨过常见的同音词频差：词典词频之外，搭配模型还会把
        // 高频虚词组合再抬高 1~2 分（「时间」对「事件」的实际差距≈2.5），
        // 所以首次选词的底分要比词频差更高，第二次起继续按对数增长。
        if c == 0 {
            0.0
        } else {
            2.4 + 1.5 * (c as f64).ln()
        }
    }

    /// 解码用加分：整词加分 + 词内含有用户常用词时的部分加分
    /// （选过「回复」后，词库里的「尽快回复」也要压过「尽快恢复」）。
    pub fn decode_bonus(&self, text: &str) -> f64 {
        let whole = self.bonus(text);
        let chars: Vec<char> = text.chars().collect();
        if chars.len() < 3 || self.counts.is_empty() {
            return whole;
        }
        let mut part = 0.0f64;
        for len in 2..chars.len() {
            for start in 0..=chars.len() - len {
                let sub: String = chars[start..start + len].iter().collect();
                part = part.max(self.bonus(&sub));
            }
        }
        whole.max(part * 0.8)
    }

    /// 二元组加分：能跨过常见词频差（ln 2~3），但设上限避免过度自信。
    pub fn pair_bonus(&self, prev: &str, next: &str) -> f64 {
        let c = self.pair_count(prev, next);
        if c == 0 {
            0.0
        } else {
            (2.2 * (c as f64 + 1.0).ln()).min(9.0)
        }
    }

    /// 记录一条网址/邮箱习惯：`label` 是 ASCII 令牌里的一段字母
    /// （baidu.com → baidu；someone@example.com → someone、example）。
    pub fn record_dot_habit(&mut self, label: &str) {
        if !dot_habit_label_ok(label) {
            return;
        }
        let entry = self.dot_habits.entry(label.to_string()).or_insert(0);
        *entry = entry.saturating_add(1);
        if self.dot_habits.len() > MAX_DOT_HABITS {
            self.decay_dot_habits();
        }
    }

    fn decay_dot_habits(&mut self) {
        self.dot_habits.retain(|_, c| {
            if *c > 1 {
                *c /= 2;
                true
            } else {
                false
            }
        });
    }

    /// 某个字母段的网址习惯次数（0 = 没有）。
    pub fn dot_habit(&self, label: &str) -> u32 {
        if !dot_habit_label_ok(label) {
            return 0;
        }
        self.dot_habits.get(label).copied().unwrap_or(0)
    }

    /// 钉选候选（微信式「固定首位」）：最近的排最前；重复钉选提升优先级。
    pub fn pin(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        self.pins.retain(|t| t != text);
        self.pins.insert(0, text.to_string());
        self.pins.truncate(MAX_PINS);
    }

    /// 屏蔽候选（「不再显示」）：只收多字词，单字是输入结构不许屏蔽。
    /// 同时清掉它的个人词频与搭配证据（屏蔽即遗忘）。
    pub fn ban(&mut self, text: &str) -> bool {
        let text = text.trim();
        if text.chars().count() < 2 {
            return false;
        }
        if !self.bans.insert(text.to_string()) {
            return true;
        }
        self.counts.remove(text);
        for nexts in self.pairs.values_mut() {
            nexts.remove(text);
        }
        for texts in self.phrases.values_mut() {
            texts.remove(text);
        }
        if self.bans.len() > MAX_BANS {
            // 超限时丢掉最早的一半（HashSet 无序，简单截断即可）
            let keep: std::collections::HashSet<String> =
                self.bans.iter().skip(MAX_BANS / 2).cloned().collect();
            self.bans = keep;
        }
        true
    }

    pub fn is_pinned(&self, text: &str) -> bool {
        self.pins.iter().any(|t| t == text)
    }

    pub fn is_banned(&self, text: &str) -> bool {
        self.bans.contains(text)
    }

    /// 钉选列表（最近的在前），供排序与展示。
    pub fn pinned(&self) -> &[String] {
        &self.pins
    }

    pub fn len(&self) -> usize {
        self.counts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.counts.is_empty()
            && self.pairs.is_empty()
            && self.phrases.is_empty()
            && self.dot_habits.is_empty()
            && self.pins.is_empty()
            && self.bans.is_empty()
    }

    pub fn clear(&mut self) {
        self.counts.clear();
        self.pairs.clear();
        self.pair_len = 0;
        self.phrases.clear();
        self.phrase_len = 0;
        self.dot_habits.clear();
        self.pins.clear();
        self.bans.clear();
    }

    /// 导出为 TSV：`词\t次数`；二元组行为 `@pair\t前词\t后词\t次数`，
    /// 短语行为 `@phrase\t按键\t短语\t次数`，供加密存储层使用。
    pub fn export_tsv(&self) -> String {
        let mut keys: Vec<_> = self.counts.iter().collect();
        keys.sort_by(|a, b| a.0.cmp(b.0));
        let mut out = String::new();
        for (w, c) in keys {
            out.push_str(w);
            out.push('\t');
            out.push_str(&c.to_string());
            out.push('\n');
        }
        let mut prevs: Vec<_> = self.pairs.iter().collect();
        prevs.sort_by(|a, b| a.0.cmp(b.0));
        for (prev, nexts) in prevs {
            let mut ns: Vec<_> = nexts.iter().collect();
            ns.sort_by(|a, b| a.0.cmp(b.0));
            for (next, c) in ns {
                out.push_str("@pair\t");
                out.push_str(prev);
                out.push('\t');
                out.push_str(next);
                out.push('\t');
                out.push_str(&c.to_string());
                out.push('\n');
            }
        }
        let mut keys: Vec<_> = self.phrases.iter().collect();
        keys.sort_by(|a, b| a.0.cmp(b.0));
        for (k, texts) in keys {
            let mut ts: Vec<_> = texts.iter().collect();
            ts.sort_by(|a, b| a.0.cmp(b.0));
            for (text, c) in ts {
                out.push_str("@phrase\t");
                out.push_str(k);
                out.push('\t');
                out.push_str(text);
                out.push('\t');
                out.push_str(&c.to_string());
                out.push('\n');
            }
        }
        let mut dots: Vec<_> = self.dot_habits.iter().collect();
        dots.sort_by(|a, b| a.0.cmp(b.0));
        for (label, c) in dots {
            out.push_str("@dot\t");
            out.push_str(label);
            out.push('\t');
            out.push_str(&c.to_string());
            out.push('\n');
        }
        for text in &self.pins {
            out.push_str("@pin\t");
            out.push_str(text);
            out.push('\n');
        }
        let mut bans: Vec<_> = self.bans.iter().collect();
        bans.sort();
        for text in bans {
            out.push_str("@ban\t");
            out.push_str(text);
            out.push('\n');
        }
        out
    }

    /// 导入 TSV（覆盖同名条目），返回成功条目数（词 + 二元组 + 短语 + 习惯）。
    pub fn import_tsv(&mut self, s: &str) -> usize {
        self.apply_tsv(s, false)
    }

    /// 合并 TSV：同名条目取**较大**的次数，重复导入同一份备份不会让计数翻倍。
    pub fn merge_tsv(&mut self, s: &str) -> usize {
        self.apply_tsv(s, true)
    }

    fn apply_tsv(&mut self, s: &str, merge: bool) -> usize {
        let mut n = 0;
        for line in s.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut it = line.split('\t');
            let Some(first) = it.next() else { continue };
            if first == "@phrase" {
                let (Some(keys), Some(text), Some(c)) = (it.next(), it.next(), it.next()) else {
                    continue;
                };
                let Ok(c) = c.trim().parse::<u32>() else {
                    continue;
                };
                if keys.is_empty() || text.is_empty() {
                    continue;
                }
                let entry = self
                    .phrases
                    .entry(keys.to_string())
                    .or_default()
                    .entry(text.to_string())
                    .or_insert(0);
                if *entry == 0 {
                    self.phrase_len += 1;
                }
                *entry = if merge { (*entry).max(c) } else { c };
                n += 1;
                continue;
            }
            if first == "@pair" {
                let (Some(prev), Some(next), Some(c)) = (it.next(), it.next(), it.next()) else {
                    continue;
                };
                let Ok(c) = c.trim().parse::<u32>() else {
                    continue;
                };
                if prev.is_empty() || next.is_empty() {
                    continue;
                }
                let entry = self
                    .pairs
                    .entry(prev.to_string())
                    .or_default()
                    .entry(next.to_string())
                    .or_insert(0);
                if *entry == 0 {
                    self.pair_len += 1;
                }
                *entry = if merge { (*entry).max(c) } else { c };
                n += 1;
                continue;
            }
            if first == "@pin" {
                let Some(text) = it.next() else { continue };
                if text.chars().count() < 2 || text.chars().count() > 32 {
                    continue;
                }
                if !self.pins.iter().any(|t| t == text) {
                    self.pins.push(text.to_string());
                }
                n += 1;
                continue;
            }
            if first == "@ban" {
                let Some(text) = it.next() else { continue };
                if text.chars().count() >= 2 {
                    self.bans.insert(text.to_string());
                }
                n += 1;
                continue;
            }
            if first == "@dot" {
                let (Some(label), Some(c)) = (it.next(), it.next()) else {
                    continue;
                };
                let Ok(c) = c.trim().parse::<u32>() else {
                    continue;
                };
                if !dot_habit_label_ok(label) {
                    continue;
                }
                let slot = self.dot_habits.entry(label.to_string()).or_insert(0);
                *slot = if merge { (*slot).max(c) } else { c };
                n += 1;
                continue;
            }
            let Some(c) = it.next() else { continue };
            let Ok(c) = c.trim().parse::<u32>() else {
                continue;
            };
            if first.is_empty() {
                continue;
            }
            let slot = self.counts.entry(first.to_string()).or_insert(0);
            *slot = if merge { (*slot).max(c) } else { c };
            n += 1;
        }
        n
    }
}

/// 网址/邮箱习惯段的有效性：2~24 个 ASCII 字母/数字/连字符/下划线。
/// 数字纯段（「163」「2」）不记——数字后的小数点由前端的上下文规则处理。
fn dot_habit_label_ok(label: &str) -> bool {
    let len = label.len();
    (2..=24).contains(&len)
        && label.is_ascii()
        && label.chars().any(|c| c.is_ascii_alphabetic())
        && label
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_bonus() {
        let mut u = UserModel::new();
        assert_eq!(u.bonus("你好"), 0.0);
        u.record("你好");
        assert_eq!(u.count("你好"), 1);
        let b1 = u.bonus("你好");
        u.record("你好");
        assert!(u.bonus("你好") > b1);
        assert_eq!(u.len(), 1);
    }

    #[test]
    fn tsv_roundtrip() {
        let mut u = UserModel::new();
        u.record("你好");
        u.record("你好");
        u.record("世界");
        let s = u.export_tsv();
        let mut v = UserModel::new();
        assert_eq!(v.import_tsv(&s), 2);
        assert_eq!(v.count("你好"), 2);
        assert_eq!(v.count("世界"), 1);
    }

    #[test]
    fn merge_takes_max_and_is_idempotent() {
        let mut u = UserModel::new();
        u.record("你好");
        u.record("你好");
        u.record("你好"); // 3 次
        let backup = {
            let mut v = UserModel::new();
            v.record("你好");
            v.record("世界");
            v.record_pair("北京", "世界");
            v.record_phrase("beijingshijie", "北京世界");
            v.export_tsv()
        };
        u.merge_tsv(&backup);
        assert_eq!(u.count("你好"), 3, "本机次数更高时不该被备份覆盖");
        assert_eq!(u.count("世界"), 1);
        assert_eq!(u.pair_count("北京", "世界"), 1);

        u.merge_tsv(&backup);
        assert_eq!(u.count("世界"), 1, "重复导入同一份备份不应翻倍");
        assert_eq!(u.phrase_count("beijingshijie", "北京世界"), 1);

        // 覆盖式导入仍然以备份为准
        u.import_tsv(&backup);
        assert_eq!(u.count("你好"), 1);
    }

    #[test]
    fn import_tolerates_garbage() {
        let mut u = UserModel::new();
        let n = u.import_tsv("# 注释\n\n坏行\n好\t3\nx\tNaN\n");
        assert_eq!(n, 1);
        assert_eq!(u.count("好"), 3);
    }

    #[test]
    fn pair_bonus_grows_and_is_capped() {
        let mut u = UserModel::new();
        assert_eq!(u.pair_bonus("北京", "世界"), 0.0);
        u.record_pair("北京", "世界");
        let b1 = u.pair_bonus("北京", "世界");
        assert!(b1 > 0.0);
        for _ in 0..500 {
            u.record_pair("北京", "世界");
        }
        assert!(u.pair_bonus("北京", "世界") > b1);
        assert!(u.pair_bonus("北京", "世界") <= 9.0);
        assert_eq!(u.pair_len(), 1);
    }

    #[test]
    fn pair_tsv_roundtrip() {
        let mut u = UserModel::new();
        u.record("北京");
        u.record_pair("北京", "世界");
        u.record_pair("北京", "世界");
        let s = u.export_tsv();
        assert!(s.contains("@pair\t北京\t世界\t2"), "{s}");
        let mut v = UserModel::new();
        let n = v.import_tsv(&s);
        assert_eq!(n, 2);
        assert_eq!(v.count("北京"), 1);
        assert_eq!(v.pair_count("北京", "世界"), 2);
    }

    #[test]
    fn phrase_record_match_and_roundtrip() {
        let mut u = UserModel::new();
        u.record_phrase("nihaoshijie", "你好世界");
        u.record_phrase("nihaoshijie", "你好世界");
        u.record_phrase("nihaopengyou", "你好朋友");
        assert_eq!(u.phrase_count("nihaoshijie", "你好世界"), 2);
        assert_eq!(u.phrase_len(), 2);

        let hits = u.phrase_matches("nihao", 5);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].1, "你好世界", "次数多的排前面: {hits:?}");
        assert!(u.phrase_matches("zzz", 5).is_empty());

        let tsv = u.export_tsv();
        assert!(tsv.contains("@phrase\tnihaoshijie\t你好世界\t2"), "{tsv}");
        let mut v = UserModel::new();
        v.import_tsv(&tsv);
        assert_eq!(v.phrase_count("nihaoshijie", "你好世界"), 2);
        assert_eq!(v.phrase_len(), 2);
    }

    /// 明确选择一次就压过同键的旧词；再改选也一次翻回来。
    #[test]
    fn record_choice_overrides_previous_choice() {
        let mut u = UserModel::new();
        u.record_phrase("gongshi", "公示");
        u.record_choice("gongshi", "攻势");
        assert!(
            u.phrase_count("gongshi", "攻势") > u.phrase_count("gongshi", "公示"),
            "第一次明确选择就应压过旧词"
        );
        u.record_choice("gongshi", "公示");
        assert!(
            u.phrase_count("gongshi", "公示") > u.phrase_count("gongshi", "攻势"),
            "改选也应一次生效"
        );
    }

    #[test]
    fn phrase_decay_keeps_frequent() {
        let mut u = UserModel::new();
        u.record_phrase("ab", "甲乙");
        u.record_phrase("ab", "甲乙");
        u.record_phrase("cd", "丙丁");
        u.phrase_len = MAX_PHRASES + 1; // 模拟超限
        u.decay_phrases();
        assert_eq!(u.phrase_count("ab", "甲乙"), 1);
        assert_eq!(u.phrase_count("cd", "丙丁"), 0);
    }

    #[test]
    fn pair_decay_keeps_frequent() {
        let mut u = UserModel::new();
        u.record_pair("a", "b");
        u.record_pair("a", "b");
        u.record_pair("c", "d");
        u.pair_len = MAX_PAIRS + 1; // 模拟超限
        u.decay_pairs();
        assert_eq!(u.pair_count("a", "b"), 1);
        assert_eq!(u.pair_count("c", "d"), 0);
    }

    /// 网址/邮箱习惯：有效字母段记次数，无效段（纯数字、过长、含符号）忽略，
    /// TSV 导出/导入走 @dot 行。
    #[test]
    fn dot_habit_record_filter_and_roundtrip() {
        let mut u = UserModel::new();
        u.record_dot_habit("baidu");
        u.record_dot_habit("baidu");
        u.record_dot_habit("v1");
        assert_eq!(u.dot_habit("baidu"), 2);
        assert_eq!(u.dot_habit("v1"), 1);
        // 无效段：纯数字、太短、太长、含符号
        u.record_dot_habit("163");
        u.record_dot_habit("a");
        u.record_dot_habit(&"x".repeat(30));
        u.record_dot_habit("bad=label");
        assert_eq!(u.dot_habit("163"), 0);
        assert_eq!(u.dot_habit("a"), 0);
        assert_eq!(u.dot_habit(&"x".repeat(30)), 0);

        let tsv = u.export_tsv();
        assert!(tsv.contains("@dot\tbaidu\t2"), "{tsv}");
        let mut v = UserModel::new();
        assert_eq!(v.import_tsv(&tsv), 2, "两个有效习惯段: {tsv}");
        assert_eq!(v.dot_habit("baidu"), 2);
        // 合并取较大值
        v.merge_tsv(&tsv);
        assert_eq!(v.dot_habit("baidu"), 2);

        u.clear();
        assert_eq!(u.dot_habit("baidu"), 0);
    }
}
