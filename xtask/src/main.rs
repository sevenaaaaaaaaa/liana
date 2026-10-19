//! 松萝构建工具（零依赖）。
//!
//! ```text
//! xtask dict build <input.tsv> -o <output.ifd> [--with-base]
//! xtask dict import-rime <dict.yaml> -o <output.ifd> [--with-base]
//! xtask dict import-rime-multi -o <output.ifd> [--tsv out.tsv] [--max-entries N] \
//!     <file.yaml[:scale]> [<file.yaml[:scale]> ...]
//! xtask dict stats <file.ifd|file.tsv>
//! ```

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use liana_dict::Dictionary;
use liana_dict::import::{ImportReport, parse_rime_dict, parse_rime_dicts, parse_tsv};
use liana_plugin::Pack;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("错误: {e}");
            eprintln!();
            usage();
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("dict") => dict_cmd(&args[1..]),
        Some("plugin") => plugin_cmd(&args[1..]),
        Some("accuracy") if args.get(1).map(String::as_str) == Some("--hard") => {
            accuracy_hard_cmd(&args[2..])
        }
        Some("accuracy") => accuracy_cmd(),
        Some("query") => query_cmd(&args[1..]),
        Some("-h") | Some("--help") => {
            usage();
            Ok(())
        }
        Some(other) => Err(format!("未知命令: {other}")),
        None => {
            usage();
            Ok(())
        }
    }
}

