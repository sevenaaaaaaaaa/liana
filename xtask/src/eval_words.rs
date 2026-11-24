//! `xtask eval-words`：词级假名 → 汉字（M1.5 验收口径之一）。
//!
//! 语料每行：读音 <TAB> 期望词形 <TAB> 词性
//! 测「单独打一个词，首选是否就是原词形」；不测上下文——上下文由
//! `eval-corpus --lang ja` 的整句口径测。

use std::collections::BTreeMap;

pub fn run(args: &[String]) -> Result<(), String> {
    let mut path = "xtask/data/corpus/liana-ja-words.tsv".to_string();
    let mut show = 15usize;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--words" => path = args.get(i + 1).ok_or("--words 缺值")?.clone(),
            "--show" => {
                show = args
                    .get(i + 1)
                    .ok_or("--show 缺值")?
                    .parse()
                    .map_err(|_| "--show 需要数字")?
            }
            other => return Err(format!("未知参数: {other}")),
        }
        i += 2;
    }

    let src = std::fs::read_to_string(&path).map_err(|e| format!("读不到 {path}: {e}（请在仓库根目录运行）"))?;
    let mut n = 0usize;
    let mut top1 = 0usize;
    let mut top3 = 0usize;
    let mut by_pos: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    let mut misses: Vec<String> = Vec::new();

    for line in src.lines() {
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 2 {
            continue;
        }
        let (reading, expected) = (cols[0], cols[1]);
        let pos = cols.get(2).copied().unwrap_or("?");
        if reading.is_empty() || expected.is_empty() {
            continue;
        }
        let cands = liana_ja::decode_kana(reading);
        let got = cands.first().map(|c| c.text.as_str()).unwrap_or("");
        // 词形正确，或该词在词典里也允许假名书写（uk 词，如 居る/いる）且首选就是读音。
        let kana_ok = got == reading && liana_ja::has_surface(reading, reading);
        let hit1 = got == expected || kana_ok;
        let hit3 = hit1 || cands.iter().take(3).any(|c| c.text == expected);
        n += 1;
        if hit1 {
            top1 += 1;
        }
        if hit3 {
            top3 += 1;
        }
        let e = by_pos.entry(pos.to_string()).or_insert((0, 0));
        e.0 += 1;
        if hit1 {
            e.1 += 1;
        }
        if !hit1 && misses.len() < show {
            misses.push(format!("  {reading} → 期望「{expected}」实际「{got}」"));
        }
    }
    if n == 0 {
        return Err(format!("{path} 里没有可用词条"));
    }

    println!("\n═══ 日语词级评测（假名 → 原词形）═══");
    println!(
        "  样本 {n}   Top-1 {:.1}%   Top-3 {:.1}%",
        top1 as f64 / n as f64 * 100.0,
        top3 as f64 / n as f64 * 100.0
    );
    for (pos, (total, hit)) in &by_pos {
        println!(
            "  {pos:<6} {hit:>4}/{total:<4} {:.1}%",
            *hit as f64 / *total as f64 * 100.0
        );
    }
    for m in &misses {
        println!("{m}");
    }
    Ok(())
}
