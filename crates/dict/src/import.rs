//! 文本导入：自有 TSV 与 Rime `.dict.yaml`。
//!
//! 导入是词典进入系统的唯一入口，因此这里做严格校验（音节合法性），
//! 并把跳过的行报告给用户，而不是静默丢弃。

use liana_core::syllables::is_syllable;

use crate::Dictionary;

#[derive(Debug, Default, Clone)]
pub struct ImportReport {
    pub total: usize,
    pub imported: usize,
    pub skipped: usize,
    /// 最多保留 20 条，避免刷屏
    pub errors: Vec<String>,
}

impl ImportReport {
    pub(crate) fn skip(&mut self, line_no: usize, reason: &str) {
        self.skipped += 1;
        if self.errors.len() < 20 {
            self.errors.push(format!("第 {line_no} 行: {reason}"));
        }
    }
}

/// 把任意拼音写法规范化为 `音节'音节` 形式。
///
/// 支持：空格/单引号/中点/冒号/number 声调/声调符号/`u:` → `v`。
/// 任一首节不合法即返回 `None`。
pub fn normalize_pinyin(s: &str) -> Option<String> {
    let mut syllables: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut chars = s.chars().peekable();

    while let Some(c) = chars.next() {
        if c == 'u' && chars.peek() == Some(&':') {
            chars.next();
            cur.push('v');
            continue;
        }
        let mapped = match c {
            'a'..='z' => Some(c),
            'A'..='Z' => Some(c.to_ascii_lowercase()),
            '0'..='9' => None,
            _ => base_of(c),
        };
        match mapped {
            Some(ch) if ch.is_ascii_alphabetic() => cur.push(ch),
            Some(_) | None => {
                if is_separator(c) || c.is_ascii_digit() {
                    if !cur.is_empty() {
                        syllables.push(std::mem::take(&mut cur));
                    }
                } else {
                    // 声调符号等：既不是字母也不是分隔符，视作忽略
                }
            }
        }
    }
    if !cur.is_empty() {
        syllables.push(cur);
    }
    if syllables.is_empty() {
        return None;
    }

    let mut out = Vec::with_capacity(syllables.len());
    for s in &syllables {
        out.push(canonicalize(s)?);
    }
    Some(out.join("'"))
}

fn is_separator(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\'' | '\u{2019}' | '·' | ':' | '-' | ',' | '/' | '|' | '_'
    )
}

/// 声调符号 → 基础字母（ü 系映射为 v）。
fn base_of(c: char) -> Option<char> {
    Some(match c {
        'ā' | 'á' | 'ǎ' | 'à' => 'a',
        'ē' | 'é' | 'ě' | 'è' | 'ê' => 'e',
        'ī' | 'í' | 'ǐ' | 'ì' => 'i',
        'ō' | 'ó' | 'ǒ' | 'ò' => 'o',
        'ū' | 'ú' | 'ǔ' | 'ù' => 'u',
        'ü' | 'ǖ' | 'ǘ' | 'ǚ' | 'ǜ' => 'v',
        'ń' | 'ň' => 'n',
        'ḿ' | 'm' => 'm',
        _ => return None,
    })
}

/// 统一 ü 写法：lue→lve、nue→nve、jve→jue、yv→yu 等，再校验。
fn canonicalize(s: &str) -> Option<String> {
    let fixed = match s {
        "lue" => "lve",
        "nue" => "nve",
        "jve" => "jue",
        "qve" => "que",
        "xve" => "xue",
        "yve" => "yue",
        "jv" => "ju",
        "qv" => "qu",
        "xv" => "xu",
        "yv" => "yu",
        other => other,
    };
    if is_syllable(fixed) {
        Some(fixed.to_string())
    } else {
        None
    }
}