/// `xtask accuracy`：输入准确率体检——生产词库跑 90+ 真实场景，
/// 按「首选是否就是想要的那一个」计分，暴露排序/词频/分词的真实短板。
fn accuracy_cmd() -> Result<(), String> {
    use std::collections::BTreeMap;
    use std::sync::Arc;

    use liana_core::Mode;
    use liana_engine::Session;

    let tsv = std::fs::read_to_string("crates/dict/data/base-large.tsv").map_err(|e| {
        format!("读不到 crates/dict/data/base-large.tsv: {e}（请在仓库根目录运行）")
    })?;
    let (dict, _) = parse_tsv(&tsv);
    let dict = Arc::new(dict);
    println!("词库: {} 词条，开始体检…", dict.entry_count());

    // (分组, 按键, 期望首选)
    let cases: &[(&str, &str, &str)] = &[
        // ── 日常高频词 ──
        ("日常高频", "nihao", "你好"),
        ("日常高频", "xiexie", "谢谢"),
        ("日常高频", "zaijian", "再见"),
        ("日常高频", "duibuqi", "对不起"),
        ("日常高频", "meiguanxi", "没关系"),
        ("日常高频", "huanying", "欢迎"),
        ("日常高频", "kuaile", "快乐"),
        ("日常高频", "mingtian", "明天"),
        ("日常高频", "zuotian", "昨天"),
        ("日常高频", "xianzai", "现在"),
        ("日常高频", "shijian", "时间"),
        ("日常高频", "keyi", "可以"),
        ("日常高频", "yinggai", "应该"),
        ("日常高频", "bixu", "必须"),
        ("日常高频", "xuyao", "需要"),
        ("日常高频", "xiwang", "希望"),
        ("日常高频", "yijing", "已经"),
        ("日常高频", "yinwei", "因为"),
        ("日常高频", "suoyi", "所以"),
        ("日常高频", "danshi", "但是"),
        ("日常高频", "haishi", "还是"),
        ("日常高频", "shenme", "什么"),
        ("日常高频", "zenme", "怎么"),
        ("日常高频", "zheyang", "这样"),
        ("日常高频", "zhidao", "知道"),
        ("日常高频", "mingbai", "明白"),
        ("日常高频", "jixu", "继续"),
        ("日常高频", "chongxin", "重新"),
        // ── 专名地名 ──
        ("专名地名", "beijing", "北京"),
        ("专名地名", "shanghai", "上海"),
        ("专名地名", "zhongguo", "中国"),
        ("专名地名", "changcheng", "长城"),
        ("专名地名", "huanghe", "黄河"),
        ("专名地名", "xi'an", "西安"),
        ("专名地名", "xingqitian", "星期天"),
        ("专名地名", "gongzuori", "工作日"),
        // ── 工作/科技 ──
        ("工作科技", "gongzuo", "工作"),
        ("工作科技", "xiangmu", "项目"),
        ("工作科技", "wenti", "问题"),
        ("工作科技", "jiejue", "解决"),
        ("工作科技", "jisuanji", "计算机"),
        ("工作科技", "chengxuyuan", "程序员"),
        ("工作科技", "daima", "代码"),
        ("工作科技", "ceshi", "测试"),
        ("工作科技", "yunxing", "运行"),
        ("工作科技", "bushu", "部署"),
        ("工作科技", "wenjian", "文件"),
        ("工作科技", "shezhi", "设置"),
        ("工作科技", "gengxin", "更新"),
        ("工作科技", "shengji", "升级"),
        ("工作科技", "anzhuang", "安装"),
        ("工作科技", "xiazai", "下载"),
        ("工作科技", "shangchuan", "上传"),
        ("工作科技", "fuzhi", "复制"),
        ("工作科技", "baocun", "保存"),
        ("工作科技", "shanchu", "删除"),
        ("工作科技", "baocuo", "报错"),
        ("工作科技", "keji", "科技"),
        ("工作科技", "jingji", "经济"),
        ("工作科技", "fazhan", "发展"),
        ("工作科技", "jiaoyu", "教育"),
        ("工作科技", "yinhang", "银行"),
        ("工作科技", "yonghu", "用户"),
        ("工作科技", "mima", "密码"),
        ("工作科技", "zhanghu", "账户"),
        ("工作科技", "youjian", "邮件"),
        // ── 设备/生活 ──
        ("设备生活", "shouji", "手机"),
        ("设备生活", "diannao", "电脑"),
        ("设备生活", "wangluo", "网络"),
        ("设备生活", "jianpan", "键盘"),
        ("设备生活", "pingmu", "屏幕"),
        ("设备生活", "shubiao", "鼠标"),
        ("设备生活", "ditu", "地图"),
        ("设备生活", "yiyuan", "医院"),
        ("设备生活", "xuexiao", "学校"),
        ("设备生活", "huoche", "火车"),
        ("设备生活", "feiji", "飞机"),
        ("设备生活", "ditie", "地铁"),
        ("设备生活", "gongyuan", "公园"),
        ("设备生活", "laoshi", "老师"),
        ("设备生活", "xuesheng", "学生"),
        ("设备生活", "pengyou", "朋友"),
        ("设备生活", "shenghuo", "生活"),
        ("设备生活", "xuexi", "学习"),
        // ── 易混淆音（声母韵母陷阱） ──
        ("易混淆音", "lvxing", "旅行"),
        ("易混淆音", "lvshi", "律师"),
        ("易混淆音", "falv", "法律"),
        ("易混淆音", "guilv", "规律"),
        ("易混淆音", "nuli", "努力"),
        ("易混淆音", "lue", "略"),
        ("易混淆音", "nve", "虐"),
        ("易混淆音", "jilu", "记录"),
        ("易混淆音", "huiyi", "会议"),
        ("易混淆音", "jihua", "计划"),
        // ── 整句转换（Viterbi） ──
        ("整句转换", "nihaoma", "你好吗"),
        ("整句转换", "jintiantianqi", "今天天气"),
        ("整句转换", "womenmingtiankaihui", "我们明天开会"),
        ("整句转换", "zhegexiangmu", "这个项目"),
        ("整句转换", "taihaole", "太好了"),
        ("整句转换", "chifanlema", "吃饭了吗"),
        ("整句转换", "zaoshanghao", "早上好"),
        ("整句转换", "wanshanghao", "晚上好"),
        ("整句转换", "shurufa", "输入法"),
        ("整句转换", "zhongwen", "中文"),
    ];

    let mut by_group: BTreeMap<&str, (usize, usize)> = BTreeMap::new();
    let mut failures: Vec<(&str, &str, &str, String)> = Vec::new();
    let mut total = 0usize;
    let mut pass = 0usize;

    for (group, keys, want) in cases {
        let mut s = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in keys.chars() {
            s.feed(ch);
        }
        let got = s
            .composition()
            .candidates
            .first()
            .map(|c| c.text.clone())
            .unwrap_or_default();
        total += 1;
        let entry = by_group.entry(group).or_insert((0, 0));
        entry.1 += 1;
        if got == *want {
            pass += 1;
            entry.0 += 1;
        } else {
            failures.push((group, keys, want, got));
        }
    }

    // 英文/网址：符号续接 + 原样上屏；中文组合仍拒绝符号（前端走 首选+全角标点）
    {
        let mut ok = true;
        let mut s = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in "example.ai".chars() {
            ok = ok && s.feed(ch);
        }
        ok = ok && s.commit_raw().as_deref() == Some("example.ai");

        let mut t = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in "http://x.com/a_1?k=v".chars() {
            ok = ok && t.feed(ch);
        }
        ok = ok && t.commit_raw().as_deref() == Some("http://x.com/a_1?k=v");

        let mut c = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in "nihao".chars() {
            c.feed(ch);
        }
        ok = ok && !c.feed('.');

        total += 1;
        let entry = by_group.entry("英文/网址").or_insert((0, 0));
        entry.1 += 1;
        if ok {
            pass += 1;
            entry.0 += 1;
        } else {
            failures.push((
                "英文/网址",
                "example.ai 等",
                "符号续接+原样上屏",
                "续接或上屏失败".into(),
            ));
        }
    }

    println!();
    println!("═══ 松萝输入准确率体检 ═══");
    for (group, (p, n)) in &by_group {
        let pct = if *n > 0 { p * 100 / n } else { 0 };
        let bar = "█".repeat(pct / 5) + &"░".repeat(20 - pct / 5);
        println!("  {group:<10} {p:>3}/{n:<3} {pct:>3}%  {bar}");
    }
    println!("  ──────────────────────────────");
    println!(
        "  总计         {pass:>3}/{total:<3} {:>3}%",
        pass * 100 / total
    );
    if failures.is_empty() {
        println!("  ✅ 全部通过");
    } else {
        println!("\n  失败明细（[分组] 按键 → 期望 ≠ 实际）:");
        for (group, keys, want, got) in &failures {
            println!("    [{group}] {keys} → 期望「{want}」实际「{got}」");
        }
    }
    Ok(())
}

