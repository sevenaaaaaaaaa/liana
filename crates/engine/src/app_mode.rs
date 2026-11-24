//! 每应用语言记忆：本地统计模型（指数衰减投票 + 置信度判定）。
//!
//! 回答一个问题：「切到这个应用时，该用哪种语言？」
//! M2 起按语言 id 记票（zh/ja/en/ko/es...），不再只有中英两档；
//! macOS 仍可用 decide_chinese 取「是否中文」的兼容答案。
//!
//! 隐私边界：只存「应用 bundle id → 语言票数」，不存按键内容、不存时间线明细。
//!
//! 信号有两类：
//! - 手动切换（Shift 裸按 / 菜单选择）是强意图，一票即足以确立偏好；
//! - 上屏是弱信号（这个应用里在用哪种语言写字），按天封顶，防止长文淹没手动切换。
//!
//! 旧票按半衰期淡忘：换工作流半年后，旧习惯不会一直纠缠。

use std::collections::BTreeMap;

/// 手动切换的票重：明确意图，一票即足以确立（并压过弱信号）。
const TOGGLE_WEIGHT: f32 = 3.0;
/// 单次上屏的弱票重。
const COMMIT_WEIGHT: f32 = 0.2;
/// 上屏票按天封顶：一个自然日内最多贡献这么多票。
const DAILY_COMMIT_CAP: f32 = 1.0;
/// 票的半衰期：14 天。
const HALF_LIFE_SECS: f64 = 14.0 * 24.0 * 3600.0;
/// 判定「记得住」的门槛：胜方至少这么多分，且对败方有这么大的优势比。
const CONFIDENT_MIN: f32 = 2.0;
const CONFIDENT_RATIO: f32 = 2.0;
/// 记录的应用数上限：超出时挤掉最久没更新的（防御异常超长的应用列表）。
const MAX_ENTRIES: usize = 256;

#[derive(Debug, Clone, Default, PartialEq)]
struct Entry {
    /// 语言 id → 票数。
    scores: BTreeMap<Box<str>, f32>,
    /// 上屏票的按天计数器（Unix 天），跨天清零。
    commit_day: u64,
    commit_votes: f32,
    updated_at: u64,
}

/// 应用 → 语言偏好的本地学习器。纯逻辑、零依赖，持久化由前端负责。
#[derive(Debug, Default)]
pub struct AppModeMemory {
    entries: BTreeMap<String, Entry>,
}

/// bundle id 只做最小净化：去首尾空白；为空或含制表/换行/控制字符则拒绝。
fn sanitize(app: &str) -> Option<String> {
    let trimmed = app.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed
        .chars()
        .any(|c| c == '\t' || c == '\n' || c == '\r' || c.is_control())
    {
        return None;
    }
    Some(trimmed.to_string())
}

/// 语言 id 同样要净化：只允许小写字母、数字与连字符，长度 1..24。
fn sanitize_lang(lang: &str) -> Option<&str> {
    let l = lang.trim();
    if l.is_empty() || l.len() > 24 {
        return None;
    }
    if !l
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return None;
    }
    Some(l)
}

fn decay(score: f32, from: u64, now: u64) -> f32 {
    if now <= from {
        return score;
    }
    let dt = (now - from) as f64;
    ((score as f64) * 0.5f64.powf(dt / HALF_LIFE_SECS)) as f32
}

impl Entry {
    fn fold_decay(&mut self, now: u64) {
        for v in self.scores.values_mut() {
            *v = decay(*v, self.updated_at, now);
        }
        self.updated_at = now;
    }

    fn score(&self, lang: &str, now: u64) -> f32 {
        self.scores
            .get(lang)
            .map(|v| decay(*v, self.updated_at, now))
            .unwrap_or(0.0)
    }
}

