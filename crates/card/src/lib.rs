//! 卡片：把结构化内容排成一份可以导出的版式，六端共用。
//!
//! 分工很硬：
//! - **本 crate 只做排版树**：给定内容，产出一串有角色、有层级的 Block。
//!   纯逻辑、零依赖、不碰文件、不算像素。
//! - **导出器**（Markdown / HTML）从同一棵排版树生成，所以几种出口不会
//!   各写一套排版，也就不会互相漂移。
//! - **图片由平台层绘制**：Core Graphics / Android Canvas 照着这棵树画，
//!   字形与圆角交给原生，本 crate 不引入图像库。
//!
//! 颜色取自 iOS 端 LianaPalette 的实际取值（深色底 0x101112 那一组），
//! 也就是用户在手机上真正看到的观感。它与 docs/design-tokens.json 的
//! oklch 定义尚未统一，这里不擅自调和——统一是一次独立的重构。

/// 一套卡片配色。值是 sRGB 十六进制，直接可用于 CSS，也可被平台层的
/// 颜色构造器读取（#RRGGBB 的六位形式）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Theme {
    /// 主题名，只用于自检与导出文件名。
    pub name: &'static str,
    /// 页面底色。
    pub bg: &'static str,
    /// 更深一层的底色，用于页脚与凹陷区。
    pub bg_deep: &'static str,
    /// 卡面。
    pub surface: &'static str,
    /// 卡内的次级填充（标签胶囊、引用块）。
    pub surface_soft: &'static str,
    /// 主文字。
    pub text: &'static str,
    /// 次要文字。
    pub text_soft: &'static str,
    /// 更弱的提示文字。
    pub faint: &'static str,
    /// 分隔线。
    pub line: &'static str,
    /// 强调色：编号、导轨、重点。
    pub accent: &'static str,
    /// 强调色的淡底。
    pub accent_soft: &'static str,
    /// 压在强调色上的文字。
    pub on_accent: &'static str,
}

/// 深色主题：与 iPhone 上深色模式的实际观感一致。
pub const INK_DARK: Theme = Theme {
    name: "ink-dark",
    bg: "#101112",
    bg_deep: "#0A0B0C",
    surface: "#1B1D1F",
    surface_soft: "#282A2C",
    text: "#F3F3EF",
    text_soft: "#B3B7B9",
    faint: "#7A7E80",
    line: "#3B3E40",
    accent: "#337BFF",
    accent_soft: "#1D2A44",
    on_accent: "#FFFFFF",
};

/// 浅色主题：雾白。
pub const INK_LIGHT: Theme = Theme {
    name: "ink-light",
    bg: "#F5F5F2",
    bg_deep: "#ECEDE9",
    surface: "#FFFFFF",
    surface_soft: "#ECEDE9",
    text: "#191B1D",
    text_soft: "#4C5052",
    faint: "#64686A",
    line: "#DDDFDC",
    accent: "#337BFF",
    accent_soft: "#E4EDFF",
    on_accent: "#FFFFFF",
};

/// 一个片段在版式里的角色。渲染器按角色决定字号、颜色与位置；
/// 角色本身不含任何样式，所以同一棵树既能出图也能出 Markdown。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// 顶部的分类胶囊，如「晚间工作计划」。
    Kicker,
    /// 卡片主标题。
    Title,
    /// 标题下的导语。
    Lead,
    /// 事项序号，两位数字。
    StepIndex,
    /// 事项标题。
    StepTitle,
    /// 事项副标题。
    StepNote,
    /// 事项标签，一个标签一个 Block。
    Tag,
    /// 「目标：」这类小节标签。
    SectionLabel,
    /// 正文段落。
    Body,
    /// 转写原文的一行。
    Quote,
    /// 页脚元信息。
    Meta,
}

/// 排版树的一个节点：文本 + 角色 + 层级。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    /// 这个片段是什么。
    pub role: Role,
    /// 文本内容（已去首尾空白；空内容的 Block 不会进入树）。
    pub text: String,
    /// 视觉层级：0 = 卡片外层，1 = 卡内，2 = 卡内再缩进。
    pub level: u8,
}