/// `xtask plugin new|check`：插件包脚手架与校验（清单由内核 crate 统一把关）。
fn plugin_cmd(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("new") => plugin_new(&args[1..]),
        Some("check") => {
            let Some(dir) = args.get(1) else {
                return Err("check 需要包目录".into());
            };
            match Pack::from_dir(Path::new(dir)) {
                Ok(p) => {
                    println!(
                        "✓ {dir}: {} v{}（{}）入口 {}",
                        p.name,
                        p.version,
                        p.kind.id(),
                        p.entry
                    );
                    if !p.permissions.is_empty() {
                        println!("  权限: {:?}", p.permissions);
                    }
                    Ok(())
                }
                Err(e) => Err(format!("✗ {dir}: {e}")),
            }
        }
        Some(other) => Err(format!("未知 plugin 子命令: {other}")),
        None => Err("plugin 需要子命令（new/check）".into()),
    }
}

fn plugin_new(args: &[String]) -> Result<(), String> {
    let mut kind = String::new();
    let mut id = String::new();
    let mut name = String::new();
    let mut out = String::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--kind" => {
                i += 1;
                kind = args.get(i).ok_or("--kind 缺值")?.clone();
            }
            "--id" => {
                i += 1;
                id = args.get(i).ok_or("--id 缺值")?.clone();
            }
            "--name" => {
                i += 1;
                name = args.get(i).ok_or("--name 缺值")?.clone();
            }
            "-o" | "--output" => {
                i += 1;
                out = args.get(i).ok_or("-o 缺值")?.clone();
            }
            other => return Err(format!("无法识别的参数: {other}")),
        }
        i += 1;
    }
    if kind.is_empty() || id.is_empty() || name.is_empty() {
        return Err("需要 --kind <skin|pet> --id <包id> --name <显示名>".into());
    }
    let entry = match kind.as_str() {
        "skin" => "theme.json",
        "pet" => "pet.json",
        other => {
            return Err(format!(
                "--kind 只支持 skin|pet（dict 用 xtask dict build 生成）: {other}"
            ));
        }
    };
    let dir = if out.is_empty() {
        PathBuf::from(format!("plugins/{id}"))
    } else {
        PathBuf::from(&out).join(&id)
    };
    if dir.exists() {
        return Err(format!("目录已存在: {}", dir.display()));
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建目录失败: {e}"))?;

    let manifest = format!(
        r#"{{
  "id": "{id}",
  "name": "{name}",
  "version": "0.1.0",
  "kind": "{kind}",
  "authors": ["你的名字"],
  "description": "一句话说明这个包",
  "license": "CC0-1.0",
  "permissions": []
}}
"#
    );
    std::fs::write(dir.join("plugin.json"), &manifest).map_err(|e| format!("写清单失败: {e}"))?;

    match kind.as_str() {
        "skin" => std::fs::write(
            dir.join(entry),
            // 与 platforms/macos/Sources/Theme.swift 的 CandidateTheme 字段一一对应
            r##"{
  "light": {
    "surface": "#FFFFFFE6",
    "text": "#222222",
    "comment": "#888888",
    "accent": "#337BFF",
    "radius": 18,
    "font_size": 17
  },
  "dark": {
    "surface": "#3A3A3CD9",
    "text": "#F2F2F2",
    "comment": "#9A9A9A",
    "accent": "#5A9BFF",
    "radius": 18,
    "font_size": 17
  }
}
"##,
        ),
        _ => std::fs::write(
            dir.join(entry),
            // 与 platforms/macos/Sources/PetWindow.swift 的 PetPack 字段一一对应；
            // states 里至少要有 idle 指向包内的一张图片
            r#"{
  "size": 96,
  "states": {
    "idle": "idle.png",
    "composing": "composing.png",
    "commit": "commit.png"
  },
  "follow_cursor": true,
  "typing_bounce": true,
  "commit_particles": true
}
"#,
        ),
    }
    .map_err(|e| format!("写入口文件失败: {e}"))?;

    // 用内核校验回读，确保骨架天生合规
    let pack = Pack::from_dir(&dir).map_err(|e| format!("生成的包未通过内核校验: {e}"))?;
    println!(
        "已生成 {}（{} v{}）",
        dir.display(),
        pack.name,
        pack.version
    );
    println!(
        "下一步：编辑 {} 与图片/颜色数据，然后用 `xtask plugin check {}` 复验",
        entry,
        dir.display()
    );
    Ok(())
}

