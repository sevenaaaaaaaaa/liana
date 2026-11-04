#!/usr/bin/env bash
# Linux 发布打包：构建（build.sh --local）→ 组装可安装目录树 → tarball + 校验和
#
# 产物（$ROOT/dist/）：
#   liana-<版本>-linux-<架构>.tar.gz       解包后 sudo ./install.sh 一键安装
#   liana-<版本>-linux-<架构>.tar.gz.sha256
#
# 用法：
#   LIANA_VERSION=v0.4.0 ./dist.sh     # CI 口径，版本号进目录名
#   ./dist.sh                          # 本地试打，版本号记 dev
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERSION="${LIANA_VERSION:-dev}"
ARCH="$(uname -m)"
NAME="liana-${VERSION}-linux-${ARCH}"
OUT="$ROOT/dist"

echo "==> 1/2 构建内核 + 词典（不安装）"
"$HERE/build.sh" --local
SO="$ROOT/target/release/libliana_ffi.so"

echo "==> 2/2 组装 $NAME.tar.gz"
STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE"
cp "$SO" "$STAGE/libliana_ffi.so"
cp "$HERE/ibus-liana" "$HERE/libliana.py" "$HERE/liana.xml" "$STAGE/"
cp "$HERE/build/base.ifd" "$STAGE/base.ifd"
chmod +x "$STAGE/ibus-liana"

# install.sh：直接复用 platforms/linux/install.sh（单一来源，装完自带自检与启用指引）
cp "$HERE/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"

mkdir -p "$OUT"
tar -czf "$OUT/$NAME.tar.gz" -C "$(dirname "$STAGE")" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo
echo "产物就绪："
ls -lh "$OUT" | tail -n +2
