//! C ABI。所有函数内部捕获 panic，绝不跨 FFI 边界展开。
//!
//! 安全契约（与 `include/liana.h` 一致）：传入的指针必须指向有效对象；
//! `liana_new*` 的字符串参数必须是 NUL 结尾的 UTF-8；返回的 `char*` 必须用
//! `liana_free_string` 释放。所有 `unsafe` 导出函数都在此契约下工作。
#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use liana_core::Mode;
use liana_dict::Dictionary;
use liana_engine::Session;
use liana_engine::app_mode::AppModeMemory;
use liana_engine::evolution::{self, EvolutionMemory};
use liana_plugin::Pack as PluginPack;

pub struct LianaSession {
    inner: Session,
}

/// 每应用中英模式记忆（独立于输入会话：跨应用共享一份）。
pub struct LianaAppMode {
    inner: AppModeMemory,
}

/// 知你自进化账本（ADR-0008 决策层）。
pub struct LianaEvolution {
    inner: EvolutionMemory,
}

/// 解析候选 JSON `[{"text":"现","score":10.5},...]` → (词, base 分) 列表。
/// 只认这个固定形状，宽容空白；坏对象跳过。
fn parse_candidates(json: &str) -> Vec<(String, f32)> {
    let mut out = Vec::new();
    let bytes = json.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'{' {
            i += 1;
            continue;
        }
        let end = match json[i..].find('}') {
            Some(e) => i + e,
            None => break,
        };
        let obj = &json[i..=end];
        let text = obj
            .find("\"text\"")
            .and_then(|p| obj[p + 6..].find('"').map(|q| p + 6 + q + 1))
            .and_then(|s| obj[s..].find('"').map(|e| obj[s..s + e].to_string()));
        let score = obj
            .find("\"score\"")
            .and_then(|p| {
                let rest = &obj[p + 7..];
                let num: String = rest
                    .chars()
                    .skip_while(|c| !c.is_ascii_digit() && *c != '-')
                    .take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-' || *c == 'e')
                    .collect();
                num.parse::<f32>().ok()
            });
        if let (Some(t), Some(sc)) = (text, score) {
            out.push((t, sc));
        }
        i = end + 1;
    }
    out
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

impl LianaSession {
    fn new(dict: Arc<Dictionary>, mode: Mode) -> Self {
        let mut inner = Session::with_mode(dict, mode);
        // 知你账本是进程级单例：IMK 下每个应用各有一个会话，
        // 学习必须跨应用沉淀才叫「越用越懂你」。
        inner.set_evolution_memory(shared_evolution());
        Self { inner }
    }
}

/// 进程内共享的知你账本。会话构造时注入；`liana_evolution_session_*`
/// 系列经由任意会话读写同一份。E0 的独立句柄 API 不受影响（各自私有）。
fn shared_evolution() -> Arc<Mutex<EvolutionMemory>> {
    static LEDGER: OnceLock<Arc<Mutex<EvolutionMemory>>> = OnceLock::new();
    LEDGER
        .get_or_init(|| Arc::new(Mutex::new(EvolutionMemory::new())))
        .clone()
}

unsafe fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .ok()
        .map(str::to_string)
}

fn mode_of(s: Option<String>) -> Mode {
    s.as_deref().and_then(Mode::from_id).unwrap_or(Mode::Pinyin)
}

fn into_c(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn guard_ptr<F: FnOnce() -> *mut c_char>(f: F) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(std::ptr::null_mut())
}

fn guard_int<F: FnOnce() -> i32>(f: F) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_new(mode: *const c_char) -> *mut LianaSession {
    let mode = unsafe { cstr(mode) };
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(LianaSession::new(
            Arc::new(Dictionary::embedded()),
            mode_of(mode),
        )))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_new_with_dict(
    mode: *const c_char,
    dict_path: *const c_char,
) -> *mut LianaSession {
    let mode = unsafe { cstr(mode) };
    let path = unsafe { cstr(dict_path) };
    catch_unwind(AssertUnwindSafe(|| {
        let dict = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| Dictionary::from_bytes(&b).ok())
            .unwrap_or_else(Dictionary::embedded);
        Box::into_raw(Box::new(LianaSession::new(
            Arc::new(dict),
            mode_of(mode),
        )))
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// 词包里没写词频的词给的默认词频（与 base-large.tsv 同尺度，约等于中等常用词）。
const LAYER_DEFAULT_FREQ: u32 = 1000;

/// 进程级词库缓存：基础词库与词包文件（路径 + 大小 + 修改时间）都没变就复用同一份，
/// 每个输入会话不必各自重新解析几 MB 的词库。
static DICT_CACHE: Mutex<Option<(String, Arc<Dictionary>)>> = Mutex::new(None);

/// 词包目录里的 `*.tsv` / `*.txt`（按文件名排序）。
fn layer_files(dir: Option<&str>) -> Vec<std::path::PathBuf> {
    let Some(dir) = dir else { return Vec::new() };
    let Ok(read_dir) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<_> = read_dir
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "tsv" || x == "txt"))
        .collect();
    files.sort();
    files
}

fn file_signature(path: &Path) -> String {
    let meta = std::fs::metadata(path).ok();
    let len = meta.as_ref().map(|m| m.len()).unwrap_or(0);
    let modified = meta
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}:{len}:{modified}", path.display())
}

