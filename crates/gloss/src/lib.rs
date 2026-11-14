//! 多语对照翻译：把中文候选翻成英/日/韩/法/德/西/俄一行。
//!
//! 设计取舍与 `liana-zhconv` 一致：**离线、零依赖、纯函数**。
//! 输入法里这一行是「边打边看」的提示，必须本地即时出结果，
//! 不能依赖网络；在线模型只作为可选精修（见 `translate` 的调用方）。
//!
//! 规则：
//! - 拉丁/数字片段（Wi-Fi、PPT、iPhone、5G）原样保留，不二次翻译；
//! - 对照表按**最长匹配**切分，空译文的词（的/了）直接省略；
//! - 查不到的中文原字保留，绝不丢字——宁可半中半外，也不吞用户输入；
//! - 日文不插空格，其余语言按空格连接；西文首字母大写。

use std::collections::HashMap;
use std::sync::OnceLock;

/// 中文<TAB>en<TAB>ja<TAB>ko<TAB>fr<TAB>de<TAB>es<TAB>ru
const TABLE: &str = include_str!("../../dict/data/glossary/multilang.tsv");
const COLUMNS: usize = 7;

/// 支持的输出语言，顺序与数据列一致。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Lang {
    En,
    Ja,
    Ko,
    Fr,
    De,
    Es,
    Ru,
}

impl Lang {
    pub const ALL: [Lang; 7] = [Lang::En, Lang::Ja, Lang::Ko, Lang::Fr, Lang::De, Lang::Es, Lang::Ru];

    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Ja => "ja",
            Lang::Ko => "ko",
            Lang::Fr => "fr",
            Lang::De => "de",
            Lang::Es => "es",
            Lang::Ru => "ru",
        }
    }

    pub fn from_code(code: &str) -> Option<Lang> {
        Lang::ALL.into_iter().find(|lang| lang.code().eq_ignore_ascii_case(code))
    }

    fn column(self) -> usize {
        match self {
            Lang::En => 0,
            Lang::Ja => 1,
            Lang::Ko => 2,
            Lang::Fr => 3,
            Lang::De => 4,
            Lang::Es => 5,
            Lang::Ru => 6,
        }
    }

    /// 日文不用空格分词；其余语言用空格连接。
    fn spaced(self) -> bool {
        !matches!(self, Lang::Ja)
    }

    /// 是否需要把首字母大写（西文），中日韩保持原样。
    fn capitalizes(self) -> bool {
        matches!(self, Lang::En | Lang::Fr | Lang::De | Lang::Es | Lang::Ru)
    }
}

pub struct Glossary {
    map: HashMap<&'static str, [&'static str; COLUMNS]>,
    max_len: usize,
}

