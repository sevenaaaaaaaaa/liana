//! 生成一张示例卡片（HTML + Markdown），用于肉眼检查排版。
//!
//! 跑：cargo run -p liana-card --example preview -- /tmp/liana-card

use liana_card::{Card, Item};
use std::path::PathBuf;

fn main() -> std::io::Result<()> {
    let out: PathBuf = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/liana-card"));
    std::fs::create_dir_all(&out)?;

    let card = Card {
        kicker: Some("晚间工作计划".into()),
        title: "今晚待办：对账清点与投放盘点".into(),
        lead: Some(
            "三件事按先后顺序做：先注册后台，再清点 8-10 月票据，最后盘点日韩投放计划。".into(),
        ),
        items: vec![
            Item {
                index: 1,
                title: "注册 Twitter 广告后台".into(),
                note: Some("今晚的起点，最先做".into()),
                tags: vec![],
                goal: Some("完成 Twitter 广告后台注册，为后续投放做准备。".into()),
                body: None,
            },
            Item {
                index: 2,
                title: "清点代理商票据".into(),
                note: Some("按代理商逐个核".into()),
                tags: vec!["8-10 月".into(), "对账单".into(), "发票".into()],
                goal: Some("弄清还差多少：按代理商逐个核对，每月分对账单、发票两类。".into()),
                body: None,
            },
            Item {
                index: 3,
                title: "盘点日韩投放计划".into(),
                note: Some("逐个平台核对".into()),
                tags: vec!["日本".into(), "韩国".into()],
                goal: None,
                body: None,
            },
        ],
        transcript: vec![
            "我认为我今天晚上应该：".into(),
            "1. 先把推特广告后台注册了；".into(),
            "2. 捋一下到底还有多少个代理商 8 月、9 月、10 月的对账单和发票没有弄好；".into(),
            "3. 捋一下日本和韩国的平台还有哪些投放计划没有做。".into(),
        ],
        meta: Some("2026-11-15 · 转写 12 分 04 秒 · 全程本机".into()),
    };

    std::fs::write(out.join("preview.html"), card.to_html())?;
    std::fs::write(out.join("preview.md"), card.to_markdown())?;
    println!("blocks: {}", card.blocks().len());
    println!("html:   {}", out.join("preview.html").display());
    println!("md:     {}", out.join("preview.md").display());
    Ok(())
}