fn dict_cmd(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("build") => {
            let no_packs = args.iter().any(|a| a == "--no-packs");
            let rest: Vec<String> = args[1..].iter().filter(|a| *a != "--no-packs").cloned().collect();
            let (input, output, with_base) = parse_io(&rest)?;
            let src = read(&input)?;
            let (mut dict, report) = parse_tsv(&src);
            print_report("TSV", &input, &report);
            if !no_packs {
                merge_default_packs(&mut dict, Path::new(&input))?;
            }
            if with_base {
                let base = Dictionary::embedded();
                dict.merge(&base);
                println!("已合并内置基础词典：+{} 词条", base.entry_count());
            }
            write_ifd(&dict, &output)
        }
        Some("import-rime") => {
            let (input, output, with_base) = parse_io(&args[1..])?;
            let src = read(&input)?;
            let (mut dict, report) = parse_rime_dict(&src);
            print_report("Rime", &input, &report);
            if with_base {
                let base = Dictionary::embedded();
                dict.merge(&base);
                println!("已合并内置基础词典：+{} 词条", base.entry_count());
            }
            write_ifd(&dict, &output)
        }
        Some("import-rime-multi") => import_rime_multi(&args[1..]),
        Some("stats") => {
            let Some(path) = args.get(1) else {
                return Err("stats 需要文件路径".into());
            };
            let bytes = std::fs::read(path).map_err(|e| format!("读取 {path} 失败: {e}"))?;
            if bytes.starts_with(b"IFD1") {
                let dict =
                    Dictionary::from_bytes(&bytes).map_err(|e| format!("解析 {path} 失败: {e}"))?;
                println!("{path}: IFD1 词典");
                println!("  key 数: {}", dict.key_count());
                println!("  词条数: {}", dict.entry_count());
                println!("  文件大小: {} 字节", bytes.len());
            } else {
                let src = String::from_utf8(bytes).map_err(|_| "不是 UTF-8 文本".to_string())?;
                let (dict, report) = parse_tsv(&src);
                print_report("TSV", path, &report);
                println!("  key 数: {}", dict.key_count());
                println!("  词条数: {}", dict.entry_count());
            }
            Ok(())
        }
        Some(other) => Err(format!("未知 dict 子命令: {other}")),
        None => Err("dict 需要子命令（build/import-rime/import-rime-multi/stats）".into()),
    }
}