/// 自有 TSV：`词\t拼音\t词频(可选)`；`#` 开头为注释。
pub fn parse_tsv(s: &str) -> (Dictionary, ImportReport) {
    let mut dict = Dictionary::new();
    let mut report = ImportReport::default();
    for (i, raw) in s.lines().enumerate() {
        let line_no = i + 1;
        let line = raw.trim_end_matches(['\r', '\n']);
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        report.total += 1;
        let mut fields = line.split('\t');
        let (Some(word), Some(pinyin)) = (fields.next(), fields.next()) else {
            report.skip(line_no, "缺少制表符分隔的「词/拼音」两列");
            continue;
        };
        let word = word.trim();
        if word.is_empty() {
            report.skip(line_no, "词为空");
            continue;
        }
        let Some(key) = normalize_pinyin(pinyin) else {
            report.skip(line_no, "拼音含非法音节");
            continue;
        };
        let freq = fields
            .next()
            .and_then(|f| f.trim().parse::<u32>().ok())
            .filter(|f| *f > 0)
            .unwrap_or(1);
        dict.insert(&key, word, freq);
        report.imported += 1;
    }
    (dict, report)
}

/// 词表：一行一个词，可选「词<TAB>拼音<TAB>词频」；拼音留空时按 `base` 自动注音，
/// 没写词频时用 `default_freq`。返回只含这些词的小词典（之后与基础词库合并）。
pub fn parse_word_list(
    s: &str,
    base: &Dictionary,
    default_freq: u32,
) -> (Dictionary, ImportReport) {
    let mut dict = Dictionary::new();
    let mut report = ImportReport::default();
    let mut pending: Vec<(usize, &str, u32)> = Vec::new();
    for (i, raw) in s.lines().enumerate() {
        let line_no = i + 1;
        let line = raw.trim_end_matches(['\r', '\n']);
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        report.total += 1;
        let mut fields = line.split('\t');
        let word = fields.next().unwrap_or("").trim();
        if word.is_empty() {
            report.skip(line_no, "词为空");
            continue;
        }
        let pinyin = fields.next().unwrap_or("").trim();
        let freq = fields
            .next()
            .and_then(|f| f.trim().parse::<u32>().ok())
            .filter(|f| *f > 0)
            .unwrap_or(default_freq);
        if pinyin.is_empty() {
            pending.push((line_no, word, freq));
            continue;
        }
        let Some(key) = normalize_pinyin(pinyin) else {
            report.skip(line_no, "拼音含非法音节");
            continue;
        };
        dict.insert(&key, word, freq);
        report.imported += 1;
    }
    let words: Vec<&str> = pending.iter().map(|(_, w, _)| *w).collect();
    for ((line_no, word, freq), key) in pending.iter().zip(base.annotate(&words)) {
        match key {
            Some(key) => {
                dict.insert(&key, word, *freq);
                report.imported += 1;
            }
            None => report.skip(*line_no, "有字不在词库里，无法自动注音"),
        }
    }
    (dict, report)
}

/// Rime `.dict.yaml` 正文导入。
///
/// 只解析条目行（`词\t拼音\t权重`），跳过 YAML 头部；遇到 `...` 视为进入词库正文后的终止符。
/// 权重做**按文件归一化**（映射到 1..=1_000_000），保证不同词库的权重尺度可比。
pub fn parse_rime_dict(s: &str) -> (Dictionary, ImportReport) {
    let mut report = ImportReport::default();
    let rows = parse_rime_rows(s, &mut report);

    let max = rows.iter().map(|r| r.2).fold(0.0f64, f64::max);
    let mut dict = Dictionary::new();
    for (key, word, weight) in rows {
        let freq = scale_weight(weight, max);
        dict.insert(&key, &word, freq);
        report.imported += 1;
    }
    (dict, report)
}

