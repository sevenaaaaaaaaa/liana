//! Liana 局域网对端 CLI。
//!
//! 与 macOS / iOS 的桌宠通道说同一套协议：
//!   Bonjour 服务 _liana-pet._tcp，TLS 1.2 + 预共享密钥（配对码里带 32 字节 key），
//!   帧 = 4 字节大端长度（含 kind）+ 1 字节 kind + 载荷；
//!   kind 1 = JSON 控制消息，kind 2 = 文件分片。
//!
//! 为什么单独一个 crate：内核保持零第三方依赖，而 TCP + TLS-PSK + mDNS 必须有库。

use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use openssl::ssl::{SslConnector, SslMethod, SslVerifyMode, SslVersion};
use serde::{Deserialize, Serialize};

const SERVICE_TYPE: &str = "_liana-pet._tcp";
const TLS_IDENTITY: &[u8] = b"liana-pet-v1";
const MAX_FRAME: usize = 70 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Profile {
    version: u8,
    id: String,
    name: String,
    /// 32 字节 PSK。Swift 的 Data 在 JSON 里是 base64 字符串，这里保持一致。
    key: String,
}

impl Profile {
    /// 解出 32 字节密钥。
    fn key_bytes(&self) -> Result<Vec<u8>, String> {
        let bytes = base64_decode(&self.key)?;
        if bytes.len() != 32 {
            return Err(format!("密钥长度不对：{} 字节（应为 32）", bytes.len()));
        }
        Ok(bytes)
    }
}

fn profile_path() -> PathBuf {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".liana-peer").join("profile.json")
}

fn load_profile() -> Result<Profile, String> {
    let path = profile_path();
    let text = std::fs::read_to_string(&path)
        .map_err(|_| format!("还没有配对。先跑 liana-peer pair <配对码>（{}）", path.display()))?;
    let profile: Profile =
        serde_json::from_str(&text).map_err(|e| format!("配对文件损坏：{e}"))?;
    profile.key_bytes()?;
    Ok(profile)
}

fn save_profile(profile: &Profile) -> Result<(), String> {
    let path = profile_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("建目录失败：{e}"))?;
    }
    let text = serde_json::to_string_pretty(profile).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("写配对文件失败：{e}"))?;
    Ok(())
}

/// 配对码形如 liana-pet://pair/<base64 JSON>。
fn parse_pairing(code: &str) -> Result<Profile, String> {
    let prefix = "liana-pet://pair/";
    let body = code.strip_prefix(prefix).ok_or("配对码应以 liana-pet://pair/ 开头")?;
    let bytes = base64_decode(body.trim())?;
    let profile: Profile =
        serde_json::from_slice(&bytes).map_err(|e| format!("配对码内容无效：{e}"))?;
    if profile.version != 1 || profile.name.is_empty() {
        return Err("配对码版本或内容不对".into());
    }
    profile.key_bytes()?;
    Ok(profile)
}

fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(input.len() * 3 / 4 + 3);
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for byte in input.bytes() {
        if byte == b'=' || byte.is_ascii_whitespace() {
            continue;
        }
        let value = TABLE
            .iter()
            .position(|&c| c == byte)
            .ok_or("配对码里有非法 base64 字符")?;
        buffer = (buffer << 6) | value as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    Ok(out)
}

fn connect(profile: &Profile, addr: &str) -> Result<openssl::ssl::SslStream<std::net::TcpStream>, String> {
    let psk = profile.key_bytes()?;
    let mut builder = SslConnector::builder(SslMethod::tls()).map_err(|e| e.to_string())?;
    builder.set_min_proto_version(Some(SslVersion::TLS1_2)).map_err(|e| e.to_string())?;
    builder.set_max_proto_version(Some(SslVersion::TLS1_2)).map_err(|e| e.to_string())?;
    builder.set_verify(SslVerifyMode::NONE);
    builder.set_cipher_list("PSK-AES128-GCM-SHA256").map_err(|e| e.to_string())?;
    // openssl crate 的 PSK 回调：(ssl, hint, identity_out, psk_out) -> psk 长度。
    // 身份必须与 Mac 端一致（liana-pet-v1），密钥用配对码里的 32 字节。
    builder.set_psk_client_callback(move |_ssl, _hint, identity_out, psk_out| {
        if identity_out.len() < TLS_IDENTITY.len() || psk_out.len() < psk.len() {
            return Ok(0);
        }
        identity_out[..TLS_IDENTITY.len()].copy_from_slice(TLS_IDENTITY);
        psk_out[..psk.len()].copy_from_slice(&psk);
        Ok(psk.len())
    });
    let connector = builder.build();
    let stream = std::net::TcpStream::connect(addr).map_err(|e| format!("连不上 {addr}：{e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(20))).ok();
    connector
        .connect("liana-peer", stream)
        .map_err(|e| format!("TLS 握手失败（配对码里的密钥与 Mac 不一致？）：{e}"))
}

fn write_frame(stream: &mut impl Write, kind: u8, payload: &[u8]) -> Result<(), String> {
    let len = payload.len() + 1;
    if len > MAX_FRAME {
        return Err("单帧超过 70KB".into());
    }
    stream.write_all(&(len as u32).to_be_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(&[kind]).map_err(|e| e.to_string())?;
    stream.write_all(payload).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())
}

fn read_frame(stream: &mut impl Read) -> Result<(u8, Vec<u8>), String> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).map_err(|e| format!("读帧头失败：{e}"))?;
    let len = u32::from_be_bytes(header) as usize;
    if len < 2 || len > MAX_FRAME {
        return Err(format!("帧长度异常：{len}"));
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).map_err(|e| format!("读帧失败：{e}"))?;
    Ok((body[0], body[1..].to_vec()))
}