/// 基础词库 + 词包目录：词包一行一个词（可选「词<TAB>拼音<TAB>词频」），没写拼音的自动注音，
/// 同词同音取较大词频（词包只补词、抬词频）。
fn load_layered(base_path: Option<&str>, layers_dir: Option<&str>) -> Arc<Dictionary> {
    let files = layer_files(layers_dir);
    // 字级搭配模型：基础词库旁边的 base.lm（没有就只用词频）
    let lm_path = base_path.map(|p| Path::new(p).with_file_name("base.lm"));
    let mut signature = base_path.map(|p| file_signature(Path::new(p))).unwrap_or_default();
    if let Some(lm) = &lm_path {
        signature.push('|');
        signature.push_str(&file_signature(lm));
    }
    for f in &files {
        signature.push('|');
        signature.push_str(&file_signature(f));
    }
    if let Ok(cache) = DICT_CACHE.lock() {
        if let Some((sig, dict)) = cache.as_ref() {
            if *sig == signature {
                return dict.clone();
            }
        }
    }
    let mut dict = base_path
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| Dictionary::from_bytes(&b).ok())
        .unwrap_or_else(Dictionary::embedded);
    if let Some(lm) = lm_path
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| liana_dict::lm::Collocations::from_bytes(&b).ok())
    {
        dict.set_collocations(Some(Arc::new(lm)));
    }
    for f in &files {
        if let Ok(text) = std::fs::read_to_string(f) {
            let (layer, _) = liana_dict::import::parse_word_list(&text, &dict, LAYER_DEFAULT_FREQ);
            dict.merge(&layer);
        }
    }
    let dict = Arc::new(dict);
    if let Ok(mut cache) = DICT_CACHE.lock() {
        *cache = Some((signature, dict.clone()));
    }
    dict
}

/// 基础词库 + 词包目录（如 `~/Library/Application Support/Liana/dicts`，里面是本机应用名等词包）。
/// 进程内共享同一份词库，文件变化后新建的会话自动用上新词库。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_new_with_layers(
    mode: *const c_char,
    dict_path: *const c_char,
    layers_dir: *const c_char,
) -> *mut LianaSession {
    let mode = unsafe { cstr(mode) };
    let path = unsafe { cstr(dict_path) };
    let layers = unsafe { cstr(layers_dir) };
    catch_unwind(AssertUnwindSafe(|| {
        let dict = load_layered(path.as_deref(), layers.as_deref());
        Box::into_raw(Box::new(LianaSession::new(dict, mode_of(mode))))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_free(session: *mut LianaSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(session) });
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_feed(
    session: *mut LianaSession,
    utf8_char: *const c_char,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let s = unsafe { cstr(utf8_char) };
    guard_int(|| {
        let Some(ch) = s.as_deref().and_then(|x| x.chars().next()) else {
            return 0;
        };
        let session = unsafe { &mut *session };
        i32::from(session.inner.feed(ch))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_backspace(session: *mut LianaSession) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &mut *session };
        i32::from(session.inner.backspace())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_clear(session: *mut LianaSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let session = unsafe { &mut *session };
        session.inner.clear();
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_set_mode(
    session: *mut LianaSession,
    mode: *const c_char,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let mode = unsafe { cstr(mode) };
    guard_int(|| {
        let Some(m) = mode.as_deref().and_then(Mode::from_id) else {
            return 0;
        };
        let session = unsafe { &mut *session };
        session.inner.set_mode(m);
        1
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_mode(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.mode().id().to_string())
    })
}

/// 简繁显示开关：非 0 表示候选转成繁体。返回 1 表示设置成功。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_set_traditional(session: *mut LianaSession, on: i32) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &mut *session };
        session.inner.set_traditional(on != 0);
        1
    })
}

/// 当前是否繁体显示。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_traditional(session: *mut LianaSession) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &*session };
        i32::from(session.inner.traditional())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_composition_json(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(composition_json(&session.inner))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_select(
    session: *mut LianaSession,
    index: u32,
) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &mut *session };
        match session.inner.select(index as usize) {
            Some(text) => into_c(text),
            None => std::ptr::null_mut(),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_commit_raw(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &mut *session };
        match session.inner.commit_raw() {
            Some(text) => into_c(text),
            None => std::ptr::null_mut(),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_user_export(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.user_model().export_tsv())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_user_import(
    session: *mut LianaSession,
    tsv: *const c_char,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let session = unsafe { &mut *session };
        session.inner.user_model_mut().import_tsv(&tsv) as i32
    })
}

/// 外部文本上屏（语音等）的学习入口：记词并更新二元组上下文。
/// 成功返回 0，参数无效返回 -1。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_record_commit(
    session: *mut LianaSession,
    text: *const c_char,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let text = unsafe { cstr(text) };
    guard_int(|| {
        let Some(text) = text else { return -1 };
        let session = unsafe { &mut *session };
        session.inner.commit_external(&text);
        0
    })
}

/// 导出用户数据备份包（明文 TSV + 版本头 + CRC32）。前端负责加密落盘。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_backup_export(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.export_backup())
    })
}

/// 导入备份包。`merge` 非 0 时同名条目取较大次数；返回条目数，失败返回 -1。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_backup_import(
    session: *mut LianaSession,
    text: *const c_char,
    merge: i32,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let text = unsafe { cstr(text) };
    guard_int(|| {
        let Some(text) = text else { return -1 };
        let session = unsafe { &mut *session };
        match session.inner.import_backup(&text, merge != 0) {
            Ok(n) => n as i32,
            Err(_) => -1,
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { CString::from_raw(s) });
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn liana_version() -> *const c_char {
    static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr().cast()
}


fn composition_json(session: &Session) -> String {
    let comp = session.composition();
    // 英文串判定与内核同源：没有任何全覆盖汉字候选 → 前端空格原样上屏、
    // 数字键不再选候选（网址/邮箱/版本号直打）。
    let raw_len = comp.raw.chars().count();
    let english_like = !comp.raw.is_empty()
        && !comp
            .candidates
            .iter()
            .any(|c| c.consumed == raw_len && c.text.chars().any(liana_engine::is_cjk_char));
    let mut out = String::with_capacity(96 + comp.candidates.len() * 48);
    out.push_str("{\"mode\":\"");
    out.push_str(session.mode().id());
    out.push_str("\",\"raw\":\"");
    out.push_str(&json_escape(&comp.raw));
    out.push_str("\",\"preedit\":\"");
    out.push_str(&json_escape(&comp.preedit));
    out.push_str("\",\"englishLike\":");
    out.push_str(if english_like { "true" } else { "false" });
    out.push_str(",\"candidates\":[");
    for (i, c) in comp.candidates.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"text\":\"");
        out.push_str(&json_escape(&c.text));
        out.push_str("\",\"consumed\":");
        out.push_str(&c.consumed.to_string());
        out.push_str(",\"kind\":\"");
        out.push_str(c.kind.id());
        out.push('"');
        if let Some(comment) = &c.comment {
            out.push_str(",\"comment\":\"");
            out.push_str(&json_escape(comment));
            out.push('"');
        }
        if let Some(reading) = c.comment_role.reading_id() {
            out.push_str(",\"reading\":\"");
            out.push_str(reading);
            out.push('"');
        }
        out.push('}');
    }
    out.push_str("]}");
    out
}