impl Glossary {
    /// 进程内单例：解析一次，之后全部走哈希查找。
    pub fn shared() -> &'static Glossary {
        static INSTANCE: OnceLock<Glossary> = OnceLock::new();
        INSTANCE.get_or_init(Glossary::parse)
    }

    fn parse() -> Glossary {
        let mut map = HashMap::new();
        let mut max_len = 1;
        for line in TABLE.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&'static str> = line.split('\t').collect();
            if fields.len() < 1 + COLUMNS {
                continue;
            }
            let zh = fields[0];
            if zh.is_empty() {
                continue;
            }
            let mut texts = [""; COLUMNS];
            texts.copy_from_slice(&fields[1..1 + COLUMNS]);
            max_len = max_len.max(zh.chars().count());
            map.insert(zh, texts);
        }
        Glossary { map, max_len }
    }

    /// 对照表里最长的中文词长度（按字符数）。
    pub fn max_term_len(&self) -> usize {
        self.max_len
    }

    pub fn lookup(&self, term: &str) -> Option<[&'static str; COLUMNS]> {
        self.map.get(term).copied()
    }

    /// 中文 → 目标语言一行。返回空串表示没有可翻译内容。
    pub fn translate(&self, zh: &str, lang: Lang) -> String {
        let chars: Vec<char> = zh.trim().chars().collect();
        if chars.is_empty() {
            return String::new();
        }
        let column = lang.column();
        let mut pieces: Vec<String> = Vec::new();
        let mut pending = String::new();
        let mut index = 0;

        while index < chars.len() {
            let character = chars[index];
            if is_latin_token(character) {
                let mut end = index;
                while end < chars.len() && is_latin_token(chars[end]) {
                    end += 1;
                }
                flush(&mut pending, &mut pieces);
                pieces.push(chars[index..end].iter().collect());
                index = end;
                continue;
            }
            let reach = (chars.len() - index).min(self.max_len);
            let mut matched = false;
            for length in (1..=reach).rev() {
                let candidate: String = chars[index..index + length].iter().collect();
                if let Some(texts) = self.map.get(candidate.as_str()) {
                    flush(&mut pending, &mut pieces);
                    let text = texts[column];
                    if !text.is_empty() {
                        pieces.push(text.to_string());
                    }
                    index += length;
                    matched = true;
                    break;
                }
            }
            if !matched {
                pending.push(character);
                index += 1;
            }
        }
        flush(&mut pending, &mut pieces);

        let separator = if lang.spaced() { " " } else { "" };
        let mut output = pieces.join(separator);
        while output.contains("  ") {
            output = output.replace("  ", " ");
        }
        let output = output.trim().to_string();
        if output.is_empty() {
            return output;
        }
        if !lang.capitalizes() {
            return output;
        }
        let mut chars = output.chars();
        match chars.next() {
            Some(first) if first.is_alphabetic() && first.is_ascii() => {
                first.to_uppercase().collect::<String>() + chars.as_str()
            }
            _ => output,
        }
    }
}

fn flush(pending: &mut String, pieces: &mut Vec<String>) {
    if !pending.is_empty() {
        pieces.push(std::mem::take(pending));
    }
}

fn is_latin_token(character: char) -> bool {
    character.is_ascii()
        && (character.is_alphanumeric() || matches!(character, '-' | '_' | '.' | '+' | '#'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tr(zh: &str, lang: Lang) -> String {
        Glossary::shared().translate(zh, lang)
    }

    #[test]
    fn mixed_latin_survives_every_language() {
        for lang in Lang::ALL {
            let out = tr("我家的Wi-Fi密码是", lang);
            assert!(!out.is_empty(), "{:?} 不该为空", lang);
            assert!(out.contains("Wi-Fi"), "{:?} 丢了 Wi-Fi: {}", lang, out);
        }
    }

    #[test]
    fn english_orders_by_glossary_phrase() {
        assert_eq!(tr("我家的Wi-Fi密码是", Lang::En), "My home Wi-Fi password is");
    }

    #[test]
    fn japanese_has_no_spaces() {
        let out = tr("我家的Wi-Fi密码是", Lang::Ja);
        assert_eq!(out, "私の家のWi-Fiパスワードは");
        assert!(!out.contains(' '));
    }

    #[test]
    fn korean_and_cyrillic_render() {
        assert_eq!(tr("密码是", Lang::Ko), "비밀번호는");
        assert_eq!(tr("密码是", Lang::Ru), "пароль");
    }

    #[test]
    fn function_words_are_dropped() {
        assert_eq!(tr("我的", Lang::En), "我");
        assert_eq!(tr("的", Lang::En), "");
    }

    #[test]
    fn unknown_words_are_kept() {
        let out = tr("饕餮纹", Lang::En);
        assert_eq!(out, "饕餮纹");
    }

    #[test]
    fn every_language_has_its_own_column() {
        let mut seen = std::collections::HashSet::new();
        for lang in Lang::ALL {
            seen.insert(tr("今天天气很好", lang));
        }
        assert!(seen.len() >= 3, "至少三种语言输出应互不相同: {:?}", seen);
    }
}