impl Block {
    fn new(role: Role, text: impl Into<String>, level: u8) -> Option<Self> {
        let text = text.into();
        let text = text.trim().to_string();
        if text.is_empty() {
            return None;
        }
        Some(Self { role, text, level })
    }
}

/// 一件事，既用于顶部导轨，也用于下面的详情卡。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Item {
    /// 序号，从 1 开始；导出时渲染成两位数字。
    pub index: u8,
    /// 事项标题。
    pub title: String,
    /// 副标题，例如「今晚的起点，最先做」。
    pub note: Option<String>,
    /// 标签，例如「8-10 月」「对账单」。
    pub tags: Vec<String>,
    /// 这一项要达成什么。
    pub goal: Option<String>,
    /// 展开说明。
    pub body: Option<String>,
}

/// 一张卡片。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Card {
    /// 顶部分类胶囊。
    pub kicker: Option<String>,
    /// 主标题。
    pub title: String,
    /// 导语。
    pub lead: Option<String>,
    /// 事项。
    pub items: Vec<Item>,
    /// 转写原文，一行一条。
    pub transcript: Vec<String>,
    /// 页脚元信息，例如「2026-11-15 · 12 分 04 秒」。
    pub meta: Option<String>,
}

impl Card {
    /// 排成有序的排版树。这是唯一的真相：Markdown、HTML 与平台层绘图
    /// 都必须走这一个函数，否则几种出口迟早互相漂移。
    ///
    /// 空内容一律丢弃，所以没有导语、没有转写、没有页脚的卡片不会在
    /// 产物里留下一片空白。
    pub fn blocks(&self) -> Vec<Block> {
        let mut out = Vec::new();
        let mut push = |role: Role, text: &str, level: u8| {
            if let Some(block) = Block::new(role, text, level) {
                out.push(block);
            }
        };

        if let Some(kicker) = self.kicker.as_deref() {
            push(Role::Kicker, kicker, 0);
        }
        push(Role::Title, &self.title, 0);
        if let Some(lead) = self.lead.as_deref() {
            push(Role::Lead, lead, 0);
        }

        for item in &self.items {
            push(Role::StepIndex, &format!("{:02}", item.index), 1);
            push(Role::StepTitle, &item.title, 1);
            if let Some(note) = item.note.as_deref() {
                push(Role::StepNote, note, 1);
            }
            for tag in &item.tags {
                push(Role::Tag, tag, 2);
            }
            if let Some(goal) = item.goal.as_deref() {
                push(Role::SectionLabel, "目标：", 2);
                push(Role::Body, goal, 2);
            }
            if let Some(body) = item.body.as_deref() {
                push(Role::Body, body, 2);
            }
        }

        for line in &self.transcript {
            push(Role::Quote, line, 0);
        }
        if let Some(meta) = self.meta.as_deref() {
            push(Role::Meta, meta, 0);
        }
        out
    }