/// 本地 AI 增强：模型目录 JSON（静态信息，前端用于渲染选择列表）。
#[unsafe(no_mangle)]
pub extern "C" fn liana_ai_catalog_json() -> *mut c_char {
    guard_ptr(|| into_c(liana_ai::catalog_json()))
}

/// 本地 AI 增强：按系统总内存给出每个用途的推荐模型 JSON。
#[unsafe(no_mangle)]
pub extern "C" fn liana_ai_recommend_json(total_ram_mb: u64) -> *mut c_char {
    guard_ptr(|| into_c(liana_ai::recommend_json(total_ram_mb)))
}

/// 扫描插件目录（皮肤/桌宠/词典数据包），返回目录 JSON：
/// `{"packs":[{"id","name","version","kind","authors","description","license","permissions","dir"}],
///   "errors":[{"dir","error"}]}`。坏包跳过不中断。调用方释放。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_plugin_scan_json(dir: *const c_char) -> *mut c_char {
    let dir = unsafe { cstr(dir) };
    guard_ptr(|| {
        let Some(dir) = dir else {
            return std::ptr::null_mut();
        };
        let (packs, errors) = PluginPack::scan(Path::new(&dir));
        into_c(PluginPack::catalog_json(&packs, &errors))
    })
}

/// 输入统计总结（全为计数，零内容）：返回指标 JSON：
/// `{"speed_cpm","accuracy","kcal","saved_keys","voice_chars","deletes","enters",
///   "stare_max_secs","top1_rate","base_top1_rate","reselect_rate"}`。
/// 后四项为 E3 评估层：首选命中率 / 反事实首选命中率 / 重选率（百分数，
/// 无选词时为 0；反事实 = 剔除学习修正的基线排序，两者之差即学习收益）。
#[unsafe(no_mangle)]
pub extern "C" fn liana_stats_digest_json(
    chars: u64,
    keys: u64,
    deletes: u64,
    enters: u64,
    saved_keys: u64,
    voice_chars: u64,
    active_secs: u64,
    stare_max_secs: u64,
    selections: u64,
    top1_hits: u64,
    base_top1_hits: u64,
    reselects: u64,
) -> *mut c_char {
    guard_ptr(|| {
        let digest = liana_engine::stats::Digest::compute(&liana_engine::stats::DayStats {
            chars,
            keys,
            deletes,
            enters,
            saved_keys,
            voice_chars,
            active_secs,
            stare_max_secs,
            selections,
            top1_hits,
            base_top1_hits,
            reselects,
        });
        into_c(digest.to_json())
    })
}

// ──────────────────── 知你自进化（ADR-0008 决策层） ────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn liana_evolution_new() -> *mut LianaEvolution {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(LianaEvolution {
            inner: EvolutionMemory::new(),
        }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_free(memory: *mut LianaEvolution) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(memory) });
    }));
}

/// 记录一次奖励：reward_x100 ∈ {100 选词, 150 重选, -200 删除, 60 次选}。
/// lex_window 为最近上屏文本；app 可为空串；hour 0-23；now Unix 秒。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_reward(
    memory: *mut LianaEvolution,
    word: *const c_char,
    lex_window: *const c_char,
    app: *const c_char,
    hour: u32,
    reward_x100: i32,
    now: u64,
) -> i32 {
    if memory.is_null() {
        return 0;
    }
    let (word, lex, app) = unsafe { (cstr(word), cstr(lex_window), cstr(app)) };
    guard_int(|| {
        let Some(word) = word else { return 0 };
        let lex = lex.unwrap_or_default();
        let app = app.unwrap_or_default();
        let features = evolution::context_features(&lex, if app.is_empty() { None } else { Some(&app) }, hour);
        let features = [features, evolution::topic_features(&lex, 3)].concat();
        let memory = unsafe { &mut *memory };
        memory.inner.reward(&word, &features, reward_x100 as f32 / 100.0, now);
        1
    })
}

/// 候选重排：输入 `[{"text":"现","score":10.5},...]`，
/// 输出按修正后分数降序的 `[{"text":..,"score":..,"delta":..},...]`。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_adjust_json(
    memory: *mut LianaEvolution,
    candidates_json: *const c_char,
    lex_window: *const c_char,
    app: *const c_char,
    hour: u32,
    now: u64,
) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    let (cands, lex, app) = unsafe { (cstr(candidates_json), cstr(lex_window), cstr(app)) };
    guard_ptr(|| {
        let Some(cands) = cands else { return std::ptr::null_mut() };
        let lex = lex.unwrap_or_default();
        let app = app.unwrap_or_default();
        let mut features =
            evolution::context_features(&lex, if app.is_empty() { None } else { Some(&app) }, hour);
        features.extend(evolution::topic_features(&lex, 3));
        let ranked = unsafe { &*memory }.inner.rank(&parse_candidates(&cands), &features, now);
        let mut out = String::from("[");
        for (i, (text, score, delta)) in ranked.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"text\":\"{}\",\"score\":{:.3},\"delta\":{:.3}}}",
                json_escape(text),
                score,
                delta
            ));
        }
        out.push(']');
        into_c(out)
    })
}