/// 多个 Rime 词库合并导入：所有来源按**同一全局尺度**归一化，保留作者设计的相对权重。
///
/// `sources` 为 `(名称, 内容, 权重乘数)`；乘数用于拉平来源之间的尺度差异
/// （例如无权重列的词表给一个较小的权重）。
pub fn parse_rime_dicts(sources: &[(String, String, f64)]) -> (Dictionary, ImportReport) {
    let mut report = ImportReport::default();
    let mut rows: Vec<(String, String, f64)> = Vec::new();
    for (_name, content, scale) in sources {
        let mut parsed = parse_rime_rows(content, &mut report);
        let factor = if scale.is_finite() && *scale > 0.0 {
            *scale
        } else {
            1.0
        };
        for r in &mut parsed {
            r.2 *= factor;
        }
        rows.extend(parsed);
    }
    let max = rows.iter().map(|r| r.2).fold(0.0f64, f64::max);
    let mut dict = Dictionary::new();
    for (key, word, weight) in rows {
        let freq = scale_weight(weight, max);
        dict.insert(&key, &word, freq);
        report.imported += 1;
    }
    (dict, report)
}

fn scale_weight(weight: f64, max: f64) -> u32 {
    if max <= 0.0 {
        1
    } else {
        ((weight / max) * 1_000_000.0).round().max(1.0) as u32
    }
}

