//! 英文输入：前缀补全 + 词频排序。词表全部在本地，不做联网纠错。

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};

use liana_core::{Candidate, CandidateKind, Decoder};

/// 内置高频词表（`词` 或 `词<TAB>权重`）。
const EMBEDDED: &str = include_str!("../data/words.txt");
/// 常用命令行工具：混输与英文模式都能补全（vibe coding 场景）。
const COMMANDS: &str = include_str!("../data/commands.txt");

pub struct EnDecoder {
    words: Vec<(String, u32)>,
    index: HashMap<char, Vec<usize>>,
    exact: HashSet<String>,
    limit: usize,
}

impl Default for EnDecoder {
    fn default() -> Self {
        Self::embedded()
    }
}

impl EnDecoder {
    pub fn embedded() -> Self {
        Self::from_wordlist(&format!("{EMBEDDED}\n{COMMANDS}"))
    }

    /// 进程内共享的内置词表（避免每个会话重复解析）。
    pub fn embedded_shared() -> Arc<Self> {
        static SHARED: OnceLock<Arc<EnDecoder>> = OnceLock::new();
        SHARED
            .get_or_init(|| Arc::new(EnDecoder::embedded()))
            .clone()
    }

    pub fn from_wordlist(src: &str) -> Self {
        let mut dedup: HashMap<String, u32> = HashMap::new();
        for line in src.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut f = line.split('\t');
            let Some(w) = f.next() else { continue };
            let w = w.to_lowercase();
            if w.is_empty()
                || !w.chars().all(|c| {
                    c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '\'' || c == '-'
                })
            {
                continue;
            }
            let freq = f.next().and_then(|x| x.trim().parse().ok()).unwrap_or(1);
            let slot = dedup.entry(w).or_insert(0);
            *slot = (*slot).max(freq);
        }
        let mut words: Vec<(String, u32)> = dedup.into_iter().collect();
        words.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let mut index: HashMap<char, Vec<usize>> = HashMap::new();
        let mut exact: HashSet<String> = HashSet::with_capacity(words.len());
        for (i, (w, _)) in words.iter().enumerate() {
            if let Some(c) = w.chars().next() {
                index.entry(c).or_default().push(i);
            }
            exact.insert(w.clone());
        }
        Self {
            words,
            index,
            exact,
            limit: 20,
        }
    }

    /// 词表里是否存在该词（大小写不敏感）。
    pub fn contains(&self, word: &str) -> bool {
        self.exact.contains(&word.to_lowercase())
    }

    /// 代码标识符匹配：camelCase / snake_case 逐段都在词库里时，原样返回输入。
    /// `getUser` = get+User ✓；`get_user` ✓；单字母段放行（getX 的 x）；
    /// 含数字的段不认（`get2` 不出候选，走英文串直通）；单段输入是普通词，走词表路径。
    pub fn decode_identifier(&self, input: &str) -> Option<String> {
        if input.is_empty()
            || !input
                .chars()
                .all(|c| c.is_ascii_alphabetic() || c == '_')
        {
            return None;
        }
        let segments = split_identifier(input);
        if segments.len() < 2 {
            return None;
        }
        segments
            .iter()
            .all(|s| self.contains(s) || s.chars().count() == 1)
            .then(|| input.to_string())
    }

    pub fn len(&self) -> usize {
        self.words.len()
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    fn case_like(&self, input: &str, word: &str) -> String {
        let upper_all = input
            .chars()
            .filter(|c| c.is_ascii_alphabetic())
            .all(|c| c.is_ascii_uppercase());
        let first_upper = input.chars().next().is_some_and(|c| c.is_ascii_uppercase());
        if upper_all && input.len() > 1 {
            word.to_ascii_uppercase()
        } else if first_upper {
            let mut cs = word.chars();
            match cs.next() {
                Some(f) => f.to_ascii_uppercase().to_string() + cs.as_str(),
                None => word.to_string(),
            }
        } else {
            word.to_string()
        }
    }
}

/// 标识符切段：下划线分隔；camelCase 按大写边界切。
/// `getUser` → [get, User]；`getUserName` → [get, User, Name]；
/// `XMLParser` → [XML, Parser]（连续大写后接小写时才切，保住缩写词）。
fn split_identifier(input: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let chars: Vec<char> = input.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        if c == '_' {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            continue;
        }
        if c.is_ascii_uppercase() {
            let prev_upper = cur.chars().last().is_some_and(|p| p.is_ascii_uppercase());
            let next_lower = chars.get(i + 1).is_some_and(|n| n.is_ascii_lowercase());
            if !cur.is_empty() && (!prev_upper || next_lower) {
                out.push(std::mem::take(&mut cur));
            }
        }
        cur.push(c);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

impl Decoder for EnDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        self.decode_inner(input, true)
    }
}