/// 决策轨道：这个词在该上下文里的贡献特征 [{"feature":..,"affinity":..},...]。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_explain_json(
    memory: *mut LianaEvolution,
    word: *const c_char,
    lex_window: *const c_char,
    app: *const c_char,
    hour: u32,
    now: u64,
) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    let (word, lex, app) = unsafe { (cstr(word), cstr(lex_window), cstr(app)) };
    guard_ptr(|| {
        let Some(word) = word else { return std::ptr::null_mut() };
        let lex = lex.unwrap_or_default();
        let app = app.unwrap_or_default();
        let mut features =
            evolution::context_features(&lex, if app.is_empty() { None } else { Some(&app) }, hour);
        features.extend(evolution::topic_features(&lex, 3));
        let trail = unsafe { &*memory }.inner.explain(&word, &features, now);
        let mut out = String::from("[");
        for (i, (f, a)) in trail.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"feature\":\"{}\",\"affinity\":{:.3}}}",
                json_escape(f),
                a
            ));
        }
        out.push(']');
        into_c(out)
    })
}

/// 学习账本 TSV 导出/导入（词\t特征\t亲和度\t观察数\t最后触摸）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_export(memory: *mut LianaEvolution) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let memory = unsafe { &*memory };
        into_c(memory.inner.export_tsv())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_import(
    memory: *mut LianaEvolution,
    tsv: *const c_char,
) -> i32 {
    if memory.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let memory = unsafe { &mut *memory };
        memory.inner.import_tsv(&tsv) as i32
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_forget_all(memory: *mut LianaEvolution) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        unsafe { &mut *memory }.inner.forget_all();
    }));
}

// ──────────── 知你教学层接线（ADR-0008 E1，会话侧共享账本） ────────────

/// 同步决策上下文与开关：`app` 可为空串；`hour` 0-23；`enabled` 非 0 开学习；
/// `now`（Unix 秒）同时刷新重排衰减时钟。返回 1 表示已设置。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_set_evolution_context(
    session: *mut LianaSession,
    app: *const c_char,
    hour: u32,
    enabled: i32,
    now: u64,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let app = unsafe { cstr(app) };
    guard_int(|| {
        let session = unsafe { &mut *session };
        session
            .inner
            .set_evolution_context(app.as_deref(), hour, enabled != 0, now);
        1
    })
}

/// 前端确认一次选词：`alt_rank` 非 0 表示数字键选了第 2+ 候选（+0.6），
/// 否则正常选词（+1.0）；删除后的窗口内重选自动升级为强正（+1.5）。
/// 必须在 `liana_select` 成功后调用一次；返回 1 表示已记账。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_note_selection(
    session: *mut LianaSession,
    alt_rank: i32,
    now: u64,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &mut *session };
        session.inner.note_selection(alt_rank != 0, now);
        1
    })
}

/// 前端看到无组合态的删除键：按「选了又删」记强负（−2）并武装重选期待。
/// 窗口外、重复删除或无上次选词时静默忽略。返回 1 表示已记账。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_note_delete(session: *mut LianaSession, now: u64) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &mut *session };
        session.inner.note_delete(now);
        1
    })
}

/// 取走最近一次选词的评估（E3 反事实对比）：
/// `{"actualTop1":bool,"baseTop1":bool,"reselect":bool,"altRank":bool}`；
/// 无待取评估时返回 NULL。必须在 note_selection 之后调用。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_eval_json(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &mut *session };
        let Some(e) = session.inner.take_selection_eval() else {
            return std::ptr::null_mut();
        };
        into_c(format!(
            "{{\"actualTop1\":{},\"baseTop1\":{},\"reselect\":{},\"altRank\":{}}}",
            e.actual_top1, e.base_top1, e.reselect, e.alt_rank
        ))
    })
}

/// 共享账本 TSV 导出/导入/清空（与 E0 独立句柄同格式，经会话访问进程单例）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_session_export(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.export_evolution())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_session_import(
    session: *mut LianaSession,
    tsv: *const c_char,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let session = unsafe { &mut *session };
        session.inner.import_evolution(&tsv) as i32
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_evolution_session_forget(session: *mut LianaSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        unsafe { &mut *session }.inner.forget_evolution();
    }));
}

// ──────────── 知你喂食层（ADR-0008 E2）：术语提炼 + 营养库 ────────────

/// 术语提炼（纯函数）：输入文档文本，输出
/// `[{"term":"县政府","count":5},...]`（次数降序，上限 50）。调用方释放。
#[unsafe(no_mangle)]
pub extern "C" fn liana_feed_extract_json(text: *const c_char) -> *mut c_char {
    let text = unsafe { cstr(text) };
    guard_ptr(|| {
        let Some(text) = text else {
            return std::ptr::null_mut();
        };
        let terms = liana_engine::feed::extract_terms(&text);
        let mut out = String::from("[");
        for (i, (term, count)) in terms.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"term\":\"{}\",\"count\":{}}}",
                json_escape(term),
                count
            ));
        }
        out.push(']');
        into_c(out)
    })
}

/// 喂入一条营养词：按键串由内核按词典读音派生；返回 1 表示已入库。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_nutrition_add(
    session: *mut LianaSession,
    term: *const c_char,
    source: *const c_char,
    strength: u32,
    now: u64,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let (term, source) = unsafe { (cstr(term), cstr(source)) };
    guard_int(|| {
        let Some(term) = term else { return 0 };
        let session = unsafe { &mut *session };
        i32::from(session.inner.nutrition_add(&term, source.as_deref().unwrap_or(""), strength, now))
    })
}

/// 营养库列举（按加入时间倒序）：
/// `[{"term":..,"keys":..,"source":..,"strength":..,"addedAt":..},...]`。调用方释放。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_nutrition_list_json(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        let mut out = String::from("[");
        for (i, (term, e)) in session.inner.nutrition().list().iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"term\":\"{}\",\"keys\":\"{}\",\"source\":\"{}\",\"strength\":{},\"addedAt\":{}}}",
                json_escape(term),
                json_escape(&e.keys),
                json_escape(&e.source),
                e.strength,
                e.added_at
            ));
        }
        out.push(']');
        into_c(out)
    })
}

