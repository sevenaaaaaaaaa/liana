//! 内嵌日语词典：jmdict.tsv（读音 → 表记 + 粗词性 + 频率权重）。
//!
//! 解析一次即共享（OnceLock）；词成本在加载时折算为整数：
//!   cost = -ln(weight / Σweight) × 100
//! 与 matrix.bin 的 i16 成本同一量纲，Viterbi 里可以直接相加。
//! 权重来自语料计数 + JMdict 优先标签的伪计数，见 crates/ja/tools/prune_jmdict.py。

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::pos;

pub struct Word {
    pub surface: Box<str>,
    pub pos: u8,
    pub cost: i32,
}

pub struct Dictionary {
    map: HashMap<Box<str>, Vec<Word>>,
    // 排序后的读音表：脚本判定要回答「这个假名前缀有没有词」，
    // HashMap 做不了前缀查询，单开一份排序索引（只在判定时用）。
    keys: Vec<Box<str>>,
    max_len: usize,
    entries: usize,
}

impl Dictionary {
    pub fn parse(tsv: &str) -> Self {
        let mut rows: Vec<(&str, &str, u8, u32)> = Vec::new();
        let mut total = 0f64;
        for line in tsv.lines() {
            let mut it = line.split('\t');
            let (Some(reading), Some(surface), Some(pos_name), Some(weight)) =
                (it.next(), it.next(), it.next(), it.next())
            else {
                continue;
            };
            let Ok(weight) = weight.trim().parse::<u32>() else { continue };
            if reading.is_empty() || surface.is_empty() || weight == 0 {
                continue;
            }
            let pos = pos::id(pos_name).unwrap_or(pos::UNK);
            total += weight as f64;
            rows.push((reading, surface, pos, weight));
        }
        let mut map: HashMap<Box<str>, Vec<Word>> = HashMap::with_capacity(rows.len() / 2);
        let mut max_len = 1usize;
        for (reading, surface, pos, weight) in rows {
            max_len = max_len.max(reading.chars().count());
            let cost = ((total / weight as f64).ln() * 100.0).round() as i32;
            map.entry(reading.into())
                .or_default()
                .push(Word { surface: surface.into(), pos, cost });
        }
        let entries = map.values().map(Vec::len).sum();
        let mut keys: Vec<Box<str>> = map.keys().cloned().collect();
        keys.sort_unstable();
        Self { map, keys, max_len, entries }
    }

    pub fn embedded() -> &'static Dictionary {
        static D: OnceLock<Dictionary> = OnceLock::new();
        D.get_or_init(|| Dictionary::parse(include_str!("../data/jmdict.tsv")))
    }

    pub fn lookup(&self, reading: &str) -> Option<&[Word]> {
        self.map.get(reading).map(|v| v.as_slice())
    }

    /// 词典里是否存在 (读音, 表记) 这一对。评测用：判断假名写法是否也是合法表记。
    pub fn has_surface(&self, reading: &str, surface: &str) -> bool {
        self.lookup(reading).is_some_and(|ws| ws.iter().any(|w| &*w.surface == surface))
    }

    /// 是否存在以 prefix 开头的读音（脚本判定用）。
    pub fn has_prefix(&self, prefix: &str) -> bool {
        let i = self.keys.partition_point(|k| k.as_ref() < prefix);
        self.keys.get(i).is_some_and(|k| k.starts_with(prefix))
    }

    pub fn max_len(&self) -> usize {
        self.max_len
    }

    pub fn entry_count(&self) -> usize {
        self.entries
    }

    pub fn key_count(&self) -> usize {
        self.map.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_dictionary_covers_core_words() {
        let d = Dictionary::embedded();
        assert!(d.entry_count() > 60_000, "条目数 {}", d.entry_count());
        assert!(d.key_count() > 30_000, "读音数 {}", d.key_count());
        let has = |reading: &str, surface: &str| {
            d.lookup(reading).is_some_and(|ws| ws.iter().any(|w| &*w.surface == surface))
        };
        assert!(has("にほん", "日本"));
        assert!(has("がっこう", "学校"));
        assert!(has("たべました", "食べました"));
        assert!(has("こんにちわ", "こんにちは"));
    }

    #[test]
    fn word_cost_is_ordered_by_score() {
        let d = Dictionary::parse("あ\t亜\tNOUN\t10\nあ\t唖\tNOUN\t90\n");
        let ws = d.lookup("あ").unwrap();
        let cheap = ws.iter().find(|w| &*w.surface == "唖").unwrap();
        let dear = ws.iter().find(|w| &*w.surface == "亜").unwrap();
        assert!(cheap.cost < dear.cost);
    }
}