    /// 转成 Markdown。只保留结构，不表达颜色与位置——所以它复用不了
    /// 一半的排版信息，但保证了「文字一个不少」。
    pub fn to_markdown(&self) -> String {
        let mut out = String::new();
        if let Some(kicker) = self.kicker.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            out.push_str(&format!("> {kicker}\n\n"));
        }
        let title = self.title.trim();
        if !title.is_empty() {
            out.push_str(&format!("# {title}\n\n"));
        }
        if let Some(lead) = self.lead.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            out.push_str(&format!("{lead}\n\n"));
        }
        for item in &self.items {
            let title = item.title.trim();
            if title.is_empty() {
                continue;
            }
            out.push_str(&format!("## {:02} {title}\n\n", item.index));
            if let Some(note) = item.note.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                out.push_str(&format!("{note}\n\n"));
            }
            let tags: Vec<&str> = item
                .tags
                .iter()
                .map(|t| t.trim())
                .filter(|t| !t.is_empty())
                .collect();
            if !tags.is_empty() {
                let rendered: Vec<String> = tags.iter().map(|t| format!("`{t}`")).collect();
                out.push_str(&rendered.join(" "));
                out.push_str("\n\n");
            }
            if let Some(goal) = item.goal.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                out.push_str(&format!("目标：{goal}\n\n"));
            }
            if let Some(body) = item.body.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                out.push_str(&format!("{body}\n\n"));
            }
        }
        let lines: Vec<&str> = self
            .transcript
            .iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect();
        if !lines.is_empty() {
            out.push_str("---\n\n");
            for line in lines {
                out.push_str(&format!("> {line}\n"));
            }
            out.push('\n');
        }
        if let Some(meta) = self.meta.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            out.push_str(&format!("*{meta}*\n"));
        }
        out.trim_end().to_string() + "\n"
    }

    /// 转成一份自包含的 HTML：内联 CSS、无外链、无脚本，亮暗跟随系统。
    ///
    /// 文本顺序与 Card::blocks 完全一致——这是几种出口不漂移的凭据，
    /// 也是测试里那条「按顺序全部出现」的断言。
    pub fn to_html(&self) -> String {
        let mut body = String::new();
        let mut open_card = false;

        if let Some(kicker) = self.kicker.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            body.push_str(&format!(
                r#"<div class="kicker"><span class="dot"></span>{}</div>"#,
                escape_html(kicker)
            ));
        }
        let title = self.title.trim();
        if !title.is_empty() {
            body.push_str(&format!(r#"<h1>{}</h1>"#, escape_html(title)));
        }
        if let Some(lead) = self.lead.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            body.push_str(&format!(r#"<p class="lead">{}</p>"#, escape_html(lead)));
        }

        if !self.items.is_empty() {
            body.push_str(r#"<section class="rail">"#);
            for item in &self.items {
                let title = item.title.trim();
                if title.is_empty() {
                    continue;
                }
                body.push_str(&format!(
                    r#"<div class="step"><span class="num">{:02}</span><div class="stepText"><strong>{}</strong>{}</div></div>"#,
                    item.index,
                    escape_html(title),
                    item.note
                        .as_deref()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(|n| format!(r#"<em>{}</em>"#, escape_html(n)))
                        .unwrap_or_default()
                ));
            }
            body.push_str(r#"</section>"#);
        }

        for item in &self.items {
            let title = item.title.trim();
            if title.is_empty() {
                continue;
            }
            if !open_card {
                body.push_str(r#"<section class="items">"#);
                open_card = true;
            }
            body.push_str(r#"<article class="item">"#);
            body.push_str(&format!(
                r#"<header><span class="num">{:02}</span><div class="head"><strong>{}</strong>{}</div></header>"#,
                item.index,
                escape_html(title),
                item.note
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|n| format!(r#"<em>{}</em>"#, escape_html(n)))
                    .unwrap_or_default()
            ));
            let tags: Vec<&str> = item
                .tags
                .iter()
                .map(|t| t.trim())
                .filter(|t| !t.is_empty())
                .collect();
            if !tags.is_empty() {
                body.push_str(r#"<div class="tags">"#);
                for tag in tags {
                    body.push_str(&format!(r#"<span class="tag">{}</span>"#, escape_html(tag)));
                }
                body.push_str("</div>");
            }
            if let Some(goal) = item.goal.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                body.push_str(&format!(
                    r#"<p class="goal"><span class="label">目标：</span>{}</p>"#,
                    escape_html(goal)
                ));
            }
            if let Some(text) = item.body.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                body.push_str(&format!(r#"<p class="body">{}</p>"#, escape_html(text)));
            }
            body.push_str(r#"</article>"#);
        }
        if open_card {
            body.push_str(r#"</section>"#);
        }

        let lines: Vec<&str> = self
            .transcript
            .iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect();
        if !lines.is_empty() {
            body.push_str(r#"<section class="transcript"><h2>转写原文</h2>"#);
            for line in lines {
                body.push_str(&format!("<p>{}</p>", escape_html(line)));
            }
            body.push_str(r#"</section>"#);
        }
        if let Some(meta) = self.meta.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            body.push_str(&format!(r#"<footer>{}</footer>"#, escape_html(meta)));
        }

        format!(
            "<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n\
             <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
             <title>{title}</title>\n<style>{vars}{css}</style>\n</head>\n<body>\n\
             <main class=\"sheet\">{body}</main>\n</body>\n</html>\n",
            title = escape_html(self.title.trim()),
            vars = theme_vars(),
            css = CARD_CSS,
            body = body
        )
    }
}

/// 两份主题的 CSS 变量。
fn theme_vars() -> String {
    let block = |t: &Theme| {
        format!(
            "--bg:{};--bg-deep:{};--surface:{};--surface-soft:{};--text:{};\
             --text-soft:{};--faint:{};--line:{};--accent:{};--accent-soft:{};--on-accent:{};",
            t.bg, t.bg_deep, t.surface, t.surface_soft, t.text, t.text_soft, t.faint, t.line, t.accent,
            t.accent_soft, t.on_accent
        )
    };
    format!(
        ":root{{{}color-scheme:light dark;}}@media (prefers-color-scheme: dark){{:root{{{}}}}}",
        block(&INK_LIGHT),
        block(&INK_DARK)
    )
}

const CARD_CSS: &str = r#"
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:var(--bg);color:var(--text)}
body{font:400 16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Noto Sans CJK SC","Segoe UI",sans-serif;
 -webkit-font-smoothing:antialiased;padding:28px 18px 40px}
.sheet{max-width:420px;margin:0 auto}
.kicker{display:inline-flex;align-items:center;gap:7px;padding:6px 13px 6px 11px;border-radius:999px;
 background:var(--accent-soft);color:var(--accent);font-size:13px;font-weight:600;letter-spacing:.02em}
.kicker .dot{width:6px;height:6px;border-radius:50%;background:var(--accent)}
h1{margin:16px 0 0;font-size:31px;line-height:1.24;font-weight:700;letter-spacing:-.02em}
.lead{margin:12px 0 0;color:var(--text-soft);font-size:15px;line-height:1.62}
.rail{margin:26px 0 0;padding:20px 18px 6px;background:var(--surface);border-radius:26px}
.step{position:relative;display:flex;gap:14px;padding:0 0 18px}
.step:not(:last-child)::before{content:"";position:absolute;left:15px;top:30px;bottom:2px;width:1px;background:var(--line)}
.num{flex:0 0 30px;width:30px;height:30px;border-radius:9px;background:var(--accent-soft);color:var(--accent);
 font-size:13px;font-weight:700;display:flex;align-items:center;justify-content:center;
 font-variant-numeric:tabular-nums;z-index:1}
.stepText{display:flex;flex-direction:column;gap:3px;padding-top:3px}
.stepText strong{font-size:15px;font-weight:600;line-height:1.4}
.stepText em{font-style:normal;font-size:13px;color:var(--faint)}
.items{display:flex;flex-direction:column;gap:12px;margin:12px 0 0}
.item{background:var(--surface);border-radius:26px;padding:18px}
.item header{display:flex;gap:14px;align-items:flex-start}
.item header .head{display:flex;flex-direction:column;gap:3px;padding-top:3px}
.item header strong{font-size:16px;font-weight:600;line-height:1.4}
.item header em{font-style:normal;font-size:13px;color:var(--faint)}
.tags{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0 0}
.tag{padding:4px 10px;border-radius:8px;background:var(--surface-soft);color:var(--text-soft);font-size:12.5px;line-height:1.4}
.goal{margin:14px 0 0;padding-top:13px;border-top:1px solid var(--line);font-size:14.5px;line-height:1.6}
.goal .label{color:var(--text-soft);font-weight:600;display:block;margin-bottom:5px}
.body{margin:10px 0 0;color:var(--text-soft);font-size:14px;line-height:1.65}
.transcript{margin:18px 0 0;padding:18px;border-radius:26px;background:var(--bg-deep);border:1px solid var(--line)}
.transcript h2{margin:0 0 12px;font-size:13px;font-weight:600;letter-spacing:.06em;color:var(--faint);text-transform:uppercase}
.transcript p{margin:0 0 9px;color:var(--text-soft);font-size:14px;line-height:1.7}
.transcript p:last-child{margin-bottom:0}
footer{margin:20px 0 0;text-align:center;color:var(--faint);font-size:12px;letter-spacing:.02em}
"#;

/// 转义 HTML 文本节点与属性值。
fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

impl Card {
    /// 从一段转写原文直接构造卡片，不需要任何模型。
    ///
    /// 规则刻意简单——它是兜底路径：模型版接进来之后，这个函数可以整体被
    /// 替换，而现在它保证「录完一段话就能出一张卡」，不依赖任何下载。
    ///
    /// - 第一个非空行是标题，除非它自己就带着编号；
    /// - 带编号前缀（1. / 1、 / 1) / ① / - / • / ·）的行各成为一个事项；
    /// - 没有编号时，标题之外的每个非空行各成一个事项；
    /// - 原始文本全部进转写区，一个字都不丢。
    pub fn from_transcript(text: &str, meta: Option<&str>) -> Card {
        let meta = meta.map(str::to_string).filter(|m| !m.trim().is_empty());
        let lines: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .collect();
        if lines.is_empty() {
            return Card { meta, ..Card::default() };
        }

        let first_is_item = split_marker(lines[0]).is_some();
        let title = if first_is_item {
            "语音记录".to_string()
        } else {
            short_title(lines[0])
        };
        let body = if first_is_item { &lines[..] } else { &lines[1..] };

        // 整段都没有编号时，每行本身就是一件事；只要出现过编号，没有编号的
        // 前置行就按导语处理，避免把开场白硬塞成一件事项。
        let body_has_markers = body.iter().any(|line| split_marker(line).is_some());

        let mut items: Vec<Item> = Vec::new();
        let mut lead: Vec<&str> = Vec::new();
        let mut index: u8 = 0;
        for line in body {
            let push_item = |items: &mut Vec<Item>, index: u8, text: &str| {
                items.push(Item {
                    index,
                    title: short_item(text),
                    ..Item::default()
                });
            };
            match split_marker(line) {
                Some((number, rest)) => {
                    index = if number > 0 { number } else { index.saturating_add(1) };
                    push_item(&mut items, index, rest);
                }
                None if !body_has_markers => {
                    index = index.saturating_add(1);
                    push_item(&mut items, index, line);
                }
                None => {
                    if items.is_empty() {
                        lead.push(line);
                    } else {
                        index = index.saturating_add(1);
                        push_item(&mut items, index, line);
                    }
                }
            }
        }

        let lead_text = {
            let joined = lead.join(" ");
            if joined.trim().is_empty() { None } else { Some(joined) }
        };

        Card {
            kicker: Some("语音记录".into()),
            title,
            lead: lead_text,
            items,
            transcript: lines.iter().map(|line| (*line).to_string()).collect(),
            meta,
        }
    }
}

/// 标题最多这么多个字符，超出用省略号收尾。
const TITLE_LIMIT: usize = 40;
/// 单个事项最多这么多个字符。
const ITEM_LIMIT: usize = 60;

fn short_title(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= TITLE_LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(TITLE_LIMIT).collect();
    format!("{head}…")
}

fn short_item(text: &str) -> String {
    let trimmed = text.trim().trim_end_matches(['。', '；', ';', '，', ',']).trim();
    if trimmed.chars().count() <= ITEM_LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(ITEM_LIMIT).collect();
    format!("{head}…")
}

/// 识别行首编号：返回（序号，去掉编号后的正文）。序号 0 表示项目符号。
fn split_marker(line: &str) -> Option<(u8, &str)> {
    let line = line.trim_start();
    if let Some(first) = line.chars().next() {
        if let Some(number) = circled_digit(first) {
            return Some((number, line[first.len_utf8()..].trim_start()));
        }
    }
    let digits: String = line.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !digits.is_empty() {
        let rest = &line[digits.len()..];
        if let Some(tail) = rest.strip_prefix(['.', '、', ')', '）', '．']) {
            if let Ok(number) = digits.parse::<u8>() {
                if number > 0 {
                    return Some((number, tail.trim_start()));
                }
            }
        }
    }
    for marker in ["- ", "• ", "· ", "* ", "— ", "– "] {
        if let Some(tail) = line.strip_prefix(marker) {
            return Some((0, tail.trim_start()));
        }
    }
    None
}

/// ①–⑳ 映射到 1–20。
fn circled_digit(c: char) -> Option<u8> {
    let code = c as u32;
    match code {
        0x2460..=0x2473 => Some((code - 0x2460 + 1) as u8),
        0x2474..=0x2487 => Some((code - 0x2474 + 1) as u8),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Card {
        Card {
            kicker: Some("晚间工作计划".into()),
            title: "今晚待办：对账清点与投放盘点".into(),
            lead: Some("三件事按先后顺序做：先注册后台，再清点 8-10 月票据，最后盘点日韩投放计划。".into()),
            items: vec![
                Item {
                    index: 1,
                    title: "注册 Twitter 广告后台".into(),
                    note: Some("今晚的起点，最先做".into()),
                    tags: vec![],
                    goal: Some("完成注册，为后续投放做准备。".into()),
                    body: None,
                },
                Item {
                    index: 2,
                    title: "清点代理商票据".into(),
                    note: None,
                    tags: vec!["8-10 月".into(), "对账单".into(), "发票".into()],
                    goal: None,
                    body: Some("按代理商逐个核对。".into()),
                },
            ],
            transcript: vec!["我认为我今天晚上应该：".into(), "先把后台注册了；".into()],
            meta: Some("2026-11-15 · 12 分 04 秒".into()),
        }
    }

    fn strip_tags(html: &str) -> String {
        let mut out = String::with_capacity(html.len());
        let mut inside = false;
        for ch in html.chars() {
            match ch {
                '<' => inside = true,
                '>' => inside = false,
                _ if !inside => out.push(ch),
                _ => {}
            }
        }
        out
    }

    fn assert_in_order(haystack: &str, blocks: &[Block], label: &str) {
        let mut cursor = 0usize;
        for block in blocks {
            let rest = &haystack[cursor..];
            match rest.find(&block.text) {
                Some(at) => cursor += at + block.text.len(),
                None => panic!("{} 缺少按序出现的片段：{:?}", label, block.text),
            }
        }
    }

    #[test]
    fn empty_card_produces_valid_html_and_no_blocks() {
        let card = Card::default();
        assert!(card.blocks().is_empty());
        let html = card.to_html();
        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("<main class=\"sheet\">"));
        assert!(html.trim_end().ends_with("</html>"));
    }

    #[test]
    fn blank_fields_are_dropped() {
        let card = Card {
            title: "只有标题".into(),
            ..Card::default()
        };
        let blocks = card.blocks();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].role, Role::Title);
    }

    #[test]
    fn html_carries_every_block_in_order() {
        let card = sample();
        assert_in_order(&strip_tags(&card.to_html()), &card.blocks(), "HTML");
    }

    #[test]
    fn markdown_carries_every_block_in_order() {
        let card = sample();
        assert_in_order(&card.to_markdown(), &card.blocks(), "Markdown");
    }

    #[test]
    fn escaping_keeps_markup_out_of_the_document() {
        let mut card = sample();
        card.items[0].body = Some("<script>alert(1)</script> & 全部".into());
        let html = card.to_html();
        assert!(!html.contains("<script>alert(1)</script>"), "原始标签泄漏进了文档");
        assert!(html.contains("&lt;script&gt;"));
        assert!(html.contains("&amp; 全部"));
    }

    #[test]
    fn index_is_zero_padded() {
        let card = sample();
        let html = card.to_html();
        assert!(html.contains(">01<"));
        assert!(html.contains(">02<"));
        let md = card.to_markdown();
        assert!(md.contains("## 01 注册 Twitter 广告后台"));
    }

    #[test]
    fn theme_vars_cover_both_schemes() {
        let vars = theme_vars();
        assert!(vars.contains("prefers-color-scheme: dark"));
        assert!(vars.contains(INK_DARK.bg));
        assert!(vars.contains(INK_LIGHT.bg));
        for value in [INK_DARK.surface, INK_DARK.accent, INK_LIGHT.surface, INK_LIGHT.accent] {
            assert!(vars.contains(value), "主题色 {} 没有写入变量", value);
        }
    }

    #[test]
    fn transcript_only_card_still_renders() {
        let card = Card {
            title: "一段录音".into(),
            transcript: vec!["第一句".into(), "第二句".into()],
            ..Card::default()
        };
        let html = card.to_html();
        assert!(html.contains("转写原文"));
        assert_in_order(&strip_tags(&html), &card.blocks(), "HTML");
    }
}

#[cfg(test)]
mod transcript_tests {
    use super::*;

    const SAMPLE: &str = "今晚对账\n1. 先注册广告后台\n2. 清点 8-10 月票据\n3. 盘点日韩投放计划";

    #[test]
    fn numbered_lines_become_items() {
        let card = Card::from_transcript(SAMPLE, Some("2026-11-16 · 3 分"));
        assert_eq!(card.title, "今晚对账");
        assert_eq!(card.items.len(), 3);
        assert_eq!(card.items[0].index, 1);
        assert_eq!(card.items[0].title, "先注册广告后台");
        assert_eq!(card.items[2].title, "盘点日韩投放计划");
        assert_eq!(card.meta.as_deref(), Some("2026-11-16 · 3 分"));
        assert_eq!(card.kicker.as_deref(), Some("语音记录"));
    }

    #[test]
    fn original_text_survives_in_transcript() {
        let card = Card::from_transcript(SAMPLE, None);
        assert_eq!(card.transcript.len(), 4);
        assert!(card.transcript.iter().any(|line| line == "今晚对账"));
        assert!(card.transcript.iter().any(|line| line.contains("清点")));
    }

    #[test]
    fn bullet_lines_get_running_index() {
        let card = Card::from_transcript("周会\n- 登录\n- 支付\n- 通知", None);
        assert_eq!(card.title, "周会");
        let titles: Vec<&str> = card.items.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles, vec!["登录", "支付", "通知"]);
        let indexes: Vec<u8> = card.items.iter().map(|i| i.index).collect();
        assert_eq!(indexes, vec![1, 2, 3]);
    }

    #[test]
    fn circled_numbers_are_understood() {
        let card = Card::from_transcript("三件事\n① 甲\n② 乙", None);
        assert_eq!(card.items.len(), 2);
        assert_eq!(card.items[1].index, 2);
        assert_eq!(card.items[1].title, "乙");
    }

    #[test]
    fn plain_lines_each_become_an_item() {
        let card = Card::from_transcript("标题\n第一件事\n第二件事", None);
        assert_eq!(card.title, "标题");
        assert_eq!(card.items.len(), 2);
        assert_eq!(card.lead, None);
    }

    #[test]
    fn leading_prose_becomes_the_lead() {
        let card = Card::from_transcript("标题\n先说一句背景\n1. 甲\n2. 乙", None);
        assert_eq!(card.lead.as_deref(), Some("先说一句背景"));
        assert_eq!(card.items.len(), 2);
    }

    #[test]
    fn empty_text_gives_an_empty_card() {
        let card = Card::from_transcript("   \n\n  ", None);
        assert!(card.title.is_empty());
        assert!(card.items.is_empty());
        assert!(card.transcript.is_empty());
    }

    #[test]
    fn long_title_and_item_are_truncated() {
        let long = "很".repeat(80);
        let card = Card::from_transcript(&format!("{long}\n1. {long}"), None);
        assert!(card.title.ends_with('…'));
        assert_eq!(card.title.chars().count(), TITLE_LIMIT + 1);
        assert!(card.items[0].title.ends_with('…'));
        assert_eq!(card.items[0].title.chars().count(), ITEM_LIMIT + 1);
        // 转写区保留全文，不被截断。
        assert_eq!(card.transcript[0].chars().count(), 80);
    }

    #[test]
    fn transcript_card_exports_carry_every_block() {
        let card = Card::from_transcript(SAMPLE, Some("2026-11-16"));
        let blocks = card.blocks();
        assert!(!blocks.is_empty());
        let html = card.to_html();
        assert!(html.contains("今晚对账"));
        assert!(html.contains("盘点日韩投放计划"));
        assert!(html.contains("转写原文"));
        let md = card.to_markdown();
        assert!(md.contains("# 今晚对账"));
        assert!(md.contains("## 03 盘点日韩投放计划"));
    }

    #[test]
    fn numbering_restarts_are_kept_verbatim() {
        // 用户口述里编号跳号时，尊重用户写的数字，不自己重排。
        let card = Card::from_transcript("标题\n1. 甲\n5. 乙", None);
        let indexes: Vec<u8> = card.items.iter().map(|i| i.index).collect();
        assert_eq!(indexes, vec![1, 5]);
    }
}