fn import_rime_multi(args: &[String]) -> Result<(), String> {
    let mut inputs: Vec<(String, f64)> = Vec::new();
    let mut output = None;
    let mut tsv = None;
    let mut max_entries = 0usize;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "--output" => {
                i += 1;
                output = Some(args.get(i).ok_or("--output 需要一个路径")?.clone());
            }
            "--tsv" => {
                i += 1;
                tsv = Some(args.get(i).ok_or("--tsv 需要一个路径")?.clone());
            }
            "--max-entries" => {
                i += 1;
                max_entries = args
                    .get(i)
                    .and_then(|v| v.parse().ok())
                    .ok_or("--max-entries 需要一个整数")?;
            }
            other => {
                let (path, scale) = match other.rsplit_once(':') {
                    Some((p, s)) => match s.parse::<f64>() {
                        Ok(v) => (p.to_string(), v),
                        Err(_) => (other.to_string(), 1.0),
                    },
                    None => (other.to_string(), 1.0),
                };
                inputs.push((path, scale));
            }
        }
        i += 1;
    }
    let output = output.ok_or("需要 -o 输出文件")?;
    if inputs.is_empty() {
        return Err("需要至少一个 Rime 词库文件".into());
    }
    let mut sources: Vec<(String, String, f64)> = Vec::with_capacity(inputs.len());
    for (path, scale) in &inputs {
        sources.push((path.clone(), read(path)?, *scale));
    }
    let (mut dict, report) = parse_rime_dicts(&sources);
    print_report("Rime 合并", &format!("{} 个来源", sources.len()), &report);
    for (path, scale) in &inputs {
        println!("  - {path} (×{scale})");
    }
    if max_entries > 0 {
        let (singles, multi) = dict.prune(max_entries);
        println!("剪枝: 保留单音节 {singles} / 多音节 {multi}");
    }
    write_ifd(&dict, &output)?;
    if let Some(path) = tsv {
        std::fs::write(&path, dict.to_tsv()).map_err(|e| format!("写入 {path} 失败: {e}"))?;
        println!("已写出 {path}: {} 词条", dict.entry_count());
    }
    Ok(())
}

/// `xtask query <按键>…`：打印生产词库（含官方词包）下的前 10 个候选与分数，排查排序用。
fn query_cmd(args: &[String]) -> Result<(), String> {
    use std::sync::Arc;

    use liana_core::Mode;
    use liana_engine::Session;

    let path = "crates/dict/data/base-large.tsv";
    let tsv = std::fs::read_to_string(path).map_err(|e| format!("读不到 {path}: {e}（请在仓库根目录运行）"))?;
    let mut dict = parse_tsv(&tsv).0;
    merge_default_packs(&mut dict, Path::new(path))?;
    let dict = Arc::new(dict);
    for keys in args {
        let mut s = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in keys.chars() {
            s.feed(ch);
        }
        println!("{keys}:");
        for c in s.composition().candidates.iter().take(10) {
            println!("  {:<12} {:>7.2}  {:?} 消耗 {}", c.text, c.score, c.kind, c.consumed);
        }
    }
    Ok(())
}

