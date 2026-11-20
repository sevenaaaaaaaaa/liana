# liana-peer

Linux / Windows 上接入松萝局域网通道的命令行工具。和 macOS / iOS 的桌宠（PetLink）说同一套协议：

- **发现**：Bonjour `_liana-pet._tcp`
- **加密**：TLS 1.2 + 预共享密钥（PSK-AES128-GCM-SHA256，identity `liana-pet-v1`）
- **帧**：`4 字节大端长度（含 kind）+ 1 字节 kind + 载荷`，kind 1 = JSON，kind 2 = 文件分片
- **握手**：`{"kind":"hello","version":1,"device":"<uuid>","name":"<设备名>"}` → `{"kind":"ready","clipboard":1}`

## 构建

```bash
cd tools/liana-peer
cargo build --release
# 产物：target/release/liana-peer（约 1.3MB，无运行时依赖）
```

Linux 需要 `libssl-dev`（Debian/Ubuntu）或 `openssl-devel`（Fedora）；Windows 建议用 `vcpkg` 或 `OPENSSL_DIR` 指向预编译 OpenSSL。

## 用法

```bash
# 1. 配对：把 Mac 桌宠「收件箱 → 配对」里复制的码贴进来
liana-peer pair "liana-pet://pair/eyJ2ZXJzaW9uIjoxLCJ..."

# 2. 发文字到 Mac 剪贴板
liana-peer text "会议改到三点"

# 3. 取 Mac 剪贴板
liana-peer pull

# 4. 发文件（每片 60KB，逐片等 Mac 确认，最后校验 SHA-256）
liana-peer file ./report.pdf

# 5. 持续接 Mac 发来的文字（Ctrl+C 退出）
liana-peer watch

# 网络里有多台 Mac 时，直接给地址跳过 mDNS
liana-peer --addr 192.168.1.20:49152 text "hello"
```

配对信息存在 `~/.liana-peer/profile.json`（Windows 为 `%USERPROFILE%\.liana-peer\profile.json`）。

## 已验证 / 未验证

- ✅ TLS-PSK 握手、hello/ready、clipboardPush/Pull 往返（用 `examples/echo_server.rs` 端到端跑通）
- ✅ 文件传输：300KB / 5 片，服务端收满 300000 字节且 SHA-256 一致（`sha match`）
- ⚠️ mDNS 自动发现：macOS 上编译通过；Windows 依赖系统 mDNS（Win10 1803+ 自带），Linux 需要 avahi 或纯 Rust 多播（mdns-sd 自带）
- ⚠️ 文件发送尚未与真实 Mac 桌宠对测（只在 echo 服务端验证了 offer → accept → chunk → saved 全流程）

## 为什么单独一个 crate

内核（`crates/*`）保持零第三方依赖，而 TCP + TLS-PSK + mDNS 必须有库。这个工具在自己的 workspace 里，不参与 `cargo test --workspace`。
