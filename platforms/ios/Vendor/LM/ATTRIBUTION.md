# base.lm（移动端整句搭配模型）

- 上游数据：[万象 RIME-LMDG](https://github.com/amzxyz/RIME-LMDG) 的语法模型 `wanxiang-lts-zh-hans.gram`
  （LTS，librime-octagram 格式，CC BY 4.0，48GB 多领域语料训练）。
- 本文件由桌面构建产物 `platforms/macos/build/base.lm`（42.4 MB，11,018,092 条 2～4 字搭配）剪枝而来：
  保留全部 2 字搭配 + 按分数截取 80 万条 3 字搭配和 20 万条 4 字搭配，共 1,072,121 条 / 5.3 MB。
- 文件名以 `.bin` 结尾，避免 Xcode 把 `.lm` 当成 Lex 源文件编译；`build.sh` 会复制为 `Resources/base.lm` 打进键盘 bundle。
- 生成命令（仓库根目录）：

```bash
cargo build -p xtask
./target/debug/xtask lm prune platforms/macos/build/base.lm \
    -o platforms/ios/Vendor/LM/base.lm \
    --len2 all --len3 800000 --len4 200000
```

- 147 句整句评测（mobile-core 词库）：无模型首选 62%，桌面全量模型 79%，本剪枝模型 72%。
- sha256：`9800c19c299632a097da02cfdf1ea40af586e2679193b680b7678aebf6316fcc`
- 许可：CC BY 4.0（数据来源标注见上）。本项目代码 AGPL-3.0-only；本数据文件按上游 CC BY 4.0 分发。