/// 官方词包：输入文件同目录的 `packs/default/*.tsv` 全部合并（同词同音取较大词频，只补词、抬词频）。
fn merge_default_packs(dict: &mut Dictionary, input: &Path) -> Result<usize, String> {
    let dir = input.parent().unwrap_or(Path::new(".")).join("packs/default");
    let Ok(read_dir) = std::fs::read_dir(&dir) else {
        return Ok(0);
    };
    let mut paths: Vec<PathBuf> = read_dir
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "tsv"))
        .collect();
    paths.sort();
    let before = dict.entry_count();
    for path in &paths {
        let src = std::fs::read_to_string(path).map_err(|e| format!("读取 {} 失败: {e}", path.display()))?;
        let (pack, report) = parse_tsv(&src);
        if report.skipped > 0 {
            print_report("词包", &path.display().to_string(), &report);
        }
        dict.merge(&pack);
    }
    let added = dict.entry_count() - before;
    if !paths.is_empty() {
        println!("已合并官方词包 {} 个：+{added} 词条（共 {}）", paths.len(), dict.entry_count());
    }
    Ok(added)
}

fn parse_io(args: &[String]) -> Result<(String, String, bool), String> {
    let mut input = None;
    let mut output = None;
    let mut with_base = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "--output" => {
                i += 1;
                output = Some(
                    args.get(i)
                        .ok_or_else(|| "-o 需要一个输出路径".to_string())?
                        .clone(),
                );
            }
            "--with-base" => with_base = true,
            other if input.is_none() && !other.starts_with('-') => input = Some(other.to_string()),
            other => return Err(format!("无法识别的参数: {other}")),
        }
        i += 1;
    }
    match (input, output) {
        (Some(i), Some(o)) => Ok((i, o, with_base)),
        _ => Err("需要输入文件与 -o 输出文件".into()),
    }
}

fn read(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("读取 {path} 失败: {e}"))
}

fn print_report(kind: &str, path: &str, report: &ImportReport) {
    println!("{kind} 导入 {path}");
    println!(
        "  总计 {} 行，导入 {} 条，跳过 {} 条",
        report.total, report.imported, report.skipped
    );
    for e in &report.errors {
        println!("  ! {e}");
    }
}

fn write_ifd(dict: &Dictionary, output: &str) -> Result<(), String> {
    let bytes = dict.to_bytes();
    std::fs::write(output, &bytes).map_err(|e| format!("写入 {output} 失败: {e}"))?;
    println!(
        "已写出 {output}: {} key / {} 词条 / {} 字节",
        dict.key_count(),
        dict.entry_count(),
        bytes.len()
    );
    Ok(())
}

fn usage() {
    eprintln!(
        "用法:\n  \
         xtask dict build <input.tsv> -o <output.ifd> [--with-base]\n  \
         xtask dict import-rime <dict.yaml> -o <output.ifd> [--with-base]\n  \
         xtask dict import-rime-multi -o <output.ifd> [--tsv out.tsv] [--max-entries N] \\\n      \
             <file.yaml[:scale]> [<file.yaml[:scale]> ...]\n  \
         xtask dict stats <file.ifd|file.tsv>\n  \
         xtask plugin new --kind <skin|pet> --id <包id> --name <显示名> [-o 输出目录]\n      \
             生成一个可编辑的插件包骨架（清单 + 入口文件），并通过内核校验回读。\n  \
         xtask plugin check <包目录>\n      \
             用内核校验一个插件包，打印通过/失败原因。"
    );
}

