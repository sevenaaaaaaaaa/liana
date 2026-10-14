//! 临时性能检查：`cargo run --release -p liana-pinyin --example bench`
//! 度量单键解码延迟（延迟预算：P99 < 8ms）。

use std::sync::Arc;
use std::time::Instant;

use liana_dict::Dictionary;
use liana_pinyin::{Layout, PinyinDecoder};

fn main() {
    let dict = match std::env::args().nth(1) {
        Some(path) => {
            let bytes = std::fs::read(&path).expect("读取词典失败");
            Arc::new(Dictionary::from_bytes(&bytes).expect("解析词典失败"))
        }
        None => Arc::new(Dictionary::embedded()),
    };
    eprintln!(
        "词典：{} key / {} 词条",
        dict.key_count(),
        dict.entry_count()
    );
    let inputs = [
        "n",
        "ni",
        "nih",
        "nh",
        "bj",
        "wm",
        "nhao",
        "shi",
        "beij",
        "ni",
        "nihao",
        "beijing",
        "shurufa",
        "zhongguodishehui",
        "woxihuanni",
        "jintiantianqizenmeyang",
        "shuangpinshurufabukeyongle",
    ];
    for layout in [
        Layout::Full,
        Layout::Shuangpin(liana_core::Scheme::Flypy),
    ] {
        for input in inputs {
            let d = PinyinDecoder::new(dict.clone(), layout);
            assert!(!d.candidates(input).is_empty());
            let mut samples = Vec::new();
            for _ in 0..200 {
                let t = Instant::now();
                let _ = d.candidates(input);
                samples.push(t.elapsed().as_secs_f64() * 1000.0);
            }
            samples.sort_by(f64::total_cmp);
            let p50 = samples[samples.len() / 2];
            let p99 = samples[(samples.len() as f64 * 0.99) as usize];
            println!("{layout:?} {input:>22}  p50={p50:6.3}ms  p99={p99:6.3}ms");
        }
    }
}
