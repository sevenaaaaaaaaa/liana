//! 词典：内存索引 + IFD1 二进制格式 + 导入器。零第三方依赖。

pub mod binary;
pub mod import;
pub mod lm;

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, OnceLock};

pub use import::{ImportReport, normalize_pinyin};

/// 词条。`letters`/`syls` 由 key 推导，用于计算候选消费掉多少按键字符。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub word: String,
    pub freq: u32,
    pub letters: u16,
    pub syls: u16,
}

/// 前缀查询命中：`key` 的字母串（去撇号）以查询串开头。
#[derive(Debug, Clone, Copy)]
pub struct PrefixHit<'a> {
    pub key: &'a str,
    pub entry: &'a Entry,
}

#[derive(Debug, Default)]
pub struct Dictionary {
    map: HashMap<String, Vec<Entry>>,
    entries: usize,
    /// (字母串, key)，按字母串排序；首次前缀查询时构建。
    prefix: OnceLock<Vec<(Box<str>, Box<str>)>>,
    /// (首字母串, key)，按首字母串排序；简拼查询用。
    initials: OnceLock<Vec<(Box<str>, Box<str>)>>,
    /// 字 → 拼音音节（取词频最高的读音）；喂食层给营养词派生按键串用。
    char_pinyin: OnceLock<HashMap<char, Box<str>>>,
    /// ln(全部词频之和)：把词频换算成对数概率的归一化常数（解码器整句打分用）。
    log_total: OnceLock<f64>,
    /// 字级搭配模型（可选）：整句解码按上下文打分；没有时退回纯词频。
    collocations: Option<Arc<lm::Collocations>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DictError {
    BadMagic,
    Truncated,
    Overflow,
    InvalidUtf8,
}

impl fmt::Display for DictError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            DictError::BadMagic => "不是合法的 IFD1 词典文件",
            DictError::Truncated => "词典文件被截断",
            DictError::Overflow => "词典文件长度字段溢出",
            DictError::InvalidUtf8 => "词典文件包含非法 UTF-8",
        };
        f.write_str(s)
    }
}

impl std::error::Error for DictError {}

const EMPTY: &[Entry] = &[];

/// key（`ni'hao`）的首字母串（`nh`）。
fn initials_of(key: &str) -> String {
    key.split('\'').filter_map(|s| s.chars().next()).collect()
}

/// 混拼匹配：query 的每个字母要么对应「整音节」，要么对应「音节首字母」。
fn abbrev_match(query: &str, key: &str) -> bool {
    fn go(q: &[u8], rest: &str) -> bool {
        if q.is_empty() {
            return rest.is_empty();
        }
        if rest.is_empty() {
            return false;
        }
        let (syl, tail) = match rest.find('\'') {
            Some(i) => (&rest[..i], &rest[i + 1..]),
            None => (rest, ""),
        };
        let sb = syl.as_bytes();
        if q.len() >= sb.len() && &q[..sb.len()] == sb && go(&q[sb.len()..], tail) {
            return true;
        }
        if q[0] == sb[0] && go(&q[1..], tail) {
            return true;
        }
        false
    }
    go(query.as_bytes(), key)
}

impl Dictionary {
    pub fn new() -> Self {
        Self::default()
    }

    /// 插入或提升词频。key 形如 `ni'hao`。
    pub fn insert(&mut self, key: &str, word: &str, freq: u32) {
        if key.is_empty() || word.is_empty() {
            return;
        }
        let letters = key.bytes().filter(u8::is_ascii_alphabetic).count() as u16;
        let syls = key.split('\'').count() as u16;
        let freq = freq.max(1);
        let list = self.map.entry(key.to_string()).or_default();
        if let Some(e) = list.iter_mut().find(|e| e.word == word) {
            if freq > e.freq {
                e.freq = freq;
            }
        } else {
            list.push(Entry {
                word: word.to_string(),
                freq,
                letters,
                syls,
            });
            self.entries += 1;
        }
        if list.len() > 1 {
            list.sort_by(|a, b| b.freq.cmp(&a.freq).then_with(|| a.word.cmp(&b.word)));
        }
        // 索引与内容保持一致：内容变化时重建。
        self.prefix = OnceLock::new();
        self.initials = OnceLock::new();
        self.char_pinyin = OnceLock::new();
        self.log_total = OnceLock::new();
    }