fn send_json(stream: &mut impl Write, value: &serde_json::Value) -> Result<(), String> {
    let data = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    write_frame(stream, 1, &data)
}

fn read_json(stream: &mut impl Read) -> Result<serde_json::Value, String> {
    let (kind, data) = read_frame(stream)?;
    if kind != 1 {
        return Err("服务端发来了非 JSON 帧".into());
    }
    serde_json::from_slice(&data).map_err(|e| format!("解析 JSON 失败：{e}"))
}

fn handshake(stream: &mut openssl::ssl::SslStream<std::net::TcpStream>, profile: &Profile) -> Result<serde_json::Value, String> {
    send_json(
        stream,
        &serde_json::json!({
            "kind": "hello",
            "version": 1,
            "device": profile.id,
            "name": profile.name,
        }),
    )?;
    let reply = read_json(stream)?;
    match reply.get("kind").and_then(|v| v.as_str()) {
        Some("ready") => Ok(reply),
        Some("error") => Err(reply
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("Mac 拒绝了连接")
            .to_string()),
        _ => Err("Mac 返回了无法识别的握手回复".into()),
    }
}

fn resolve_via_mdns(timeout: Duration) -> Result<String, String> {
    let service = mdns_sd::ServiceDaemon::new().map_err(|e| format!("启动 mDNS 失败：{e}"))?;
    let receiver = service
        .browse(SERVICE_TYPE)
        .map_err(|e| format!("浏览服务失败：{e}"))?;
    let deadline = std::time::Instant::now() + timeout;
    let mut found: Option<String> = None;
    while std::time::Instant::now() < deadline {
        match receiver.recv_timeout(Duration::from_millis(500)) {
            Ok(mdns_sd::ServiceEvent::ServiceResolved(info)) => {
                if let Some(addr) = info.get_addresses().iter().next() {
                    found = Some(format!("{addr}:{}", info.get_port()));
                    break;
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = service.shutdown();
    found.ok_or_else(|| "没有在局域网里发现松萝桌宠（确认 Mac 端已打开收件箱）".to_string())
}

fn usage() {
    eprintln!("liana-peer —— 松萝局域网对端（Linux / Windows）");
    eprintln!();
    eprintln!("用法：");
    eprintln!("  liana-peer pair \"<配对码>\"      从 Mac 桌宠复制的配对码，存到 ~/.liana-peer/profile.json");
    eprintln!("  liana-peer info                 查看当前配对");
    eprintln!("  liana-peer text \"<文字>\"       把文字送到 Mac 剪贴板");
    eprintln!("  liana-peer pull                 取 Mac 剪贴板文字");
    eprintln!("  liana-peer file <路径>          发送文件");
    eprintln!("  liana-peer watch                持续监听 Mac 发来的文字");
    eprintln!();
    eprintln!("可选：--addr host:port 跳过 mDNS 直接连（默认自动发现 _liana-pet._tcp）");
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        return;
    }
    let mut addr: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();
    let mut index = 0;
    while index < args.len() {
        if args[index] == "--addr" {
            addr = args.get(index + 1).cloned();
            index += 2;
            continue;
        }
        if args[index] == "-h" || args[index] == "--help" {
            usage();
            return;
        }
        positional.push(args[index].clone());
        index += 1;
    }
    let command = positional.first().map(String::as_str).unwrap_or("");
    if let Err(message) = run(command, &positional[1..], addr.as_deref()) {
        eprintln!("✗ {message}");
        std::process::exit(1);
    }
}

fn run(command: &str, rest: &[String], addr: Option<&str>) -> Result<(), String> {
    match command {
        "pair" => {
            let code = rest.first().ok_or("缺少配对码")?;
            let profile = parse_pairing(code)?;
            save_profile(&profile)?;
            println!("✓ 已配对：{}（{}）", profile.name, profile.id);
            println!("  存到 {}", profile_path().display());
            Ok(())
        }
        "info" => {
            let profile = load_profile()?;
            println!("设备：{}", profile.name);
            println!("id：{}", profile.id);
            println!("配对文件：{}", profile_path().display());
            Ok(())
        }
        "text" => {
            let text = rest.join(" ");
            if text.trim().is_empty() {
                return Err("缺少要发送的文字".into());
            }
            let profile = load_profile()?;
            let target = match addr {
                Some(value) => value.to_string(),
                None => resolve_via_mdns(Duration::from_secs(8))?,
            };
            let mut stream = connect(&profile, &target)?;
            handshake(&mut stream, &profile)?;
            let id = uuid_like();
            send_json(&mut stream, &serde_json::json!({"kind": "clipboardPush", "id": id, "text": text}))?;
            let reply = read_json(&mut stream)?;
            match reply.get("kind").and_then(|v| v.as_str()) {
                Some("clipboardSaved") => {
                    println!("✓ 已送到 Mac 剪贴板（{target}）");
                    Ok(())
                }
                Some("clipboardError") => Err(reply
                    .get("message")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Mac 未允许剪贴板同步")
                    .to_string()),
                _ => Err("Mac 返回了无法识别的回复".into()),
            }
        }
        "pull" => {
            let profile = load_profile()?;
            let target = match addr {
                Some(value) => value.to_string(),
                None => resolve_via_mdns(Duration::from_secs(8))?,
            };
            let mut stream = connect(&profile, &target)?;
            handshake(&mut stream, &profile)?;
            let id = uuid_like();
            send_json(&mut stream, &serde_json::json!({"kind": "clipboardPull", "id": id}))?;
            let reply = read_json(&mut stream)?;
            match reply.get("kind").and_then(|v| v.as_str()) {
                Some("clipboardValue") => {
                    println!("{}", reply.get("text").and_then(|v| v.as_str()).unwrap_or(""));
                    Ok(())
                }
                _ => Err("Mac 没有返回剪贴板内容".into()),
            }
        }
        "file" => {
            let path = rest.first().ok_or("缺少文件路径")?;
            let data = std::fs::read(path).map_err(|e| format!("读文件失败：{e}"))?;
            if data.len() > 200 * 1024 * 1024 {
                return Err("只支持不超过 200MB 的文件".into());
            }
            let name = std::path::Path::new(path)
                .file_name()
                .and_then(|v| v.to_str())
                .unwrap_or("file.bin")
                .to_string();
            let profile = load_profile()?;
            let target = match addr {
                Some(value) => value.to_string(),
                None => resolve_via_mdns(Duration::from_secs(8))?,
            };
            let mut stream = connect(&profile, &target)?;
            handshake(&mut stream, &profile)?;
            let id = uuid_like();
            let digest = sha256_hex(&data);
            send_json(
                &mut stream,
                &serde_json::json!({
                    "kind": "offer",
                    "id": id,
                    "name": name,
                    "size": data.len(),
                    "sha256": digest,
                }),
            )?;
            let reply = read_json(&mut stream)?;
            if reply.get("kind").and_then(|v| v.as_str()) != Some("accept") {
                return Err(reply
                    .get("message")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Mac 没有接受这个文件")
                    .to_string());
            }
            // 每片 60KB，发完等一条 ack；最后一片的 ack 是 saved。
            let mut chunks = 0usize;
            for chunk in data.chunks(60 * 1024) {
                write_frame(&mut stream, 2, chunk)?;
                chunks += 1;
                let ack = read_json(&mut stream)?;
                match ack.get("kind").and_then(|v| v.as_str()) {
                    Some("accept") => {}
                    Some("saved") => {
                        println!("✓ 已送达：{}（{} 字节 / {} 片）", name, data.len(), chunks);
                        return Ok(());
                    }
                    _ => return Err("Mac 在传输中途报错".into()),
                }
            }
            println!("✓ 已发送完毕：{}（{} 片），等待 Mac 校验", name, chunks);
            Ok(())
        }
        "watch" => {
            let profile = load_profile()?;
            let target = match addr {
                Some(value) => value.to_string(),
                None => resolve_via_mdns(Duration::from_secs(8))?,
            };
            let mut stream = connect(&profile, &target)?;
            handshake(&mut stream, &profile)?;
            println!("… 已连上 {target}，等待 Mac 发来的文字（Ctrl+C 退出）");
            loop {
                match read_json(&mut stream) {
                    Ok(value) => {
                        if value.get("kind").and_then(|v| v.as_str()) == Some("clipboardValue") {
                            println!("{}", value.get("text").and_then(|v| v.as_str()).unwrap_or(""));
                        }
                    }
                    Err(message) => return Err(message),
                }
            }
        }
        other => {
            usage();
            Err(format!("未知命令：{other}"))
        }
    }
}

fn sha256_hex(data: &[u8]) -> String {
    use openssl::hash::{hash, MessageDigest};
    match hash(MessageDigest::sha256(), data) {
        Ok(digest) => digest.iter().map(|b| format!("{b:02x}")).collect(),
        Err(_) => String::new(),
    }
}

fn uuid_like() -> String {
    let mut bytes = [0u8; 16];
    let _ = openssl::rand::rand_bytes(&mut bytes);
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}
