//! 拆字输入：不知道读音时，按部件的拼音拼出汉字。
//!
//! 触发：全拼模式下 `uu` 前缀（`u` 单键已被符号模式占用，`uu` 与符号查询
//! 无冲突——符号查询里 uu 开头的别名极少，且拆字触发优先判定）。
//!
//! 语法：`uu` + 各部件读音（小写全拼，按任意顺序），如：
//! - `uumucun` = 木 + 村 → 树（木子旁 + 对）……实际编码见 RADICALS 表
//! - 匹配规则：候选字的部件读音集合 == 输入部件读音集合（顺序无关）；
//!   允许多打一个部件做模糊召回，但精确匹配排前。
//!
//! 数据：内置常用部件表 + 常用字拆分表（离线，~400 字覆盖日常绝大多数
//! 「不会读」场景——生僻字场景交给系统的笔画输入）。

use std::collections::HashMap;
use std::sync::OnceLock;

use liana_core::{Candidate, CandidateKind, Decoder};

mod data;

pub use data::COMPONENTS;
pub use data::CHARS;

/// 触发前缀（在 engine 的符号触发之前判定）。
pub const TRIGGER: &str = "uu";
/// 单次返回上限。
const MAX_RESULTS: usize = 20;

struct Entry {
    /// 字
    ch: &'static str,
    /// 部件读音（小写全拼，已排序，空格分隔）
    keys: &'static str,
    /// 拆法说明（显示用）：木口 → 呆
    split: &'static str,
}

fn entries() -> &'static [Entry] {
    static ENTRIES: OnceLock<Vec<Entry>> = OnceLock::new();
    ENTRIES.get_or_init(|| {
        CHARS
            .lines()
            .filter_map(|line| {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    return None;
                }
                let mut f = line.split('\t');
                let ch = f.next()?;
                let parts: Vec<&str> = f.next()?.split_whitespace().collect();
                if parts.is_empty() {
                    return None;
                }
                let split = f.next().unwrap_or("");
                let mut keys: Vec<String> = parts
                    .iter()
                    .filter_map(|p| component_key(p))
                    .collect();
                keys.sort();
                if keys.is_empty() {
                    return None;
                }
                let keys = keys.join(" ");
                Some(Entry { ch, keys: Box::leak(keys.into_boxed_str()), split })
            })
            .collect()
    })
}

/// 部件名 → 读音键。别名归一（如「三点水」=「水」）；没有收录的部件返回 None，
/// 该字不参与匹配（保证不会因未知部件产生错误候选）。
fn component_key(name: &str) -> Option<String> {
    static MAP: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    let map = MAP.get_or_init(|| {
        let mut m: HashMap<&'static str, &'static str> = HashMap::new();
        for (key, names) in COMPONENTS {
            m.insert(*key, *key);
            for n in names.split_whitespace() {
                m.insert(n, *key);
            }
        }
        m
    });
    map.get(name).map(|k| (*k).to_string())
}

pub struct RadixDecoder;

impl RadixDecoder {
    /// 直接吃整个按键缓冲（必须以 `uu` 开头），`consumed` 含触发前缀。
    pub fn decode_buffer(&self, buffer: &str) -> Vec<Candidate> {
        let mut it = buffer.chars();
        if it.next() != Some('u') || it.next() != Some('u') {
            return Vec::new();
        }
        let query = it.as_str();
        let consumed = query.chars().count() + 2;
        self.build(query, consumed)
    }

    fn build(&self, query: &str, consumed: usize) -> Vec<Candidate> {
        // 无缝连打形态也认：uuriyue → ri yue（按组件表贪心切段）。
        // 先跑切段：整串往往不是任何部件名（riyue），不能让它提前短路。
        let mut forms: Vec<Vec<String>> = Vec::new();
        if query.chars().all(|c| c.is_ascii_lowercase()) && !query.contains(' ') {
            if let Some(segs) = greedy_segment(query) {
                let mut sorted = segs;
                sorted.sort();
                forms.push(sorted);
            }
        }
        let mut want: Vec<String> = query
            .split_whitespace()
            .filter_map(component_key)
            .collect();
        want.sort();
        if !want.is_empty() && !forms.contains(&want) {
            forms.push(want);
        }
        if forms.is_empty() {
            return Vec::new();
        }

        let mut out: Vec<Candidate> = Vec::new();
        // 精确匹配优先，再模糊（输入集合是候选集合的子集，至多多 1 个部件）
        for exact in [true, false] {
            for e in entries() {
                let keys: Vec<&str> = e.keys.split_whitespace().collect();
                for form in &forms {
                    let hit = if exact {
                        keys.iter().map(|&k| k).eq(form.iter().map(|x| x.as_str()))
                    } else {
                        !exact
                            && keys.len() >= form.len()
                            && form.iter().all(|k| keys.contains(&k.as_str()))
                            && keys.len() - form.len() <= 1
                    };
                    if hit {
                        let label = if e.split.is_empty() {
                            e.keys.to_string()
                        } else {
                            e.split.to_string()
                        };
                        out.push(
                            Candidate::new(e.ch, consumed, CandidateKind::Symbol, 1.0)
                                .with_comment(label),
                        );
                        break;
                    }
                }
                if out.len() >= MAX_RESULTS {
                    break;
                }
            }
            if !out.is_empty() {
                break;
            }
        }
        out
    }
}

/// 贪心切段：按组件表从左到右匹配最长读音（yin → 银；超过 6 字母不成音节则失败）。
fn greedy_segment(query: &str) -> Option<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = query;
    while !rest.is_empty() {
        let mut matched = None;
        for len in (1..=6).rev() {
            if rest.len() >= len {
                let head = &rest[..len];
                if component_key(head).is_some() {
                    matched = Some(head);
                    break;
                }
            }
        }
        let head = matched?;
        out.push(head.to_string());
        rest = &rest[head.len()..];
    }
    (!out.is_empty()).then_some(out)
}

impl Decoder for RadixDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        self.decode_buffer(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(input: &str) -> Vec<String> {
        RadixDecoder.decode_buffer(input).iter().map(|c| c.text.clone()).collect()
    }

    #[test]
    fn trigger_needs_uu() {
        assert!(RadixDecoder.decode_buffer("u").is_empty());
        assert!(RadixDecoder.decode_buffer("umu").is_empty());
        assert!(RadixDecoder.decode_buffer("uu").is_empty(), "空查询不出候选");
    }

    #[test]
    fn char_by_component_names() {
        // 明 = 日 + 月
        let got = texts("uu ri yue");
        assert!(got.iter().any(|t| t == "明"), "{got:?}");
        // 无缝连打
        let got = texts("uuriyue");
        assert!(got.iter().any(|t| t == "明"), "{got:?}");
    }

    #[test]
    fn consumes_trigger_prefix() {
        let c = RadixDecoder.decode_buffer("uu ri yue");
        assert!(c.iter().all(|x| x.consumed == "uu ri yue".chars().count()));
    }

    #[test]
    fn split_comment_shown_fix() {
        let c = RadixDecoder.decode_buffer("uu ri yue");
        assert!(c[0].comment.as_deref().is_some_and(|s| !s.is_empty()));
    }

    #[test]
    fn unknown_component_is_empty() {
        assert!(RadixDecoder.decode_buffer("uuzzz").is_empty());
    }

}