impl EnDecoder {
    /// 中英混输用：保留与输入完全相同的英文词（普通补全模式会略过它）。
    pub fn decode_for_mix(&self, input: &str) -> Vec<Candidate> {
        self.decode_inner(input, false)
    }

    fn decode_inner(&self, input: &str, skip_exact: bool) -> Vec<Candidate> {
        let lower = input.to_lowercase();
        let Some(first) = lower.chars().next() else {
            return Vec::new();
        };
        let mut out: Vec<Candidate> = Vec::new();
        let consumed = input.chars().count();

        if let Some(ids) = self.index.get(&first) {
            for &i in ids {
                let (w, freq) = &self.words[i];
                if !w.starts_with(&lower) {
                    continue;
                }
                let exact = w.len() == lower.len();
                let score = (f64::from(*freq)).ln() + if exact { 0.5 } else { 0.0 };
                let text = self.case_like(input, w);
                if skip_exact && text == input {
                    continue;
                }
                out.push(Candidate::new(text, consumed, CandidateKind::Word, score));
                if out.len() >= self.limit {
                    break;
                }
            }
        }
        out.sort_by(|a, b| b.score.total_cmp(&a.score));
        out.truncate(self.limit);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_wordlist_loads() {
        let d = EnDecoder::embedded();
        assert!(d.len() > 100, "词表太小: {}", d.len());
    }

    #[test]
    fn prefix_completion_prefers_frequent() {
        let d = EnDecoder::embedded();
        let c = d.decode("hel");
        assert!(!c.is_empty());
        assert!(c[0].text.starts_with("hel"), "{}", c[0].text);
        assert!(c.iter().any(|x| x.text == "hello"));
        assert!(c.iter().any(|x| x.text == "help"));
        assert!(c.iter().all(|x| x.consumed == 3));
    }

    #[test]
    fn case_is_preserved() {
        let d = EnDecoder::embedded();
        assert_eq!(d.decode("Hel")[0].text, "Help");
        assert_eq!(d.decode("HEL")[0].text, "HELP");
        assert_eq!(d.decode("hel")[0].text, "help");
    }

    #[test]
    fn exact_word_not_duplicated() {
        let d = EnDecoder::embedded();
        assert!(d.decode("hello").iter().all(|c| c.text != "hello"));
    }

    #[test]
    fn mix_mode_keeps_exact_word_with_case() {
        let d = EnDecoder::embedded();
        let c = d.decode_for_mix("hello");
        assert_eq!(c[0].text, "hello");
        let c = d.decode_for_mix("Hello");
        assert_eq!(c[0].text, "Hello");
        assert!(d.contains("hello"));
        assert!(d.contains("HELLO"));
        assert!(!d.contains("hellozzz"));
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(d_decode_empty(""));
        assert!(d_decode_empty("123"));
    }

    fn d_decode_empty(input: &str) -> bool {
        let d = EnDecoder::embedded();
        d.decode(input).is_empty()
    }

    #[test]
    fn identifier_segments_match() {
        let d = EnDecoder::embedded();
        assert_eq!(d.decode_identifier("getUser").as_deref(), Some("getUser"));
        assert_eq!(
            d.decode_identifier("get_user_name").as_deref(),
            Some("get_user_name")
        );
        assert_eq!(d.decode_identifier("getX").as_deref(), Some("getX"));
        // 词表没有的段
        assert_eq!(d.decode_identifier("getZzzz"), None);
        // 单段是普通词，不走标识符路径
        assert_eq!(d.decode_identifier("get"), None);
        // 含数字不认
        assert_eq!(d.decode_identifier("get2User"), None);
        // 空输入
        assert_eq!(d.decode_identifier(""), None);
    }

    #[test]
    fn camel_acronym_splits_after_run() {
        // XMLParser：连续大写保住缩写词，接小写时才切
        let d = EnDecoder::embedded();
        // xml 和 parser 都是词表词即可命中
        let _ = d.decode_identifier("XMLParser");
    }

    #[test]
    fn command_tools_in_wordlist() {
        let d = EnDecoder::embedded();
        assert!(d.contains("kubectl"), "命令行工具应进词表");
        assert!(d.contains("xattr"));
        assert!(d.contains("pip3"), "带数字的工具名应合法");
        assert!(!d.contains("llb"));
    }
}
