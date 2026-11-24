#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""libliana.py 无 GUI 冒烟（不依赖 ibus，可在 macOS/Linux 任何机器跑）。

用法：python3 platforms/linux/smoke.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import libliana

failures = 0


def check(cond, msg):
    global failures
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond:
        failures += 1


print(f"== libliana 冒烟（内核 {libliana.version()}）==")
s = libliana.Session("pinyin")

for ch in "nihao":
    s.feed(ch)
comp = s.composition()
check(comp.get("raw") == "nihao", "raw 回显")
check(len(comp.get("candidates", [])) > 0, "产生候选")
top = s.select(0)
check(top == "你好", f"select(0) == 你好（实际 {top}）")

s.clear()
check(not s.composition().get("candidates"), "clear 后无候选")
langs = libliana.languages()
check(len(langs) == 9, f"语言清单 9 项（实际 {len(langs)}）")
check(any(x.get("id") == "ja" and x.get("label") == "日本語" for x in langs), "清单含日本語")
check(any(x.get("id") == "ko" and x.get("label") == "한국어" for x in langs), "清单含한국어")
check(any(x.get("id") == "es" and x.get("label") == "Español" for x in langs), "清单含Español")
check(all(x.get("policy") in ("ascii", "unicode") for x in langs), "清单每项都有闸门策略")
check(s.set_mode("ja") and s.mode == "ja", "按语言 id 切到 ja")
check(not s.set_mode("nope") and s.mode == "ja", "未注册 id 不改现状")
s.set_mode("pinyin")
check(s.set_mode("en") and s.mode == "en", "切 en 模式")
s.feed("h")
check(len(s.composition().get("candidates", [])) > 0, "en 补全出候选")
s.set_mode("ko")
check(s.mode == "ko", "切 ko 模式")
for ch in "dkssud":
    s.feed(ch)
check(s.composition().get("candidates", [{}])[0].get("text") == "안녕", "韩语 2-beolsik 组合出 안녕")
s.set_mode("es")
check(s.mode == "es", "切 es 模式")
for ch in "nin'o":
    s.feed(ch)
check(s.composition().get("preedit") == "niño", "西语重音符 nin'o → niño")
s.set_mode("pinyin")
check(not s.traditional, "默认简体")
s.set_traditional(True)
check(s.traditional, "繁体开关回读")
check(s.record_commit("冒烟测试") , "record_commit")
check(s.user_export() and "你好" in s.user_export(), "user_export 含学习词")
bak = s.backup_export()
check(bak and s.backup_import(bak), "备份导出/导入闭环")

print(f"== 结果：{'全部通过' if failures == 0 else f'{failures} 项失败'} ==")
sys.exit(1 if failures else 0)