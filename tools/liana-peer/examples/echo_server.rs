//! 最小回环服务端：验证 liana-peer 的 TLS-PSK、帧协议与文件分片。
//! 跑：cargo run --release --example echo_server
//! 然后：liana-peer --addr 127.0.0.1:47811 file /tmp/sample.bin

use std::io::{Read, Write};
use std::net::TcpListener;

use openssl::ssl::{Ssl, SslContextBuilder, SslMethod, SslStream, SslVersion};
use serde_json::Value;

const PSK: [u8; 32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                       16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31];
const TLS_IDENTITY: &[u8] = b"liana-pet-v1";

fn main() {
    let mut builder = SslContextBuilder::new(SslMethod::tls()).expect("tls");
    builder.set_min_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    builder.set_max_proto_version(Some(SslVersion::TLS1_2)).unwrap();
    builder.set_cipher_list("PSK-AES128-GCM-SHA256").unwrap();
    builder.set_psk_server_callback(move |_ssl, identity, psk_out| {
        if identity != Some(TLS_IDENTITY) || psk_out.len() < PSK.len() {
            return Ok(0);
        }
        psk_out[..PSK.len()].copy_from_slice(&PSK);
        Ok(PSK.len())
    });
    let context = builder.build();

    let listener = TcpListener::bind("127.0.0.1:47811").expect("bind");
    println!("echo server on 127.0.0.1:47811");
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let Ok(ssl) = Ssl::new(&context) else { continue };
        let Ok(mut tls) = SslStream::new(ssl, stream) else { continue };
        if tls.accept().is_err() {
            println!("tls accept failed");
            continue;
        }
        println!("client connected");
        serve(&mut tls);
    }
}

fn serve(tls: &mut SslStream<std::net::TcpStream>) {
    let mut incoming: Option<(String, u64, String, Vec<u8>)> = None;
    loop {
        let Ok((kind, data)) = read_frame(tls) else { return };
        if kind == 2 {
            let Some((name, size, digest, mut buffer)) = incoming.take() else { continue };
            buffer.extend_from_slice(&data);
            let done = buffer.len() as u64 >= size;
            if done {
                let actual = sha256_hex(&buffer);
                let ok = actual == digest;
                println!("file {} received {} bytes, sha {}", name, buffer.len(), if ok { "match" } else { "MISMATCH" });
                let reply = if ok {
                    serde_json::json!({"kind": "saved", "name": name})
                } else {
                    serde_json::json!({"kind": "error", "message": "hash mismatch"})
                };
                let _ = reply_json(tls, &reply);
                return;
            }
            incoming = Some((name, size, digest, buffer));
            let _ = reply_json(tls, &serde_json::json!({"kind": "accept"}));
            continue;
        }
        let Ok(value) = serde_json::from_slice::<Value>(&data) else { return };
        match value.get("kind").and_then(|v| v.as_str()) {
            Some("hello") => {
                let _ = reply_json(tls, &serde_json::json!({"kind": "ready", "clipboard": 1}));
            }
            Some("clipboardPush") => {
                let _ = reply_json(tls, &serde_json::json!({"kind": "clipboardSaved", "id": value.get("id").cloned().unwrap_or(Value::Null)}));
            }
            Some("clipboardPull") => {
                let _ = reply_json(tls, &serde_json::json!({"kind": "clipboardValue", "id": value.get("id").cloned().unwrap_or(Value::Null), "text": "from-echo"}));
            }
            Some("offer") => {
                let name = value.get("name").and_then(|v| v.as_str()).unwrap_or("file").to_string();
                let size = value.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
                let digest = value.get("sha256").and_then(|v| v.as_str()).unwrap_or("").to_string();
                println!("offer {} ({} bytes)", name, size);
                incoming = Some((name, size, digest, Vec::new()));
                let _ = reply_json(tls, &serde_json::json!({"kind": "accept"}));
            }
            _ => {
                let _ = reply_json(tls, &serde_json::json!({"kind": "error", "message": "unsupported"}));
            }
        }
    }
}

fn reply_json(tls: &mut SslStream<std::net::TcpStream>, value: &Value) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(value).unwrap();
    write_frame(tls, 1, &bytes)
}

fn write_frame(stream: &mut impl Write, kind: u8, payload: &[u8]) -> std::io::Result<()> {
    let len = payload.len() + 1;
    stream.write_all(&(len as u32).to_be_bytes())?;
    stream.write_all(&[kind])?;
    stream.write_all(payload)?;
    stream.flush()
}

fn read_frame(stream: &mut impl Read) -> std::io::Result<(u8, Vec<u8>)> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header) as usize;
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body)?;
    Ok((body[0], body[1..].to_vec()))
}

fn sha256_hex(data: &[u8]) -> String {
    use openssl::hash::{hash, MessageDigest};
    match hash(MessageDigest::sha256(), data) {
        Ok(digest) => digest.iter().map(|b| format!("{b:02x}")).collect(),
        Err(_) => String::new(),
    }
}