/// 忘记一条营养词：返回 1 表示存在过并已删除。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_nutrition_forget(
    session: *mut LianaSession,
    term: *const c_char,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let term = unsafe { cstr(term) };
    guard_int(|| {
        let Some(term) = term else { return 0 };
        let session = unsafe { &mut *session };
        i32::from(session.inner.nutrition_forget(&term))
    })
}

/// 清空营养库。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_nutrition_forget_all(session: *mut LianaSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        unsafe { &mut *session }.inner.nutrition_forget_all();
    }));
}

/// 营养库 TSV 导出/导入（词\t按键串\t出处\t强度\t加入时间）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_nutrition_export(session: *mut LianaSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.nutrition_export())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_nutrition_import(
    session: *mut LianaSession,
    tsv: *const c_char,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let session = unsafe { &mut *session };
        session.inner.nutrition_import(&tsv) as i32
    })
}

// ──────────────────── 每应用中英模式记忆 ────────────────────
#[unsafe(no_mangle)]
pub extern "C" fn liana_app_mode_new() -> *mut LianaAppMode {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(LianaAppMode {
            inner: AppModeMemory::new(),
        }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_free(memory: *mut LianaAppMode) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(memory) });
    }));
}

/// 记录一次信号：`zh` 非 0 表示中文侧，`strong` 非 0 表示手动切换（Shift/菜单），
/// 否则为上屏弱信号；`now` 为 Unix 秒。返回 1 表示已记录（应用 id 非法时为 0）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_observe(
    memory: *mut LianaAppMode,
    app_id: *const c_char,
    zh: i32,
    strong: i32,
    now: u64,
) -> i32 {
    if memory.is_null() {
        return 0;
    }
    let app = unsafe { cstr(app_id) };
    guard_int(|| {
        let Some(app) = app else { return 0 };
        let memory = unsafe { &mut *memory };
        i32::from(memory.inner.observe(&app, zh != 0, strong != 0, now))
    })
}

/// 该应用现在该用中文还是英文？返回 1 = 中文，0 = 英文，-1 = 样本不足不干预。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_decide(
    memory: *mut LianaAppMode,
    app_id: *const c_char,
    now: u64,
) -> i32 {
    if memory.is_null() {
        return -1;
    }
    let app = unsafe { cstr(app_id) };
    guard_int(|| {
        let Some(app) = app else { return -1 };
        let memory = unsafe { &*memory };
        match memory.inner.decide(&app, now) {
            Some(true) => 1,
            Some(false) => 0,
            None => -1,
        }
    })
}

/// 忘记单个应用的偏好。返回 1 表示存在过并已删除。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_forget(
    memory: *mut LianaAppMode,
    app_id: *const c_char,
) -> i32 {
    if memory.is_null() {
        return 0;
    }
    let app = unsafe { cstr(app_id) };
    guard_int(|| {
        let Some(app) = app else { return 0 };
        let memory = unsafe { &mut *memory };
        i32::from(memory.inner.forget(&app))
    })
}

/// 清空全部学习结果（关闭学习开关时调用，不留数据）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_forget_all(memory: *mut LianaAppMode) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let memory = unsafe { &mut *memory };
        memory.inner.forget_all();
    }));
}

/// 导出学习结果 TSV（前端负责持久化；只含 bundle id 与票数，无按键内容）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_export(memory: *mut LianaAppMode) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let memory = unsafe { &*memory };
        into_c(memory.inner.export_tsv())
    })
}

