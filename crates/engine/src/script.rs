//! 脚本判定：不切模式时，判断用户更可能在打哪种语言。
//!
//! 只处理罗马字输入（拼音 / 日文罗马字 / 英文）。韩文直打、西语重音符不参与
//! 判定——它们的输入字符本身已经说明了语言。
//!
//! 打分是启发式的，但每条都有可测的依据：
//! - 拼音：贪心切分合法音节，覆盖率 = 被音节吃掉的字符 / 总字符；
//! - 日文：罗马字转假名成功给 0.55，假名整词命中词典给 1.0，前缀命中给 0.8；
//! - 英文：整词命中 0.75，前缀命中 0.55。
//! 判定只在「另一门语言明显更高」时切换，且当前语言有 0.1 的先验。

use liana_core::syllables::is_syllable;

pub struct Scores {
    pub zh: f64,
    pub ja: f64,
    pub en: f64,
}

impl Scores {
    pub fn best(&self) -> (&'static str, f64) {
        let mut id = "zh";
        let mut score = self.zh;
        if self.ja > score {
            id = "ja";
            score = self.ja;
        }
        if self.en > score {
            id = "en";
            score = self.en;
        }
        (id, score)
    }

    pub fn get(&self, id: &str) -> f64 {
        match id {
            "zh" => self.zh,
            "ja" => self.ja,
            "en" => self.en,
            _ => 0.0,
        }
    }
}

/// 拼音合法音节的覆盖率：nihon 的 ni 覆盖 2/5；nihao 覆盖 5/5。
pub fn pinyin_coverage(input: &str) -> f64 {
    let s = input.to_ascii_lowercase();
    let bytes = s.as_bytes();
    if bytes.is_empty() {
        return 0.0;
    }
    let mut i = 0usize;
    let mut covered = 0usize;
    while i < bytes.len() {
        let mut hit = 0usize;
        for len in (1..=6.min(bytes.len() - i)).rev() {
            if is_syllable(&s[i..i + len]) {
                hit = len;
                break;
            }
        }
        if hit == 0 {
            break;
        }
        i += hit;
        covered += hit;
    }
    covered as f64 / bytes.len() as f64
}

/// 日文罗马字的可信度：能转成假名，并且假名在词典里有词/前缀。
pub fn ja_confidence(input: &str) -> f64 {
    let Some(kana) = liana_ja::to_hiragana(input) else {
        return 0.0;
    };
    if kana.is_empty() {
        return 0.0;
    }
    // 词典整词命中要比「拼音恰好也能切完」更硬：sensei/gakusei 这类
    // 日文词同时是合法拼音串，只靠覆盖率会误判成中文。
    if liana_ja::has_reading(&kana) {
        1.2
    } else if liana_ja::has_reading_prefix(&kana) {
        0.85
    } else {
        0.55
    }
}

pub fn english_confidence(exact: bool, prefix: bool) -> f64 {
    if exact {
        0.75
    } else if prefix {
        0.55
    } else {
        0.0
    }
}

pub fn detect(input: &str, en_exact: bool, en_prefix: bool) -> Scores {
    Scores {
        zh: pinyin_coverage(input),
        ja: ja_confidence(input),
        en: english_confidence(en_exact, en_prefix),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn japanese_romaji_beats_pinyin_parse() {
        let s = detect("nihon", false, false);
        assert!(s.ja > s.zh + 0.3, "ja={} zh={}", s.ja, s.zh);
        assert_eq!(s.best().0, "ja");
    }

    #[test]
    fn pinyin_sentence_is_not_japanese() {
        let s = detect("nihao", false, false);
        assert_eq!(s.zh, 1.0);
        assert!(s.ja < 0.7, "ja={}", s.ja);
        assert_eq!(s.best().0, "zh");
    }

    #[test]
    fn japanese_sokuon_word_is_detected() {
        let s = detect("gakkou", false, false);
        assert_eq!(s.ja, 1.2);
        assert!(s.ja > s.zh, "ja={} zh={}", s.ja, s.zh);
    }

    #[test]
    fn japanese_word_that_is_also_pinyin_wins() {
        // sensei 既能切成 sen+sei，也是词典里的 せんせい；应判日文。
        let s = detect("sensei", false, false);
        assert!(s.zh > 0.8, "zh={}", s.zh);
        assert!(s.ja > s.zh, "ja={} zh={}", s.ja, s.zh);
        assert_eq!(s.best().0, "ja");
    }

    #[test]
    fn english_word_is_detected() {
        let s = detect("hello", true, true);
        assert_eq!(s.best().0, "en");
    }

    #[test]
    fn pure_pinyin_is_fully_covered() {
        assert_eq!(pinyin_coverage("zhongguo"), 1.0);
        assert_eq!(pinyin_coverage("woxihuanni"), 1.0);
    }

    #[test]
    fn invalid_tail_lowers_pinyin_coverage() {
        assert!(pinyin_coverage("nihon") < 0.6);
        assert!(pinyin_coverage("gakkou") < 0.5);
    }
}
