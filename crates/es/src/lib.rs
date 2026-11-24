//! 西语输入：把 ASCII 的重音写法合成变音符，并做常用词补全。
//!
//! 输入约定（只用引擎已放行的字符，不要求系统西语键盘）：
//! - 元音/n 后面跟一个单引号：a'→á、e'→é、i'→í、o'→ó、u'→ú、n'→ñ；
//! - u 后面两个单引号：u''→ü；
//! - 其余字符原样保留。这样 nin'o → niño、que' → qué、espan'ol → español。
//!
//! 词表是常用西语词（含变音符），按词频排序做前缀补全；输入本身也作为候选返回，
//! 用户想原样上屏时不用再切模式。

use std::sync::OnceLock;

use liana_core::{Candidate, CandidateKind, Decoder, FeedPolicy, LanguagePack};

const WORDS: &str = include_str!("../data/words.txt");

/// 把后缀单引号合成到前一个字符上。
pub fn compose(input: &str) -> String {
    let mut out: Vec<char> = Vec::with_capacity(input.chars().count());
    for ch in input.chars() {
        if ch == '\'' {
            match out.last_mut() {
                Some(last) => match *last {
                    'a' => *last = 'á',
                    'e' => *last = 'é',
                    'i' => *last = 'í',
                    'o' => *last = 'ó',
                    'u' => *last = 'ú',
                    'n' => *last = 'ñ',
                    'ú' => *last = 'ü',
                    _ => out.push('\''),
                },
                None => out.push('\''),
            }
        } else {
            out.push(ch);
        }
    }
    out.into_iter().collect()
}

pub struct EsDecoder {
    words: Vec<(&'static str, u32)>,
    limit: usize,
}

impl EsDecoder {
    pub fn embedded() -> &'static EsDecoder {
        static D: OnceLock<EsDecoder> = OnceLock::new();
        D.get_or_init(EsDecoder::parse)
    }

    fn parse() -> EsDecoder {
        let mut words: Vec<(&'static str, u32)> = WORDS
            .lines()
            .filter_map(|line| {
                let mut it = line.split('\t');
                let w = it.next()?.trim();
                let f = it.next().and_then(|x| x.trim().parse::<u32>().ok()).unwrap_or(999);
                (!w.is_empty()).then_some((w, f))
            })
            .collect();
        words.sort_by_key(|(_, f)| *f);
        EsDecoder { words, limit: 8 }
    }

    pub fn len(&self) -> usize {
        self.words.len()
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    fn candidates(&self, input: &str) -> Vec<Candidate> {
        if input.is_empty() {
            return Vec::new();
        }
        let text = compose(input);
        let lower = text.to_lowercase();
        let consumed = input.chars().count();
        let mut out: Vec<Candidate> = Vec::new();
        for (w, freq) in &self.words {
            if w.starts_with(&lower) {
                let score = 100.0 - (*freq).min(99) as f64;
                out.push(Candidate::new(*w, consumed, CandidateKind::Word, score));
                if out.len() >= self.limit {
                    break;
                }
            }
        }
        if !text.is_empty() && !out.iter().any(|c| c.text == text) {
            out.push(Candidate::new(text, consumed, CandidateKind::Word, 1.0));
        }
        out
    }
}

impl Decoder for EsDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        self.candidates(input)
    }
}

pub struct SpanishPack;

impl LanguagePack for SpanishPack {
    fn id(&self) -> &'static str {
        "es"
    }

    fn label(&self) -> &'static str {
        "Español"
    }

    fn feed_policy(&self) -> FeedPolicy {
        // 允许用户直接粘贴/输入 á é í ó ú ñ ü。
        FeedPolicy::Unicode
    }

    fn decode(&self, input: &str) -> Vec<Candidate> {
        EsDecoder::embedded().candidates(input)
    }

    fn preedit(&self, input: &str) -> String {
        compose(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_accent_vowels() {
        assert_eq!(compose("que'"), "qué");
        assert_eq!(compose("esta'"), "está");
        assert_eq!(compose("si'"), "sí");
    }

    #[test]
    fn suffix_accent_enie() {
        assert_eq!(compose("nin'o"), "niño");
        assert_eq!(compose("espan'ol"), "español");
    }

    #[test]
    fn umlaut_needs_two_quotes() {
        assert_eq!(compose("u'"), "ú");
        assert_eq!(compose("u''"), "ü");
    }

    #[test]
    fn plain_apostrophe_is_kept() {
        assert_eq!(compose("l'"), "l'");
        assert_eq!(compose("'"), "'");
    }

    #[test]
    fn compose_leaves_plain_text_alone() {
        assert_eq!(compose("hola mundo"), "hola mundo");
    }

    #[test]
    fn completion_finds_common_word() {
        let d = EsDecoder::embedded();
        let c = d.decode("qu");
        assert!(c.iter().any(|x| x.text == "que"), "{:?}", c.iter().map(|x| &x.text).collect::<Vec<_>>());
    }

    #[test]
    fn completion_matches_accented_form() {
        let d = EsDecoder::embedded();
        let c = d.decode("que'");
        assert_eq!(c[0].text, "qué");
    }

    #[test]
    fn enie_word_is_completed() {
        let d = EsDecoder::embedded();
        let c = d.decode("nin'o");
        assert_eq!(c[0].text, "niño");
    }

    #[test]
    fn unknown_input_returns_literal() {
        let d = EsDecoder::embedded();
        let c = d.decode("zzz");
        assert!(c.iter().any(|x| x.text == "zzz"));
    }

    #[test]
    fn empty_input_is_empty() {
        let d = EsDecoder::embedded();
        assert!(d.decode("").is_empty());
    }

    #[test]
    fn wordlist_is_not_empty() {
        let d = EsDecoder::embedded();
        assert!(d.len() > 100, "词表 {}", d.len());
    }

    #[test]
    fn pack_metadata() {
        let p = SpanishPack;
        assert_eq!(p.id(), "es");
        assert_eq!(p.label(), "Español");
        assert_eq!(p.feed_policy(), FeedPolicy::Unicode);
        assert_eq!(p.preedit("nin'o"), "niño");
    }
}