/// `xtask accuracy --hard`：困难评测集（单字/口语/简拼/半截/长整句/成语/科技）+ 学习能力。
/// 同时报 Top-1 与 Top-5：Top-1 决定「一次打对」，Top-5 决定「翻页成本」。
fn accuracy_hard_cmd(args: &[String]) -> Result<(), String> {
    use std::collections::BTreeMap;
    use std::sync::Arc;

    use liana_core::Mode;
    use liana_engine::Session;

    // --cases <评测集>（默认困难集）、--dict <词典 .ifd/.tsv>（默认 base-large.tsv）
    let mut cases_path = "xtask/data/accuracy-hard.tsv".to_string();
    let mut dict_path = "crates/dict/data/base-large.tsv".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--cases" => cases_path = args.get(i + 1).ok_or("--cases 缺值")?.clone(),
            "--dict" => dict_path = args.get(i + 1).ok_or("--dict 缺值")?.clone(),
            other => return Err(format!("未知参数: {other}")),
        }
        i += 2;
    }
    let dict = if dict_path.ends_with(".ifd") {
        let bytes = std::fs::read(&dict_path).map_err(|e| format!("读不到 {dict_path}: {e}"))?;
        Dictionary::from_bytes(&bytes).map_err(|e| format!("{dict_path}: {e}"))?
    } else {
        let tsv = std::fs::read_to_string(&dict_path)
            .map_err(|e| format!("读不到 {dict_path}: {e}（请在仓库根目录运行）"))?;
        let mut dict = parse_tsv(&tsv).0;
        merge_default_packs(&mut dict, Path::new(&dict_path))?;
        dict
    };
    let dict = Arc::new(dict);
    let cases_src = std::fs::read_to_string(&cases_path)
        .map_err(|e| format!("读不到 {cases_path}: {e}"))?;

    let run = |keys: &str| -> Vec<String> {
        let mut s = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in keys.chars() {
            s.feed(ch);
        }
        s.composition()
            .candidates
            .iter()
            .take(5)
            .map(|c| c.text.clone())
            .collect()
    };

    let mut groups: BTreeMap<String, (usize, usize, usize)> = BTreeMap::new();
    let mut fails = Vec::new();
    let (mut t1, mut t5, mut n) = (0usize, 0usize, 0usize);
    for line in cases_src.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            continue;
        }
        let (g, keys, want) = (f[0], f[1], f[2]);
        let got = run(keys);
        let e = groups.entry(g.to_string()).or_insert((0, 0, 0));
        e.2 += 1;
        n += 1;
        if got.first().map(String::as_str) == Some(want) {
            e.0 += 1;
            t1 += 1;
        } else {
            fails.push(format!("[{g}] {keys} → 期望「{want}」实际 {:?}", got));
        }
        if got.iter().any(|c| c == want) {
            e.1 += 1;
            t5 += 1;
        }
    }

    // 学习能力：在 setup 按键下选中一次目标词后，test 按键的首选应体现它。
    // 前两条考「选一次就记住」，后两条考「个人词进入整句解码」。
    let learn_cases = [
        ("shiyan", "试验", "shiyan", "试验"),
        ("gongshi", "攻势", "gongshi", "攻势"),
        ("huifu", "回复", "wohuijinkuaihuifuni", "我会尽快回复你"),
        ("kuaidi", "快递", "kuaididaole", "快递到了"),
    ];
    let mut learn_ok = 0;
    for (setup, word, test, want) in learn_cases {
        let mut s = Session::with_mode(dict.clone(), Mode::Pinyin);
        for ch in setup.chars() {
            s.feed(ch);
        }
        let found = match s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == word)
        {
            Some(i) => {
                s.select(i);
                true
            }
            None => {
                s.clear();
                false
            }
        };
        s.reset_context();
        for ch in test.chars() {
            s.feed(ch);
        }
        let top = s
            .composition()
            .candidates
            .first()
            .map(|c| c.text.clone())
            .unwrap_or_default();
        if found && top == want {
            learn_ok += 1;
        } else {
            fails.push(format!(
                "[学习] 选一次「{word}」后 {test} 首选「{top}」≠「{want}」(候选里{})",
                if found { "有" } else { "没有" }
            ));
        }
    }

    println!("\n═══ 松萝困难评测集 ═══");
    println!("  {:<8} {:>9} {:>9}", "分组", "Top-1", "Top-5");
    for (g, (a, b, c)) in &groups {
        println!(
            "  {g:<8} {a:>3}/{c:<3}{:>3}%  {b:>3}/{c:<3}{:>3}%",
            a * 100 / c,
            b * 100 / c
        );
    }
    println!("  ──────────────────────────────");
    println!(
        "  总计     {t1:>3}/{n:<3}{:>3}%  {t5:>3}/{n:<3}{:>3}%",
        t1 * 100 / n,
        t5 * 100 / n
    );
    println!("  学习     {learn_ok}/{}", learn_cases.len());
    if !fails.is_empty() {
        println!("\n  失败明细:");
        for f in &fails {
            println!("    {f}");
        }
    }
    Ok(())
}
