//! 最小回环服务端：只用来验证 liana-peer 的 TLS-PSK 与帧协议。
//! 跑：cargo run --release --example echo_server
//! 然后：liana-peer --addr 127.0.0.1:47811 text "hi"

use std::io::{Read, Write};
use std::net::TcpListener;

use openssl::ssl::{SslContextBuilder, SslMethod, SslVersion};
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
        let ssl = openssl::ssl::Ssl::new(&context).expect("ssl");
        let Ok(mut tls) = openssl::ssl::SslStream::new(ssl, stream) else { continue };
        if tls.accept().is_err() {
            println!("tls accept failed");
            continue;
        }
        println!("client connected");
        loop {
            match read_frame(&mut tls) {
                Ok((kind, data)) => {
                    if kind != 1 {
                        continue;
                    }
                    let value: Value = match serde_json::from_slice(&data) {
                        Ok(v) => v,
                        Err(_) => break,
                    };
                    let reply = match value.get("kind").and_then(|v| v.as_str()) {
                        Some("hello") => serde_json::json!({"kind": "ready", "clipboard": 1}),
                        Some("clipboardPush") => serde_json::json!({"kind": "clipboardSaved", "id": value.get("id").cloned().unwrap_or(Value::Null)}),
                        Some("clipboardPull") => serde_json::json!({"kind": "clipboardValue", "id": value.get("id").cloned().unwrap_or(Value::Null), "text": "from-echo"}),
                        _ => serde_json::json!({"kind": "error", "message": "unsupported"}),
                    };
                    let bytes = serde_json::to_vec(&reply).unwrap();
                    let _ = write_frame(&mut tls, 1, &bytes);
                    println!("handled {}", value.get("kind").and_then(|v| v.as_str()).unwrap_or("?"));
                }
                Err(_) => break,
            }
        }
    }
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