    /// 挂上字级搭配模型（与词库同生命周期，进程内共享）。
    pub fn set_collocations(&mut self, lm: Option<Arc<lm::Collocations>>) {
        self.collocations = lm;
    }

    pub fn collocations(&self) -> Option<&lm::Collocations> {
        self.collocations.as_deref()
    }

    /// ln(Σ词频)：词频 → 对数概率的归一化常数。空词典返回 0。
    pub fn log_total(&self) -> f64 {
        *self.log_total.get_or_init(|| {
            let sum: f64 = self
                .map
                .values()
                .flat_map(|v| v.iter())
                .map(|e| f64::from(e.freq))
                .sum();
            if sum > 0.0 { sum.ln() } else { 0.0 }
        })
    }

    /// 按 key 查候选（词频降序，同频按字典序）。
    pub fn lookup(&self, key: &str) -> &[Entry] {
        self.map.get(key).map(Vec::as_slice).unwrap_or(EMPTY)
    }

    /// 字 → 拼音音节（无分隔符的小写字母串，如 `zhang`），取词典里词频最高的读音。
    /// 喂食层用它给营养词派生按键串；缺字返回 None。首次调用时构建，之后只读。
    pub fn char_pinyin(&self) -> &HashMap<char, Box<str>> {
        self.char_pinyin.get_or_init(|| {
            let mut best: HashMap<char, (u32, &str)> = HashMap::new();
            for (key, entries) in &self.map {
                // 单音节键才可能是单字条目（多字词的键含分隔符）
                if key.contains('\'') {
                    continue;
                }
                for e in entries {
                    let mut cs = e.word.chars();
                    let (Some(ch), None) = (cs.next(), cs.next()) else {
                        continue;
                    };
                    match best.get(&ch) {
                        Some(&(freq, _)) if freq >= e.freq => continue,
                        _ => {
                            best.insert(ch, (e.freq, key.as_str()));
                        }
                    }
                }
            }
            best.into_iter()
                .map(|(ch, (_, key))| (ch, Box::<str>::from(key)))
                .collect()
        })
    }

    /// 给一批没有拼音的词自动注音，返回词库 key（`yin'hang`）；有字不在词库里时为 None。
    ///
    /// 先按词库里已有的词切分（「招商银行」→ 招商 + 银行，多音字跟着词走），
    /// 切不出来的部分逐字取最高频读音；切分取段数最少的方案。
    pub fn annotate(&self, words: &[&str]) -> Vec<Option<String>> {
        // 词 → 最高词频的读音（只借用词库里的字符串，不复制）
        let mut readings: HashMap<&str, (&str, u32)> = HashMap::with_capacity(self.entries);
        for (key, list) in &self.map {
            for e in list {
                let slot = readings.entry(e.word.as_str()).or_insert((key.as_str(), 0));
                if e.freq > slot.1 {
                    *slot = (key.as_str(), e.freq);
                }
            }
        }
        const MAX_PIECE: usize = 8;
        words
            .iter()
            .map(|word| {
                let chars: Vec<(usize, char)> = word.char_indices().collect();
                let n = chars.len();
                if n == 0 {
                    return None;
                }
                let byte_at = |i: usize| if i == n { word.len() } else { chars[i].0 };
                // best[i] = 前 i 个字的 (段数, 读音列表)
                let mut best: Vec<Option<(usize, Vec<&str>)>> = vec![None; n + 1];
                best[0] = Some((0, Vec::new()));
                for end in 1..=n {
                    for start in end.saturating_sub(MAX_PIECE)..end {
                        let Some((segs, keys)) = &best[start] else {
                            continue;
                        };
                        let piece = &word[byte_at(start)..byte_at(end)];
                        let Some(&(key, _)) = readings.get(piece) else {
                            continue;
                        };
                        if best[end].as_ref().is_none_or(|(s, _)| segs + 1 < *s) {
                            let mut next = keys.clone();
                            next.push(key);
                            best[end] = Some((segs + 1, next));
                        }
                    }
                }
                best[n].take().map(|(_, keys)| keys.join("'"))
            })
            .collect()
    }

