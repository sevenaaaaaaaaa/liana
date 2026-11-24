//! 韩语输入：2-beolsik（두벌식）直打 + Hangul 音节组合。
//!
//! 键位是标准 2-beolsik：q=ㅂ w=ㅈ e=ㄷ r=ㄱ t=ㅅ ...（Shift 出紧音/ㅒㅖ）。
//! 组合规则覆盖初声/中声/终声、双初声（ㄲㄸㅃㅆㅉ）、复合终声（ㄳㄵㄶㄺ...）
//! 与复合中声（ㅘㅙㅚㅝㅞㅟㅢ）。终声后接元音时，终声移到下一音节初声。

use liana_core::{Candidate, CandidateKind, Decoder, FeedPolicy, LanguagePack};

const INITIALS: [char; 19] = [
    'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ',
    'ㅌ', 'ㅍ', 'ㅎ',
];
const MEDIALS: [char; 21] = [
    'ㅏ', 'ㅐ', 'ㅑ', 'ㅒ', 'ㅓ', 'ㅔ', 'ㅕ', 'ㅖ', 'ㅗ', 'ㅘ', 'ㅙ', 'ㅚ', 'ㅛ', 'ㅜ', 'ㅝ', 'ㅞ',
    'ㅟ', 'ㅠ', 'ㅡ', 'ㅢ', 'ㅣ',
];
const FINALS: [char; 28] = [
    '\0', 'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ', 'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ', 'ㄾ', 'ㄿ', 'ㅀ',
    'ㅁ', 'ㅂ', 'ㅄ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

fn index_of(table: &[char], c: char) -> Option<usize> {
    table.iter().position(|x| *x == c)
}

#[derive(Clone, Copy)]
enum Jamo {
    Consonant(usize),
    Vowel(usize),
}

/// 2-beolsik 键位。Shift 键出紧音与 ㅒ/ㅖ。
fn key(ch: char) -> Option<Jamo> {
    let c = match ch {
        'q' => 'ㅂ', 'w' => 'ㅈ', 'e' => 'ㄷ', 'r' => 'ㄱ', 't' => 'ㅅ',
        'y' => 'ㅛ', 'u' => 'ㅕ', 'i' => 'ㅑ', 'o' => 'ㅐ', 'p' => 'ㅔ',
        'a' => 'ㅁ', 's' => 'ㄴ', 'd' => 'ㅇ', 'f' => 'ㄹ', 'g' => 'ㅎ',
        'h' => 'ㅗ', 'j' => 'ㅓ', 'k' => 'ㅏ', 'l' => 'ㅣ',
        'z' => 'ㅋ', 'x' => 'ㅌ', 'c' => 'ㅊ', 'v' => 'ㅍ',
        'b' => 'ㅠ', 'n' => 'ㅜ', 'm' => 'ㅡ',
        'Q' => 'ㅃ', 'W' => 'ㅉ', 'E' => 'ㄸ', 'R' => 'ㄲ', 'T' => 'ㅆ',
        'O' => 'ㅒ', 'P' => 'ㅖ',
        _ => return None,
    };
    if let Some(i) = index_of(&INITIALS, c) {
        Some(Jamo::Consonant(i))
    } else {
        index_of(&MEDIALS, c).map(Jamo::Vowel)
    }
}

/// 双初声：ㄱ+ㄱ→ㄲ 等。返回合成后的初声下标。
fn combine_initial(a: usize, b: usize) -> Option<usize> {
    let pair = (INITIALS[a], INITIALS[b]);
    let c = match pair {
        ('ㄱ', 'ㄱ') => 'ㄲ',
        ('ㄷ', 'ㄷ') => 'ㄸ',
        ('ㅂ', 'ㅂ') => 'ㅃ',
        ('ㅅ', 'ㅅ') => 'ㅆ',
        ('ㅈ', 'ㅈ') => 'ㅉ',
        _ => return None,
    };
    index_of(&INITIALS, c)
}

/// 复合终声：ㄱ+ㅅ→ㄳ 等。返回终声下标。
fn combine_final(a: usize, b: usize) -> Option<usize> {
    if a == 0 {
        return None;
    }
    let pair = (FINALS[a], INITIALS[b]);
    let c = match pair {
        ('ㄱ', 'ㅅ') => 'ㄳ',
        ('ㄴ', 'ㅈ') => 'ㄵ',
        ('ㄴ', 'ㅎ') => 'ㄶ',
        ('ㄹ', 'ㄱ') => 'ㄺ',
        ('ㄹ', 'ㅁ') => 'ㄻ',
        ('ㄹ', 'ㅂ') => 'ㄼ',
        ('ㄹ', 'ㅅ') => 'ㄽ',
        ('ㄹ', 'ㅌ') => 'ㄾ',
        ('ㄹ', 'ㅍ') => 'ㄿ',
        ('ㄹ', 'ㅎ') => 'ㅀ',
        ('ㅂ', 'ㅅ') => 'ㅄ',
        _ => return None,
    };
    index_of(&FINALS, c)
}

/// 复合中声：ㅗ+ㅏ→ㅘ 等。返回中声下标。
fn combine_medial(a: usize, b: usize) -> Option<usize> {
    let pair = (MEDIALS[a], MEDIALS[b]);
    let c = match pair {
        ('ㅗ', 'ㅏ') => 'ㅘ',
        ('ㅗ', 'ㅐ') => 'ㅙ',
        ('ㅗ', 'ㅣ') => 'ㅚ',
        ('ㅜ', 'ㅓ') => 'ㅝ',
        ('ㅜ', 'ㅔ') => 'ㅞ',
        ('ㅜ', 'ㅣ') => 'ㅟ',
        ('ㅡ', 'ㅣ') => 'ㅢ',
        _ => return None,
    };
    index_of(&MEDIALS, c)
}

/// 终声下标 → 初声下标（终声后接元音时，终声移到下一音节）。
fn final_to_initial(f: usize) -> usize {
    match FINALS[f] {
        'ㄱ' => 0, 'ㄲ' => 1, 'ㄴ' => 2, 'ㄷ' => 3, 'ㄹ' => 5, 'ㅁ' => 6,
        'ㅂ' => 7, 'ㅅ' => 9, 'ㅆ' => 10, 'ㅇ' => 11, 'ㅈ' => 12, 'ㅊ' => 14,
        'ㅋ' => 15, 'ㅌ' => 16, 'ㅍ' => 17, 'ㅎ' => 18,
        _ => 11,
    }
}

/// 复合终声拆成 (留在本音节的终声, 移到下一音节初声的辅音)。
fn split_final(f: usize) -> Option<(usize, usize)> {
    let pair = match FINALS[f] {
        'ㄳ' => ('ㄱ', 'ㅅ'), 'ㄵ' => ('ㄴ', 'ㅈ'), 'ㄶ' => ('ㄴ', 'ㅎ'),
        'ㄺ' => ('ㄹ', 'ㄱ'), 'ㄻ' => ('ㄹ', 'ㅁ'), 'ㄼ' => ('ㄹ', 'ㅂ'),
        'ㄽ' => ('ㄹ', 'ㅅ'), 'ㄾ' => ('ㄹ', 'ㅌ'), 'ㄿ' => ('ㄹ', 'ㅍ'),
        'ㅀ' => ('ㄹ', 'ㅎ'), 'ㅄ' => ('ㅂ', 'ㅅ'),
        _ => return None,
    };
    Some((index_of(&FINALS, pair.0)?, index_of(&INITIALS, pair.1)?))
}

#[derive(Default)]
struct Composer {
    ini: Option<usize>,
    med: Option<usize>,
    fin: usize,
    out: String,
}

impl Composer {
    fn has_syllable(&self) -> bool {
        self.ini.is_some()
    }

    fn flush(&mut self) {
        let (Some(ini), Some(med)) = (self.ini, self.med) else {
            self.ini = None;
            self.med = None;
            self.fin = 0;
            return;
        };
        let code = 0xAC00 + ((ini * 21 + med) as u32) * 28 + self.fin as u32;
        if let Some(ch) = char::from_u32(code) {
            self.out.push(ch);
        }
        self.ini = None;
        self.med = None;
        self.fin = 0;
    }

    fn consonant(&mut self, c: usize) {
        match (self.ini, self.med) {
            (None, _) => {
                self.ini = Some(c);
            }
            (Some(ini), None) => {
                if let Some(double) = combine_initial(ini, c) {
                    self.ini = Some(double);
                } else {
                    self.fin = index_of(&FINALS, INITIALS[c]).unwrap_or(0);
                    self.med = Some(20);
                    // 只有初声、还没中声时不能成音节；先记下终声候选，
                    // 等元音到来再决定（这里把中声留空，flush 会丢弃）。
                    self.med = None;
                    self.ini = Some(ini);
                    self.fin = index_of(&FINALS, INITIALS[c]).unwrap_or(0);
                }
            }
            (Some(_), Some(_)) => {
                if self.fin == 0 {
                    self.fin = index_of(&FINALS, INITIALS[c]).unwrap_or(0);
                } else if let Some(complex) = combine_final(self.fin, c) {
                    self.fin = complex;
                } else {
                    self.flush();
                    self.ini = Some(c);
                }
            }
        }
    }

    fn vowel(&mut self, v: usize) {
        match (self.ini, self.med) {
            (None, _) => {
                self.ini = Some(11); // ㅇ
                self.med = Some(v);
            }
            (Some(_), None) => {
                self.med = Some(v);
            }
            (Some(_), Some(med)) => {
                if self.fin == 0 {
                    if let Some(complex) = combine_medial(med, v) {
                        self.med = Some(complex);
                    } else {
                        self.flush();
                        self.ini = Some(11);
                        self.med = Some(v);
                    }
                } else {
                    // 终声后接元音：终声移到下一音节初声
                    let fin = self.fin;
                    if let Some((keep, next)) = split_final(fin) {
                        self.fin = keep;
                        self.flush();
                        self.ini = Some(next);
                        self.med = Some(v);
                    } else {
                        self.fin = 0;
                        self.flush();
                        self.ini = Some(final_to_initial(fin));
                        self.med = Some(v);
                    }
                }
            }
        }
    }

    fn finish(mut self) -> String {
        self.flush();
        self.out
    }
}

/// 2-beolsik 键串 → Hangul。
pub fn compose(keys: &str) -> String {
    let mut c = Composer::default();
    for ch in keys.chars() {
        match key(ch) {
            Some(Jamo::Consonant(i)) => c.consonant(i),
            Some(Jamo::Vowel(v)) => c.vowel(v),
            None => {}
        }
    }
    c.finish()
}

pub struct KoDecoder;

impl Decoder for KoDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        if input.is_empty() || !input.chars().all(|c| c.is_ascii_alphabetic()) {
            return Vec::new();
        }
        let hangul = compose(input);
        let consumed = input.chars().count();
        let mut out = vec![Candidate::new(
            hangul.clone(),
            consumed,
            CandidateKind::Word,
            10.0,
        )];
        let jamo: String = input
            .chars()
            .map(|ch| match key(ch) {
                Some(Jamo::Consonant(i)) => INITIALS[i],
                Some(Jamo::Vowel(v)) => MEDIALS[v],
                None => ch,
            })
            .collect();
        if jamo != hangul {
            out.push(
                Candidate::new(jamo, consumed, CandidateKind::Kana, 5.0).with_comment("자모"),
            );
        }
        out
    }
}

