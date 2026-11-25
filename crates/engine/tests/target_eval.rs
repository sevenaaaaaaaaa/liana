//! M1 目标语言候选评测：打中文拼音，候选栏末尾应出现用户想要的英文。
//!
//! 这是「打中文出英文」这条通道唯一的评价标准——不是"能不能出候选"，
//! 而是"出的是不是那个词"。语料在 `xtask/data/corpus/target-en.tsv`，
//! 期望值是按「用户会怎么写英文」写的，不是按词表写了什么写的。

use liana_core::types::CandidateKind;
use liana_dict::Dictionary;
use liana_core::Mode;
use liana_engine::Session;
use std::sync::Arc;

const CORPUS: &str = include_str!("../../../xtask/data/corpus/target-en.tsv");
const MIN_TOP1: f64 = 0.70;

/// 用真词库（base-large.tsv，20 万词条）而不是测试用的 base.tsv：
/// 用玩具词典评出来的命中率没有意义——中文首选错了，英文候选自然跟着错。
fn session() -> Session {
    static DICT: std::sync::OnceLock<Arc<Dictionary>> = std::sync::OnceLock::new();
    let dict = DICT.get_or_init(|| {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../dict/data/base-large.tsv");
        let tsv = std::fs::read_to_string(path).expect("读不到 base-large.tsv");
        Arc::new(liana_dict::import::parse_tsv(&tsv).0)
    });
    Session::with_mode(dict.clone(), Mode::Pinyin)
}

fn type_pinyin(s: &mut Session, keys: &str) {
    for ch in keys.chars() {
        s.feed(ch);
    }
}

fn english_candidates(s: &Session) -> Vec<String> {
    s.composition()
        .candidates
        .iter()
        .filter(|c| c.comment.as_deref() == Some("EN") && c.kind != CandidateKind::Literal)
        .map(|c| c.text.to_lowercase())
        .collect()
}

#[test]
fn target_language_hit_rate() {
    let mut total = 0usize;
    let mut hit = 0usize;
    let mut misses: Vec<String> = Vec::new();
    for line in CORPUS.lines() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split('\t');
        let (Some(pinyin), Some(expected)) = (parts.next(), parts.next()) else {
            continue;
        };
        // 期望值可以用 `|` 给多个可接受说法（同义词不该算错），
        // 匹配用包含：候选是 "early morning" 时，用户要的 "morning" 也在里面。
        let wants: Vec<String> = expected
            .split('|')
            .map(|item| item.trim().to_lowercase())
            .filter(|item| !item.is_empty())
            .collect();
        let mut s = session();
        s.set_target_language("en");
        type_pinyin(&mut s, pinyin.trim());
        let english = english_candidates(&s);
        let zh_top = s
            .composition()
            .candidates
            .first()
            .map(|c| c.text.clone())
            .unwrap_or_default();
        total += 1;
        let ok = wants
            .iter()
            .any(|want| english.iter().any(|text| text.contains(want.as_str())));
        if ok {
            hit += 1;
        } else {
            misses.push(format!(
                "{pinyin} → 中文首选「{zh_top}」 期望 {wants:?} 实际 {english:?}"
            ));
        }
    }
    assert!(total >= 25, "语料太小（{total} 条），评测没有意义");
    let rate = hit as f64 / total as f64;
    for line in &misses {
        eprintln!("miss: {line}");
    }
    println!("目标语言候选命中率 {:.1}%（{hit}/{total}）", rate * 100.0);
    assert!(
        rate >= MIN_TOP1,
        "目标语言候选命中率 {:.1}%（{hit}/{total}），低于门槛 {:.0}%",
        rate * 100.0,
        MIN_TOP1 * 100.0
    );
}

/// 打开英文候选不能改变中文首选——这是「不破坏中文输入」的硬约束。
#[test]
fn chinese_top1_is_unchanged() {
    for pinyin in ["nihao", "xiexie", "mingtian", "gongzuo", "shijian"] {
        let mut plain = session();
        type_pinyin(&mut plain, pinyin);
        let before = plain.composition().candidates.first().map(|c| c.text.clone());

        let mut with_target = session();
        with_target.set_target_language("en");
        type_pinyin(&mut with_target, pinyin);
        let after = with_target
            .composition()
            .candidates
            .first()
            .map(|c| c.text.clone());

        assert_eq!(before, after, "{pinyin} 的中文首选被目标语言候选改变了");
        assert!(
            after.is_some_and(|text| text.chars().any(|c| !c.is_ascii())),
            "{pinyin} 的首选应当是中文"
        );
    }
}