    fn prefix_index(&self) -> &[(Box<str>, Box<str>)] {
        self.prefix.get_or_init(|| {
            let mut idx: Vec<(Box<str>, Box<str>)> = self
                .map
                .keys()
                .map(|key| {
                    let letters: String = key.chars().filter(|c| *c != '\'').collect();
                    (letters.into_boxed_str(), key.clone().into_boxed_str())
                })
                .collect();
            idx.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
            idx
        })
    }

    /// 前缀查询：返回字母串以 `letters` 开头的 key（每个 key 取词频最高的一条）。
    ///
    /// `max_per_key` 控制同一 key 下取多少条词条（如 `shi` 下的 是/时/事）。
    pub fn lookup_prefix(&self, letters: &str, per_key: usize, limit: usize) -> Vec<PrefixHit<'_>> {
        if letters.is_empty() || limit == 0 {
            return Vec::new();
        }
        let idx = self.prefix_index();
        let start = idx.partition_point(|(l, _)| l.as_ref() < letters);
        let mut out = Vec::new();
        for (l, key) in &idx[start..] {
            if !l.starts_with(letters) {
                break;
            }
            if let Some(entries) = self.map.get(key.as_ref()) {
                for entry in entries.iter().take(per_key.max(1)) {
                    out.push(PrefixHit {
                        key: key.as_ref(),
                        entry,
                    });
                    if out.len() >= limit {
                        return out;
                    }
                }
            }
        }
        out
    }

    fn initials_index(&self) -> &[(Box<str>, Box<str>)] {
        self.initials.get_or_init(|| {
            let mut idx: Vec<(Box<str>, Box<str>)> = self
                .map
                .keys()
                .map(|key| {
                    (
                        initials_of(key).into_boxed_str(),
                        key.clone().into_boxed_str(),
                    )
                })
                .collect();
            idx.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
            idx
        })
    }

    /// 简拼查询：返回首字母串以 `initials` 开头的 key（`nh` → 你好）。
    pub fn lookup_initials(
        &self,
        initials: &str,
        per_key: usize,
        limit: usize,
    ) -> Vec<PrefixHit<'_>> {
        if initials.is_empty() || limit == 0 {
            return Vec::new();
        }
        let idx = self.initials_index();
        let start = idx.partition_point(|(l, _)| l.as_ref() < initials);
        let mut out = Vec::new();
        for (l, key) in &idx[start..] {
            if !l.starts_with(initials) {
                break;
            }
            if let Some(entries) = self.map.get(key.as_ref()) {
                for entry in entries.iter().take(per_key.max(1)) {
                    out.push(PrefixHit {
                        key: key.as_ref(),
                        entry,
                    });
                    if out.len() >= limit {
                        return out;
                    }
                }
            }
        }
        out
    }

    /// 混拼查询：输入按「整音节 或 首字母」任意混打也能整词命中。
    ///
    /// 例：`nhao`→`ni'hao`（n 为 ni 的首字母，hao 为整音节）、`nh`→`ni'hao`。
    /// 只扫描首字母相同的 key，避免全表遍历；返回词频最高的至多 `limit` 条。
    pub fn lookup_mixed(&self, query: &str, limit: usize) -> Vec<PrefixHit<'_>> {
        if query.len() < 2 || limit == 0 {
            return Vec::new();
        }
        let idx = self.prefix_index();
        let first = &query[..1];
        let start = idx.partition_point(|(l, _)| l.as_ref() < first);
        let mut out: Vec<PrefixHit<'_>> = Vec::new();
        let cap = limit * 4;
        for (l, key) in &idx[start..] {
            if !l.starts_with(first) {
                break;
            }
            if !abbrev_match(query, key) {
                continue;
            }
            if let Some(entry) = self.map.get(key.as_ref()).and_then(|v| v.first()) {
                out.push(PrefixHit {
                    key: key.as_ref(),
                    entry,
                });
                if out.len() >= cap {
                    out.sort_by_key(|h| std::cmp::Reverse(h.entry.freq));
                    out.truncate(limit);
                }
            }
        }
        out.sort_by_key(|h| std::cmp::Reverse(h.entry.freq));
        out.truncate(limit);
        out
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.map.contains_key(key)
    }

    pub fn key_count(&self) -> usize {
        self.map.len()
    }

    pub fn entry_count(&self) -> usize {
        self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries == 0
    }

    /// 合并另一个词典（同 key 同词取较大词频）。
    pub fn merge(&mut self, other: &Dictionary) {
        for (key, list) in &other.map {
            for e in list {
                self.insert(key, &e.word, e.freq);
            }
        }
    }

    /// 只保留词频最高的至多 `max_entries` 条；单音节条目（生僻字输入）始终保留。
    ///
    /// 返回 `(保留单音节数, 保留多音节数)`。
    pub fn prune(&mut self, max_entries: usize) -> (usize, usize) {
        if self.entries <= max_entries {
            return (0, 0);
        }
        let mut singles: Vec<(&String, usize)> = Vec::new();
        let mut multis: Vec<(&String, usize, u32)> = Vec::new();
        for (key, list) in &self.map {
            for (i, _) in list.iter().enumerate() {
                if list[i].syls <= 1 {
                    singles.push((key, i));
                } else {
                    multis.push((key, i, list[i].freq));
                }
            }
        }
        let keep_multi = max_entries.saturating_sub(singles.len());
        multis.sort_by_key(|x| std::cmp::Reverse(x.2));
        multis.truncate(keep_multi);

        let mut kept: std::collections::HashSet<(&str, usize)> =
            std::collections::HashSet::with_capacity(singles.len() + multis.len());
        for (k, i) in &singles {
            kept.insert((k.as_str(), *i));
        }
        for (k, i, _) in &multis {
            kept.insert((k.as_str(), *i));
        }

        let mut new_map: HashMap<String, Vec<Entry>> = HashMap::with_capacity(kept.len() / 2 + 1);
        let mut new_entries = 0usize;
        let mut kept_singles = 0usize;
        let mut kept_multi = 0usize;
        for (key, list) in &self.map {
            let mut filtered = Vec::new();
            for (i, e) in list.iter().enumerate() {
                if kept.contains(&(key.as_str(), i)) {
                    filtered.push(e.clone());
                }
            }
            if !filtered.is_empty() {
                new_entries += filtered.len();
                kept_singles += filtered.iter().filter(|e| e.syls <= 1).count();
                kept_multi += filtered.iter().filter(|e| e.syls > 1).count();
                new_map.insert(key.clone(), filtered);
            }
        }
        self.map = new_map;
        self.entries = new_entries;
        self.prefix = OnceLock::new();
        self.initials = OnceLock::new();
        self.char_pinyin = OnceLock::new();
        self.log_total = OnceLock::new();
        (kept_singles, kept_multi)
    }

    /// 导出为 TSV（`词\t拼音\t词频`），按 key 排序，便于入库与 diff。
    pub fn to_tsv(&self) -> String {
        let mut keys: Vec<&String> = self.map.keys().collect();
        keys.sort();
        let mut out = String::with_capacity(self.entries * 32);
        for key in keys {
            let pinyin = key.replace('\'', " ");
            for e in &self.map[key] {
                out.push_str(&e.word);
                out.push('\t');
                out.push_str(&pinyin);
                out.push('\t');
                out.push_str(&e.freq.to_string());
                out.push('\n');
            }
        }
        out
    }

    /// 确定性序列化（key 排序后写入），便于校验与 diff。
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut keys: Vec<&String> = self.map.keys().collect();
        keys.sort();
        let mut out = Vec::with_capacity(64 + self.entries * 12);
        out.extend_from_slice(&binary::MAGIC);
        binary::write_varint(&mut out, self.entries as u64);
        for key in keys {
            for e in &self.map[key] {
                binary::write_str(&mut out, key);
                binary::write_str(&mut out, &e.word);
                binary::write_varint(&mut out, u64::from(e.freq));
            }
        }
        out
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, DictError> {
        if bytes.len() < 4 || bytes[..4] != binary::MAGIC {
            return Err(DictError::BadMagic);
        }
        let mut pos = 4;
        let count = binary::read_varint(bytes, &mut pos)? as usize;
        let mut dict = Dictionary::new();
        for _ in 0..count {
            let key = binary::read_str(bytes, &mut pos)?;
            let word = binary::read_str(bytes, &mut pos)?;
            let freq = binary::read_varint(bytes, &mut pos)? as u32;
            dict.insert(&key, &word, freq);
        }
        Ok(dict)
    }

    /// 内置基础词典（约 200 条），保证首次可用与测试确定性。
    /// 正式词库用 `xtask dict import-rime` 从 Rime 词库生成。
    pub fn embedded() -> Self {
        import::parse_tsv(include_str!("../data/base.tsv")).0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn demo() -> Dictionary {
        let mut d = Dictionary::new();
        d.insert("ni'hao", "你好", 100);
        d.insert("ni'hao", "泥号", 1);
        d.insert("ni", "你", 500);
        d
    }

    #[test]
    fn lookup_order_and_dedupe() {
        let d = demo();
        let l = d.lookup("ni'hao");
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].word, "你好");
        assert_eq!(l[0].letters, 5);
        assert_eq!(l[0].syls, 2);
        assert_eq!(l[1].word, "泥号");
        assert!(d.lookup("nothing").is_empty());
    }

    #[test]
    fn duplicate_word_keeps_max_freq() {
        let mut d = Dictionary::new();
        d.insert("ni", "你", 1);
        d.insert("ni", "你", 9);
        assert_eq!(d.entry_count(), 1);
        assert_eq!(d.lookup("ni")[0].freq, 9);
    }

    #[test]
    fn binary_roundtrip_is_deterministic() {
        let d = demo();
        let b1 = d.to_bytes();
        let b2 = d.to_bytes();
        assert_eq!(b1, b2);
        let r = Dictionary::from_bytes(&b1).unwrap();
        assert_eq!(r.entry_count(), d.entry_count());
        assert_eq!(r.to_bytes(), b1);
        assert_eq!(r.lookup("ni'hao")[0].word, "你好");
    }

    #[test]
    fn binary_rejects_garbage() {
        assert_eq!(
            Dictionary::from_bytes(b"NOPE").unwrap_err(),
            DictError::BadMagic
        );
        assert_eq!(
            Dictionary::from_bytes(b"IFD1").unwrap_err(),
            DictError::Truncated
        );
    }

    #[test]
    fn merge_keeps_max() {
        let mut a = Dictionary::new();
        a.insert("ni", "你", 5);
        let mut b = Dictionary::new();
        b.insert("ni", "你", 7);
        b.insert("ni", "尼", 3);
        a.merge(&b);
        assert_eq!(a.entry_count(), 2);
        assert_eq!(a.lookup("ni")[0].freq, 7);
    }

    #[test]
    fn prune_keeps_singles_and_top_words() {
        let mut d = Dictionary::new();
        d.insert("ni", "你", 10);
        d.insert("ni'hao", "你好", 100);
        d.insert("ni'hao", "泥号", 1);
        d.insert("wo", "我", 50);
        d.insert("bei'jing", "北京", 90);
        let (singles, multi) = d.prune(3);
        assert_eq!(singles, 2, "单音节始终保留");
        assert_eq!(multi, 1, "多音节按词频取前 1");
        assert_eq!(d.entry_count(), 3);
        assert!(!d.lookup("ni'hao").is_empty());
        assert!(d.lookup("bei'jing").is_empty(), "词频较低的多音节被剪掉");

        let tsv = d.to_tsv();
        assert!(tsv.contains("你\tni\t10"), "{tsv}");
        assert!(tsv.contains("你好\tni hao\t100"), "{tsv}");
    }

    #[test]
    fn prefix_lookup_returns_extensions() {
        let mut d = Dictionary::new();
        d.insert("ni", "你", 500);
        d.insert("ni'hao", "你好", 100);
        d.insert("ni'hai", "你孩", 10);
        d.insert("shi", "是", 900);
        d.insert("ni'hao", "泥号", 1);

        let hits = d.lookup_prefix("nih", 1, 100);
        let words: Vec<&str> = hits.iter().map(|h| h.entry.word.as_str()).collect();
        assert!(words.contains(&"你好"), "{words:?}");
        assert!(words.contains(&"你孩"), "{words:?}");
        assert!(!words.contains(&"你"), "「你」不是 nih 的扩展: {words:?}");

        let multi = d.lookup_prefix("ni", 2, 100);
        let ni_words: Vec<&str> = multi
            .iter()
            .filter(|h| h.key == "ni")
            .map(|h| h.entry.word.as_str())
            .collect();
        assert_eq!(ni_words.first().copied(), Some("你"));
        assert!(!multi.iter().any(|h| h.key == "shi"));

        assert!(d.lookup_prefix("zzz", 1, 100).is_empty());
    }

    #[test]
    fn initials_and_mixed_lookup() {
        let mut d = Dictionary::new();
        d.insert("ni'hao", "你好", 100);
        d.insert("ni'hao'ma", "你好吗", 50);
        d.insert("nan'hai", "男孩", 40);
        d.insert("bei'jing", "北京", 90);

        let hits = d.lookup_initials("nh", 1, 100);
        let words: Vec<&str> = hits.iter().map(|h| h.entry.word.as_str()).collect();
        assert!(words.contains(&"你好"), "{words:?}");
        assert!(words.contains(&"你好吗"), "{words:?}");
        assert!(words.contains(&"男孩"), "{words:?}");

        let mixed = d.lookup_mixed("nhao", 100);
        let words: Vec<&str> = mixed.iter().map(|h| h.entry.word.as_str()).collect();
        assert!(words.contains(&"你好"), "{words:?}");
        assert!(!words.contains(&"北京"), "{words:?}");

        // 混拼要求整词命中：`nh` 不会命中「你好吗」（还有未匹配的音节）
        assert!(
            !d.lookup_mixed("nh", 100)
                .iter()
                .any(|h| h.entry.word == "你好吗")
        );

        // 全首字母也能作为混拼整词命中，且不跨首字母扫描
        let bj = d.lookup_mixed("bj", 100);
        assert!(bj.iter().any(|h| h.entry.word == "北京"), "bj 应命中北京");
        assert!(!bj.iter().any(|h| h.entry.word == "你好"));
    }

    #[test]
    fn embedded_dict_is_clean_and_useful() {
        let (d, report) = import::parse_tsv(include_str!("../data/base.tsv"));
        assert_eq!(report.skipped, 0, "内置词典有非法行: {:?}", report.errors);
        assert!(report.imported > 150);
        assert_eq!(d.lookup("ni'hao")[0].word, "你好");
        assert!(!d.lookup("wo'men").is_empty());
    }
}