pub struct KoreanPack;

impl LanguagePack for KoreanPack {
    fn id(&self) -> &'static str {
        "ko"
    }

    fn label(&self) -> &'static str {
        "한국어"
    }

    fn feed_policy(&self) -> FeedPolicy {
        FeedPolicy::Ascii
    }

    fn decode(&self, input: &str) -> Vec<Candidate> {
        KoDecoder.decode(input)
    }

    fn preedit(&self, input: &str) -> String {
        compose(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_syllable() {
        assert_eq!(compose("rk"), "가");
        assert_eq!(compose("sk"), "나");
        assert_eq!(compose("dk"), "아");
    }

    #[test]
    fn batchim_syllable() {
        assert_eq!(compose("rka"), "감");
        assert_eq!(compose("rkqt"), "값");
        assert_eq!(compose("rkt"), "갓");
    }

    #[test]
    fn common_words() {
        assert_eq!(compose("dkssud"), "안녕");
        assert_eq!(compose("gksrmf"), "한글");
        assert_eq!(compose("dmlfl"), "의리");
    }

    #[test]
    fn shifted_double_consonant() {
        assert_eq!(compose("Rk"), "까");
        assert_eq!(compose("Tk"), "싸");
    }

    #[test]
    fn complex_medial() {
        assert_eq!(compose("rhk"), "과");
        assert_eq!(compose("dhk"), "와");
        assert_eq!(compose("dnj"), "워");
    }

    #[test]
    fn final_moves_to_next_syllable() {
        assert_eq!(compose("rkaak"), "감마");
        assert_eq!(compose("rkqtdk"), "값아");
    }

    #[test]
    fn vowel_only_starts_with_ieung() {
        assert_eq!(compose("k"), "아");
        assert_eq!(compose("dk"), "아");
    }

    #[test]
    fn double_initial_before_vowel() {
        assert_eq!(compose("rrk"), "까");
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(KoDecoder.decode("").is_empty());
        assert!(compose("").is_empty());
    }

    #[test]
    fn non_ascii_is_rejected() {
        assert!(KoDecoder.decode("한").is_empty());
    }

    #[test]
    fn pack_preedit_and_id() {
        let p = KoreanPack;
        assert_eq!(p.id(), "ko");
        assert_eq!(p.preedit("dkssud"), "안녕");
        assert_eq!(p.feed_policy(), FeedPolicy::Ascii);
        let c = p.decode("dkssud");
        assert_eq!(c[0].text, "안녕");
    }

    #[test]
    fn jamo_fallback_is_listed() {
        let c = KoDecoder.decode("rk");
        assert!(c.iter().any(|x| x.text == "ㄱㅏ"));
    }
}