/// 导入学习结果 TSV，返回导入行数。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn liana_app_mode_import(
    memory: *mut LianaAppMode,
    tsv: *const c_char,
) -> i32 {
    if memory.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let memory = unsafe { &mut *memory };
        memory.inner.import_tsv(&tsv) as i32
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn call_str(f: impl FnOnce() -> *mut c_char) -> Option<String> {
        let p = f();
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_str().ok()?.to_string();
        unsafe { liana_free_string(p) };
        Some(s)
    }

    #[test]
    fn end_to_end_via_c_abi() {
        let session = unsafe { liana_new(c"pinyin".as_ptr()) };
        assert!(!session.is_null());
        unsafe {
            for ch in ["n", "i", "h", "a", "o"] {
                let c = CString::new(ch).unwrap();
                assert_eq!(liana_feed(session, c.as_ptr()), 1);
            }
            let json = call_str(|| liana_composition_json(session)).unwrap();
            assert!(json.contains("\"preedit\":\"ni hao\""), "{json}");
            assert!(json.contains("你好"), "{json}");
            assert!(
                json.contains("\"comment\":\"ni hao\",\"reading\":\"exact\""),
                "精确读音应标记 exact: {json}"
            );
            let text = call_str(|| liana_select(session, 0)).unwrap();
            assert_eq!(text, "你好");
            let json = call_str(|| liana_composition_json(session)).unwrap();
            assert!(json.contains("\"raw\":\"\""), "{json}");
            liana_free(session);
        }
    }

    #[test]
    fn null_and_bad_args_are_safe() {
        unsafe {
            assert!(liana_composition_json(std::ptr::null_mut()).is_null());
            assert_eq!(liana_feed(std::ptr::null_mut(), c"a".as_ptr()), 0);
            assert!(liana_select(std::ptr::null_mut(), 0).is_null());
            assert_eq!(liana_set_mode(std::ptr::null_mut(), c"en".as_ptr()), 0);
        }
    }

    #[test]
    fn mode_switch_and_user_tsv_roundtrip() {
        let session = unsafe { liana_new(c"en".as_ptr()) };
        unsafe {
            let m = call_str(|| liana_mode(session)).unwrap();
            assert_eq!(m, "en");
            assert_eq!(liana_set_mode(session, c"flypy".as_ptr()), 1);
            assert_eq!(call_str(|| liana_mode(session)).unwrap(), "flypy");
            assert_eq!(liana_user_import(session, c"你好\t3\n".as_ptr()), 1);
            let tsv = call_str(|| liana_user_export(session)).unwrap();
            assert_eq!(tsv, "你好\t3\n");
            liana_free(session);
        }
    }

    #[test]
    fn traditional_toggle_via_c_abi() {
        let session = unsafe { liana_new(c"pinyin".as_ptr()) };
        unsafe {
            assert_eq!(liana_traditional(session), 0);
            assert_eq!(liana_set_traditional(session, 1), 1);
            assert_eq!(liana_traditional(session), 1);
            for ch in ["x", "u", "e", "x", "i"] {
                let c = CString::new(ch).unwrap();
                liana_feed(session, c.as_ptr());
            }
            let json = call_str(|| liana_composition_json(session)).unwrap();
            assert!(json.contains("學習"), "{json}");
            liana_free(session);
        }
    }

    #[test]
    fn backup_roundtrip_via_c_abi() {
        let a = unsafe { liana_new(c"pinyin".as_ptr()) };
        let b = unsafe { liana_new(c"pinyin".as_ptr()) };
        unsafe {
            assert_eq!(liana_user_import(a, c"你好\t3\n".as_ptr()), 1);
            let pack = call_str(|| liana_backup_export(a)).unwrap();
            assert!(pack.starts_with("#IFBAK1"), "{pack}");

            let c_pack = CString::new(pack).unwrap();
            assert_eq!(liana_backup_import(b, c_pack.as_ptr(), 0), 1);
            assert_eq!(call_str(|| liana_user_export(b)).unwrap(), "你好\t3\n");

            assert_eq!(liana_backup_import(b, c"坏包".as_ptr(), 0), -1);
            assert_eq!(
                liana_backup_import(std::ptr::null_mut(), c_pack.as_ptr(), 0),
                -1
            );
            liana_free(a);
            liana_free(b);
        }
    }

    #[test]
    fn version_is_not_null() {
        let p = liana_version();
        assert!(!p.is_null());
        let v = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(!v.is_empty());
    }

    #[test]
    fn ai_catalog_and_recommend_json() {
        let cat = unsafe { call_str(|| liana_ai_catalog_json()) }.unwrap();
        assert!(cat.contains("\"id\":\"whisper-base\""), "{cat}");

        let rec = unsafe { call_str(|| liana_ai_recommend_json(16 * 1024)) }.unwrap();
        assert!(rec.contains("\"kind\":\"speech\""), "{rec}");
        assert!(rec.contains("\"level\":\"suggested\""), "{rec}");
    }

    #[test]
    fn app_mode_memory_via_c_abi() {
        let mem = liana_app_mode_new();
        assert!(!mem.is_null());
        unsafe {
            // 手动切到英文（强信号）→ 判英文；换应用 → 不干预
            assert_eq!(
                liana_app_mode_observe(mem, c"com.apple.Terminal".as_ptr(), 0, 1, 1_000),
                1
            );
            assert_eq!(
                liana_app_mode_decide(mem, c"com.apple.Terminal".as_ptr(), 1_000),
                0
            );
            assert_eq!(
                liana_app_mode_decide(mem, c"com.other.app".as_ptr(), 1_000),
                -1
            );

            // 非法应用 id 被忽略
            assert_eq!(
                liana_app_mode_observe(mem, c"".as_ptr(), 1, 1, 1_000),
                0
            );
            assert_eq!(
                liana_app_mode_observe(mem, c"a\tb".as_ptr(), 1, 1, 1_000),
                0
            );

            // 导出 → 导入另一个实例 → 判定一致
            let tsv = call_str(|| liana_app_mode_export(mem)).unwrap();
            let other = liana_app_mode_new();
            let c_tsv = CString::new(tsv).unwrap();
            assert_eq!(liana_app_mode_import(other, c_tsv.as_ptr()), 1);
            assert_eq!(
                liana_app_mode_decide(other, c"com.apple.Terminal".as_ptr(), 1_000),
                0
            );

            // 忘记后不再判定
            assert_eq!(
                liana_app_mode_forget(other, c"com.apple.Terminal".as_ptr()),
                1
            );
            assert_eq!(
                liana_app_mode_decide(other, c"com.apple.Terminal".as_ptr(), 1_000),
                -1
            );
            liana_app_mode_free(other);
            liana_app_mode_free(mem);
        }
    }

    #[test]
    fn app_mode_null_and_bad_args_are_safe() {
        unsafe {
            assert_eq!(
                liana_app_mode_observe(std::ptr::null_mut(), c"a".as_ptr(), 1, 1, 0),
                0
            );
            assert_eq!(
                liana_app_mode_decide(std::ptr::null_mut(), c"a".as_ptr(), 0),
                -1
            );
            assert_eq!(
                liana_app_mode_forget(std::ptr::null_mut(), c"a".as_ptr()),
                0
            );
            assert!(liana_app_mode_export(std::ptr::null_mut()).is_null());
            assert_eq!(
                liana_app_mode_import(std::ptr::null_mut(), c"x".as_ptr()),
                -1
            );
            liana_app_mode_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn evolution_via_c_abi() {
        let mem = liana_evolution_new();
        assert!(!mem.is_null());
        unsafe {
            let word = CString::new("先").unwrap();
            let lex = CString::new("优先").unwrap();
            let app = CString::new("com.apple.Notes").unwrap();
            let cands = CString::new(
                r#"[{"text":"现","score":10.5},{"text":"先","score":9.0}]"#,
            )
            .unwrap();

            // 一次奖励不足置信
            liana_evolution_reward(mem, word.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 100, 1_000);
            let out = call_str(|| {
                liana_evolution_adjust_json(mem, cands.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 1_100)
            })
            .unwrap();
            assert!(out.starts_with("\"text\":\"现\"") || out.contains("\"text\":\"现\""), "{out}");

            // 两次奖励后上浮
            liana_evolution_reward(mem, word.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 100, 1_200);
            let out = call_str(|| {
                liana_evolution_adjust_json(mem, cands.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 1_300)
            })
            .unwrap();
            assert!(out.find("\"text\":\"先\"").unwrap() < out.find("\"text\":\"现\"").unwrap(), "{out}");
            assert!(out.contains("\"delta\""), "{out}");

            // 决策轨道
            let trail = call_str(|| {
                liana_evolution_explain_json(mem, word.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 1_400)
            })
            .unwrap();
            assert!(trail.contains("\"feature\":\"lex:"), "{trail}");

            // 导出/导入回环
            let tsv = call_str(|| liana_evolution_export(mem)).unwrap();
            let other = liana_evolution_new();
            let c_tsv = CString::new(tsv).unwrap();
            assert!(liana_evolution_import(other, c_tsv.as_ptr()) >= 1);
            liana_evolution_forget_all(other);
            liana_evolution_free(other);
            liana_evolution_free(mem);
        }
    }

    #[test]
    fn evolution_null_args_are_safe() {
        unsafe {
            let w = c"先".as_ptr();
            assert_eq!(
                liana_evolution_reward(std::ptr::null_mut(), w, w, w, 0, 100, 0),
                0
            );
            assert!(liana_evolution_adjust_json(std::ptr::null_mut(), w, w, w, 0, 0).is_null());
            assert!(liana_evolution_explain_json(std::ptr::null_mut(), w, w, w, 0, 0).is_null());
            assert!(liana_evolution_export(std::ptr::null_mut()).is_null());
            assert_eq!(liana_evolution_import(std::ptr::null_mut(), w), -1);
            liana_evolution_free(std::ptr::null_mut());
            liana_evolution_forget_all(std::ptr::null_mut());
        }
    }

    /// 取当前组合态首个候选文本（E1 教学序列测试用）。
    unsafe fn first_candidate_text(session: *mut LianaSession) -> Option<String> {
        let json = unsafe { call_str(|| unsafe { liana_composition_json(session) }) }?;
        let key = "\"text\":\"";
        let start = json.find(key)? + key.len();
        let end = json[start..].find('"')? + start;
        Some(json[start..end].to_string())
    }

    unsafe fn feed_str(session: *mut LianaSession, text: &str) {
        for ch in text.chars() {
            let c = CString::new(ch.to_string()).unwrap();
            assert_eq!(unsafe { liana_feed(session, c.as_ptr()) }, 1, "{ch}");
        }
    }

    /// E1 接线：选词奖励跨会话共享（进程单例账本）、删除负奖励、开关、TSV 回环。
    #[test]
    fn evolution_session_wiring_via_c_abi() {
        unsafe {
            let s1 = liana_new(b"pinyin\0".as_ptr().cast());
            let s2 = liana_new(b"pinyin\0".as_ptr().cast());
            assert!(!s1.is_null() && !s2.is_null());
            let app = CString::new("evo.session.test").unwrap();

            // 会话 B 也能看到会话 A 学到的东西：账本是进程单例
            assert_eq!(liana_set_evolution_context(s1, app.as_ptr(), 10, 1, 1_000), 1);
            feed_str(s1, "nihao");
            let top = first_candidate_text(s1).expect("应有候选");

            for t in [1_005u64, 1_010] {
                assert!(!liana_select(s1, 0).is_null());
                assert_eq!(liana_evolution_note_selection(s1, 0, t), 1);
                // E3：每次确认都产出评估，取走即清
                let eval = call_str(|| unsafe { liana_evolution_eval_json(s1) });
                assert!(eval.is_some(), "note_selection 后应有评估");
                assert!(eval.unwrap().contains("\"actualTop1\""));
                feed_str(s1, "nihao");
            }
            assert!(unsafe { liana_evolution_eval_json(s1) }.is_null(), "取走即清");
            let shared = call_str(|| liana_evolution_session_export(s2)).unwrap();
            assert!(
                shared.lines().any(|l| l.starts_with(&format!("{top}\t"))),
                "会话 B 应读到会话 A 的学习: {shared}"
            );

            // 选了又删：负亲和度落账
            assert!(!liana_select(s1, 0).is_null());
            assert_eq!(liana_evolution_note_selection(s1, 0, 1_015), 1);
            assert_eq!(liana_evolution_note_delete(s1, 1_018), 1);
            let tsv = call_str(|| liana_evolution_session_export(s1)).unwrap();
            assert!(
                tsv.lines().any(|l| {
                    l.starts_with(&format!("{top}\t"))
                        && l.split('\t').nth(2).unwrap().parse::<f32>().unwrap() < 0.0
                }),
                "删除应留负亲和度: {tsv}"
            );

            // 关闭学习：选择与删除都不再记账
            let frozen = call_str(|| liana_evolution_session_export(s1)).unwrap();
            assert_eq!(liana_set_evolution_context(s1, app.as_ptr(), 10, 0, 2_000), 1);
            feed_str(s1, "nihao");
            assert!(!liana_select(s1, 0).is_null());
            assert_eq!(liana_evolution_note_selection(s1, 0, 2_005), 1);
            assert_eq!(liana_evolution_note_delete(s1, 2_008), 1);
            assert_eq!(
                call_str(|| liana_evolution_session_export(s1)).unwrap(),
                frozen,
                "关闭后不得新增账目"
            );
            assert_eq!(liana_set_evolution_context(s1, app.as_ptr(), 10, 1, 2_100), 1);

            // 清空 + TSV 导入回环
            let saved = frozen.clone();
            liana_evolution_session_forget(s2);
            assert!(call_str(|| liana_evolution_session_export(s1)).unwrap().is_empty());
            let c_tsv = CString::new(saved).unwrap();
            assert!(liana_evolution_session_import(s1, c_tsv.as_ptr()) >= 1);

            // 空会话指针安全
            assert_eq!(liana_set_evolution_context(std::ptr::null_mut(), app.as_ptr(), 0, 1, 0), 0);
            assert_eq!(liana_evolution_note_selection(std::ptr::null_mut(), 0, 0), 0);
            assert_eq!(liana_evolution_note_delete(std::ptr::null_mut(), 0), 0);
            assert!(liana_evolution_session_export(std::ptr::null_mut()).is_null());
            assert_eq!(liana_evolution_session_import(std::ptr::null_mut(), c_tsv.as_ptr()), -1);
            liana_evolution_session_forget(std::ptr::null_mut());
            assert!(liana_evolution_eval_json(std::ptr::null_mut()).is_null());

            liana_free(s1);
            liana_free(s2);
        }
    }

    /// E2 喂食层：术语提炼 JSON → 喂入营养词 → 按键召回 → 列举/忘记/回环。
    #[test]
    fn nutrition_feed_via_c_abi() {
        unsafe {
            let session = liana_new(b"pinyin\0".as_ptr().cast());
            assert!(!session.is_null());

            // 纯函数提炼：反复出现的词浮出，只出现一次的不给
            let text = CString::new("县政府发布通知，县政府要求落实。").unwrap();
            let json = call_str(|| liana_feed_extract_json(text.as_ptr())).unwrap();
            assert!(json.contains("\"term\":\"县政府\""), "{json}");
            assert!(!json.contains("通知"), "只出现一次不成词: {json}");

            // 喂入营养词（词典单字读音派生按键串）
            let term = CString::new("北京高").unwrap();
            let source = CString::new("会议纪要.txt").unwrap();
            assert_eq!(liana_nutrition_add(session, term.as_ptr(), source.as_ptr(), 2, 1_000), 1);

            // 列举
            let list = call_str(|| liana_nutrition_list_json(session)).unwrap();
            assert!(list.contains("\"term\":\"北京高\""), "{list}");
            assert!(list.contains("\"keys\":\"beijinggao\""), "{list}");
            assert!(list.contains("\"source\":\"会议纪要.txt\""), "{list}");

            // 按键召回：打 beijinggao 应出现北京高
            feed_str(session, "beijinggao");
            let comp = call_str(|| liana_composition_json(session)).unwrap();
            assert!(comp.contains("北京高"), "{comp}");
            liana_clear(session);

            // TSV 回环
            let tsv = call_str(|| liana_nutrition_export(session)).unwrap();
            assert!(tsv.contains("北京高\tbeijinggao"), "{tsv}");
            let c_tsv = CString::new(tsv).unwrap();
            let fresh = liana_new(b"pinyin\0".as_ptr().cast());
            assert_eq!(liana_nutrition_import(fresh, c_tsv.as_ptr()), 1);
            let list2 = call_str(|| liana_nutrition_list_json(fresh)).unwrap();
            assert!(list2.contains("\"term\":\"北京高\""), "{list2}");

            // 忘记
            assert_eq!(liana_nutrition_forget(fresh, term.as_ptr()), 1);
            assert_eq!(liana_nutrition_forget(fresh, term.as_ptr()), 0);
            liana_nutrition_forget_all(fresh);
            assert!(call_str(|| liana_nutrition_list_json(fresh)).unwrap() == "[]");

            // 空指针安全
            let bad = CString::new("x").unwrap();
            assert!(liana_feed_extract_json(std::ptr::null()).is_null());
            assert_eq!(liana_nutrition_add(std::ptr::null_mut(), bad.as_ptr(), bad.as_ptr(), 1, 0), 0);
            assert!(liana_nutrition_list_json(std::ptr::null_mut()).is_null());
            assert_eq!(liana_nutrition_forget(std::ptr::null_mut(), bad.as_ptr()), 0);
            liana_nutrition_forget_all(std::ptr::null_mut());
            assert!(liana_nutrition_export(std::ptr::null_mut()).is_null());
            assert_eq!(liana_nutrition_import(std::ptr::null_mut(), bad.as_ptr()), -1);

            liana_free(session);
            liana_free(fresh);
        }
    }

    #[test]
    fn plugin_scan_via_c_abi() {
        let root = std::env::temp_dir().join(format!("iffi-plugin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let pack = root.join("skin-x");
        std::fs::create_dir_all(&pack).unwrap();
        std::fs::write(
            pack.join("plugin.json"),
            r#"{"id":"skin-x","name":"X","version":"1.0.0","kind":"skin","permissions":[]}"#,
        )
        .unwrap();
        std::fs::write(pack.join("theme.json"), "{}").unwrap();

        let c_dir = CString::new(root.to_str().unwrap()).unwrap();
        let json = unsafe { call_str(|| liana_plugin_scan_json(c_dir.as_ptr())) }.unwrap();
        assert!(json.contains("\"id\":\"skin-x\""), "{json}");
        assert!(json.contains("\"errors\":[]"), "{json}");

        let c_missing = CString::new("/nonexistent-liana-plugins").unwrap();
        let empty = unsafe { call_str(|| liana_plugin_scan_json(c_missing.as_ptr())) }.unwrap();
        assert!(empty.contains("\"packs\":[]"), "{empty}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn layered_dict_adds_words_and_is_shared() {
        let dir = std::env::temp_dir().join(format!("liana-layers-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("apps.tsv"), "钉钉\tding ding\t3000\n你好世界\n").unwrap();
        let d = dir.to_str().unwrap();
        let a = load_layered(None, Some(d));
        assert!(a.lookup("ding'ding").iter().any(|e| e.word == "钉钉" && e.freq == 3000));
        assert!(a.lookup("ni'hao'shi'jie").iter().any(|e| e.word == "你好世界"));
        // 文件没变：同一份词库
        let b = load_layered(None, Some(d));
        assert!(Arc::ptr_eq(&a, &b));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