/// 解析 Rime 词库条目为 `(key, word, weight)`；无权重列时默认 1.0。
fn parse_rime_rows(s: &str, report: &mut ImportReport) -> Vec<(String, String, f64)> {
    let mut rows: Vec<(String, String, f64)> = Vec::new();
    // `...` 只有在**本文件已解析到词条**时才视为正文结束（否则是头部结束符）。
    let mut parsed_here = 0usize;

    for (i, raw) in s.lines().enumerate() {
        let line_no = i + 1;
        let line = raw.trim_end_matches(['\r', '\n']);
        if line.trim() == "..." {
            if parsed_here > 0 {
                break;
            }
            continue;
        }
        let trimmed = line.trim();
        if trimmed.is_empty()
            || trimmed.starts_with('#')
            || trimmed.starts_with('%')
            || trimmed.starts_with("---")
            || trimmed.contains(':')
        {
            continue;
        }
        let mut fields = line.split('\t');
        let (Some(word), Some(pinyin)) = (fields.next(), fields.next()) else {
            continue;
        };
        let word = word.trim();
        if word.is_empty() {
            continue;
        }
        report.total += 1;
        parsed_here += 1;

        let Some(key) = normalize_pinyin(pinyin) else {
            report.skip(line_no, "拼音含非法音节");
            continue;
        };
        let weight = fields
            .next()
            .and_then(|w| w.trim().parse::<f64>().ok())
            .filter(|w| w.is_finite() && *w >= 0.0)
            .unwrap_or(1.0);
        rows.push((key, word.to_string(), weight));
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_forms() {
        assert_eq!(normalize_pinyin("ni hao").unwrap(), "ni'hao");
        assert_eq!(normalize_pinyin("ni3 hao3").unwrap(), "ni'hao");
        assert_eq!(normalize_pinyin("nǐ hǎo").unwrap(), "ni'hao");
        assert_eq!(normalize_pinyin("lüe").unwrap(), "lve");
        assert_eq!(normalize_pinyin("lue").unwrap(), "lve");
        assert_eq!(normalize_pinyin("nu:e").unwrap(), "nve");
        assert_eq!(normalize_pinyin("zhong'guo").unwrap(), "zhong'guo");
        assert_eq!(normalize_pinyin("Xi'An").unwrap(), "xi'an");
        assert!(normalize_pinyin("ni xx").is_none());
        assert!(normalize_pinyin("").is_none());
        assert!(normalize_pinyin("123").is_none());
    }

    #[test]
    fn tsv_import_reports_errors() {
        let src = "# 注释\n你好\tni hao\t100\n坏词\tzzz\t5\n缺列\n世界\tshi jie\n";
        let (d, r) = parse_tsv(src);
        assert_eq!(r.total, 4);
        assert_eq!(r.imported, 2);
        assert_eq!(r.skipped, 2);
        assert_eq!(d.lookup("ni'hao").len(), 1);
        assert_eq!(d.lookup("shi'jie")[0].freq, 1);
    }

    #[test]
    fn rime_import_scales_weights() {
        let src = concat!(
            "---\n",
            "name: test\n",
            "version: '1'\n",
            "...\n",
            "你好\tni hao\t100\n",
            "世界\tshi jie\t50\n",
            "北京\tbei jing\t25\n",
        );
        let (d, r) = parse_rime_dict(src);
        assert_eq!(r.imported, 3);
        assert_eq!(r.skipped, 0);
        let nihao = &d.lookup("ni'hao")[0];
        let shijie = &d.lookup("shi'jie")[0];
        let beijing = &d.lookup("bei'jing")[0];
        assert!(nihao.freq > shijie.freq && shijie.freq > beijing.freq);
        assert_eq!(nihao.freq, 1_000_000);
        assert_eq!(beijing.freq, 250_000);
    }

    #[test]
    fn rime_stops_at_vocabulary_section() {
        let src = "你好\tni hao\t10\n...\n无关\twu guan\t999\n";
        let (d, r) = parse_rime_dict(src);
        assert_eq!(r.imported, 1);
        assert!(d.lookup("wu'guan").is_empty());
    }

    #[test]
    fn multi_source_keeps_global_scale() {
        let chars = "这\tzhe\t17648808\n你\tni\t1422192\n";
        let words = "你好\tni hao\t332885\n北京\tbei jing\t1119506\n";
        let rare = "魑魅魍魉\tchi mei wang liang\t100\n";
        let sources = vec![
            ("chars".to_string(), chars.to_string(), 1.0),
            ("words".to_string(), words.to_string(), 1.0),
            ("rare".to_string(), rare.to_string(), 1.0),
        ];
        let (d, r) = parse_rime_dicts(&sources);
        assert_eq!(r.imported, 5);
        let zhe = d.lookup("zhe")[0].freq;
        let ni = d.lookup("ni")[0].freq;
        let nihao = d.lookup("ni'hao")[0].freq;
        assert!(zhe > ni && ni > nihao, "{zhe} {ni} {nihao}");
        assert!(d.lookup("chi'mei'wang'liang")[0].freq < nihao);
    }

    #[test]
    fn multi_source_scale_factor() {
        let a = "甲\tjia\t100\n";
        let b = "乙\tyi\t1\n";
        let sources = vec![
            ("a".to_string(), a.to_string(), 1.0),
            ("b".to_string(), b.to_string(), 500.0),
        ];
        let (d, _) = parse_rime_dicts(&sources);
        assert!(d.lookup("yi")[0].freq > d.lookup("jia")[0].freq);
    }

    #[test]
    fn word_list_annotates_by_known_words() {
        let mut base = Dictionary::new();
        base.insert("yin'hang", "银行", 5000);
        base.insert("zhao'shang", "招商", 800);
        base.insert("yin", "银", 300);
        base.insert("xing", "行", 9000);
        base.insert("hang", "行", 2000);
        base.insert("ding", "钉", 50);
        let src = "# 注释\n招商银行\n钉钉\t\t3000\n飞书\tfei shu\t800\n𠀀字\n";
        let (d, r) = parse_word_list(src, &base, 100);
        assert_eq!(r.imported, 3);
        assert_eq!(r.skipped, 1);
        // 多音字跟着词走：银行读 hang，不是逐字最高频的 xing
        assert_eq!(d.lookup("zhao'shang'yin'hang")[0].word, "招商银行");
        assert_eq!(d.lookup("zhao'shang'yin'hang")[0].freq, 100);
        assert_eq!(d.lookup("ding'ding")[0].freq, 3000);
        assert_eq!(d.lookup("fei'shu")[0].word, "飞书");
    }
}