impl AppModeMemory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 记录一次信号。lang 是语言 id；strong = 用户手动切换。
    /// 返回是否被记录（应用 id 或语言 id 非法时忽略）。
    pub fn observe(&mut self, app: &str, lang: &str, strong: bool, now: u64) -> bool {
        let (Some(key), Some(lang)) = (sanitize(app), sanitize_lang(lang)) else {
            return false;
        };
        {
            let entry = self.entries.entry(key.clone()).or_default();
            entry.fold_decay(now);
            let weight = if strong {
                TOGGLE_WEIGHT
            } else {
                let day = now / 86_400;
                if entry.commit_day != day {
                    entry.commit_day = day;
                    entry.commit_votes = 0.0;
                }
                let budget = (DAILY_COMMIT_CAP - entry.commit_votes).max(0.0);
                let w = COMMIT_WEIGHT.min(budget);
                entry.commit_votes += w;
                w
            };
            *entry.scores.entry(lang.into()).or_insert(0.0) += weight;
            entry.updated_at = now;
        }
        if self.entries.len() > MAX_ENTRIES {
            let oldest = self
                .entries
                .iter()
                .filter(|(k, _)| k.as_str() != key)
                .min_by_key(|(_, e)| e.updated_at)
                .map(|(k, _)| k.clone());
            if let Some(oldest) = oldest {
                self.entries.remove(&oldest);
            }
        }
        true
    }

    /// 兼容旧调用：chinese=true 记 zh，否则记 en。
    pub fn observe_chinese(&mut self, app: &str, chinese: bool, strong: bool, now: u64) -> bool {
        self.observe(app, if chinese { "zh" } else { "en" }, strong, now)
    }

    /// 这个应用现在最该用哪种语言？样本不足或意见分裂时返回 None（不干预）。
    pub fn decide(&self, app: &str, now: u64) -> Option<&str> {
        let key = sanitize(app)?;
        let entry = self.entries.get(&key)?;
        let mut best: Option<(&str, f32)> = None;
        let mut second = 0.0f32;
        for (lang, raw) in &entry.scores {
            let s = decay(*raw, entry.updated_at, now);
            match best {
                Some((_, b)) if s <= b => second = second.max(s),
                _ => {
                    if let Some((_, b)) = best {
                        second = second.max(b);
                    }
                    best = Some((lang.as_ref(), s));
                }
            }
        }
        let (lang, top) = best?;
        if top < CONFIDENT_MIN {
            return None;
        }
        if second > 0.0 && top / second < CONFIDENT_RATIO {
            return None;
        }
        Some(lang)
    }

    /// 兼容旧调用：只回答「是否中文」。胜方是 ja/ko/es 时返回 None，
    /// 前端不会因为日语偏好而误切回中文。
    pub fn decide_chinese(&self, app: &str, now: u64) -> Option<bool> {
        match self.decide(app, now)? {
            "zh" => Some(true),
            "en" => Some(false),
            _ => None,
        }
    }

    /// 忘记单个应用的偏好。返回是否存在过。
    pub fn forget(&mut self, app: &str) -> bool {
        let Some(key) = sanitize(app) else {
            return false;
        };
        self.entries.remove(&key).is_some()
    }

    pub fn forget_all(&mut self) {
        self.entries.clear();
    }

    /// 导出为 TSV：应用 \t 语言 \t 票数 \t 上屏天 \t 上屏票 \t 更新时间。
    /// 一个应用有几种语言就几行；旧版 6 列「中文票/英文票」仍可被 import 识别。
    pub fn export_tsv(&self) -> String {
        let mut out = String::new();
        for (app, e) in &self.entries {
            for (lang, score) in &e.scores {
                if *score <= 0.0 {
                    continue;
                }
                out.push_str(app);
                out.push('\t');
                out.push_str(lang);
                out.push('\t');
                out.push_str(&format!("{score:.3}"));
                out.push('\t');
                out.push_str(&e.commit_day.to_string());
                out.push('\t');
                out.push_str(&format!("{:.3}", e.commit_votes));
                out.push('\t');
                out.push_str(&e.updated_at.to_string());
                out.push('\n');
            }
        }
        out
    }

    /// 导入 TSV，返回成功导入的行数；坏行跳过，绝不 panic。
    /// 兼容两种 6 列格式：
    /// - 旧：应用 / 中文票 / 英文票 / 天 / 上屏票 / 时间；
    /// - 新：应用 / 语言 id / 票数 / 天 / 上屏票 / 时间。
    pub fn import_tsv(&mut self, tsv: &str) -> usize {
        let mut imported = 0;
        for line in tsv.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 6 {
                continue;
            }
            let (Some(key), Some(day), Some(votes), Some(at)) = (
                sanitize(f[0]),
                f[3].parse::<u64>().ok(),
                f[4].parse::<f32>().ok(),
                f[5].parse::<u64>().ok(),
            ) else {
                continue;
            };
            let entry = self.entries.entry(key).or_default();
            entry.commit_day = day;
            entry.commit_votes = votes;
            entry.updated_at = at;
            if let (Ok(zh), Ok(en)) = (f[1].parse::<f32>(), f[2].parse::<f32>()) {
                entry.scores.insert("zh".into(), zh);
                entry.scores.insert("en".into(), en);
                imported += 1;
                continue;
            }
            let (Some(lang), Ok(score)) = (sanitize_lang(f[1]), f[2].parse::<f32>()) else {
                continue;
            };
            entry.scores.insert(lang.into(), score);
            imported += 1;
        }
        imported
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 86_400;

    #[test]
    fn empty_memory_decides_nothing() {
        let m = AppModeMemory::new();
        assert_eq!(m.decide("com.example.app", 1_000), None);
        assert!(m.is_empty());
    }

    #[test]
    fn single_manual_toggle_establishes_preference() {
        let mut m = AppModeMemory::new();
        assert!(m.observe("com.apple.Terminal", "en", true, 1_000));
        assert_eq!(m.decide("com.apple.Terminal", 1_000), Some("en"));
        assert_eq!(m.decide("com.apple.Terminal", 1_000 + 3 * DAY), Some("en"));
    }

    #[test]
    fn opposite_toggles_cancel_out() {
        let mut m = AppModeMemory::new();
        m.observe("app", "en", true, 1_000);
        m.observe("app", "zh", true, 1_100);
        assert_eq!(m.decide("app", 1_200), None);
    }

    #[test]
    fn majority_needs_two_to_one_advantage() {
        let mut m = AppModeMemory::new();
        m.observe("app", "zh", true, 1_000);
        m.observe("app", "zh", true, 1_000);
        m.observe("app", "en", true, 1_000);
        assert_eq!(m.decide("app", 1_000), Some("zh"));
        assert_eq!(m.decide_chinese("app", 1_000), Some(true));
    }

    #[test]
    fn old_votes_fade_after_half_lives() {
        let mut m = AppModeMemory::new();
        m.observe("app", "en", true, 1_000);
        assert_eq!(m.decide("app", 1_000 + 4 * 14 * DAY), None);
    }

    #[test]
    fn commit_votes_are_weak_and_daily_capped() {
        let mut m = AppModeMemory::new();
        m.observe("app", "zh", true, DAY);
        for i in 0..10 {
            m.observe("app", "en", false, DAY + i);
        }
        assert_eq!(m.decide("app", DAY + 100), Some("zh"));
    }

    #[test]
    fn three_languages_keep_independent_scores() {
        let mut m = AppModeMemory::new();
        m.observe("app", "zh", true, 1_000);
        m.observe("app", "ja", true, 1_000);
        m.observe("app", "ja", true, 1_000);
        m.observe("app", "ja", true, 1_000);
        // ja 9.0 对 zh 3.0，优势比 3 → 判日语
        assert_eq!(m.decide("app", 1_000), Some("ja"));
        // 旧接口不把日语当中文
        assert_eq!(m.decide_chinese("app", 1_000), None);
    }

    #[test]
    fn export_import_roundtrip_with_three_languages() {
        let mut m = AppModeMemory::new();
        m.observe("app.one", "zh", true, 1_000);
        m.observe("app.one", "zh", true, 1_000);
        m.observe("app.one", "zh", true, 1_000);
        m.observe("app.one", "ja", true, 1_000);
        m.observe("app.two", "es", true, 3_000);
        let tsv = m.export_tsv();
        assert_eq!(tsv.lines().count(), 3);
        let mut n = AppModeMemory::new();
        assert_eq!(n.import_tsv(&tsv), 3);
        assert_eq!(n.len(), 2);
        assert_eq!(n.decide("app.one", 2_000), Some("zh"));
        assert_eq!(n.decide("app.two", 3_000), Some("es"));
    }

    #[test]
    fn legacy_two_column_import_still_works() {
        let mut m = AppModeMemory::new();
        let legacy = "com.apple.Terminal\t3.000\t0.000\t20000\t0.200\t1720000000\n";
        assert_eq!(m.import_tsv(legacy), 1);
        assert_eq!(m.decide_chinese("com.apple.Terminal", 1720000000), Some(true));
        assert_eq!(m.decide("com.apple.Terminal", 1720000000), Some("zh"));
    }

    #[test]
    fn invalid_language_is_ignored() {
        let mut m = AppModeMemory::new();
        assert!(!m.observe("app", "ZH", true, 1_000));
        assert!(!m.observe("app", "", true, 1_000));
        assert!(m.is_empty());
    }
}
