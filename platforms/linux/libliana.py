#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Liana FFI 的 ctypes 绑定（Linux IBus 引擎与无 GUI 冒烟共用）。

加载顺序：
  1. 环境变量 LIANA_FFI_PATH 指定的绝对路径；
  2. 仓库 target/release 下的 libliana_ffi.so / .dylib（开发态）；
  3. 系统安装路径 /usr/local/lib/liana/（build.sh 安装后）。

与 macOS/Android/iOS 端共用同一份 C ABI（crates/ffi/include/liana.h）。
"""
import ctypes
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))

_CANDIDATE_PATHS = []
if os.environ.get("LIANA_FFI_PATH"):
    _CANDIDATE_PATHS.append(os.environ["LIANA_FFI_PATH"])
_SO = os.path.join(_ROOT, "target", "release", "libliana_ffi.so")
_DYLIB = os.path.join(_ROOT, "target", "release", "libliana_ffi.dylib")
_INSTALLED = "/usr/local/lib/liana/libliana_ffi.so"
_CANDIDATE_PATHS += [_SO, _DYLIB, _INSTALLED,
                     os.path.join(os.path.dirname(_SO), "libliana_ffi.so")]

_lib = None
for _path in _CANDIDATE_PATHS:
    if os.path.exists(_path):
        try:
            _lib = ctypes.CDLL(_path)
            break
        except OSError:
            continue
if _lib is None:
    raise OSError("找不到 libliana_ffi；请先构建（cargo build --release -p liana_ffi）"
                  "或设置 LIANA_FFI_PATH")


def _bind():
    l = _lib
    ptr = ctypes.c_void_p
    str_p = ctypes.c_char_p
    l.liana_new.argtypes, l.liana_new.restype = [str_p], ptr
    l.liana_new_with_dict.argtypes, l.liana_new_with_dict.restype = [str_p, str_p], ptr
    l.liana_free.argtypes, l.liana_free.restype = [ptr], None
    l.liana_feed.argtypes, l.liana_feed.restype = [ptr, str_p], ctypes.c_int32
    l.liana_backspace.argtypes, l.liana_backspace.restype = [ptr], ctypes.c_int32
    l.liana_clear.argtypes, l.liana_clear.restype = [ptr], None
    l.liana_set_mode.argtypes, l.liana_set_mode.restype = [ptr, str_p], ctypes.c_int32
    l.liana_mode.argtypes, l.liana_mode.restype = [ptr], ptr
    l.liana_languages.argtypes, l.liana_languages.restype = [], ptr
    l.liana_set_traditional.argtypes, l.liana_set_traditional.restype = [ptr, ctypes.c_int32], ctypes.c_int32
    l.liana_traditional.argtypes, l.liana_traditional.restype = [ptr], ctypes.c_int32
    l.liana_composition_json.argtypes, l.liana_composition_json.restype = [ptr], ptr
    l.liana_select.argtypes, l.liana_select.restype = [ptr, ctypes.c_uint32], ptr
    l.liana_commit_raw.argtypes, l.liana_commit_raw.restype = [ptr], ptr
    l.liana_record_commit.argtypes, l.liana_record_commit.restype = [ptr, str_p], ctypes.c_int32
    l.liana_user_export.argtypes, l.liana_user_export.restype = [ptr], ptr
    l.liana_user_import.argtypes, l.liana_user_import.restype = [ptr, str_p], ctypes.c_int32
    l.liana_backup_export.argtypes, l.liana_backup_export.restype = [ptr], ptr
    l.liana_backup_import.argtypes, l.liana_backup_import.restype = [ptr, str_p, ctypes.c_int32], ctypes.c_int32
    l.liana_free_string.argtypes, l.liana_free_string.restype = [ptr], None
    l.liana_version.argtypes, l.liana_version.restype = [], str_p


_bind()


def languages():
    """内置语言清单：[{"id":..., "label":..., "policy":...}]。"""
    return json.loads(_take_str(_lib.liana_languages()) or "[]")


def _take_str(cptr):
    """领走 C 字符串：c_char_p restype 会把指针转成 bytes 拷贝导致原始指针
    丢失（free 时释放错内存直接 abort），所以字符串返回值一律 restype=c_void_p，
    此处 cast 读内容、再释放原始指针。"""
    if not cptr:
        return None
    s = ctypes.cast(cptr, ctypes.c_char_p).value.decode("utf-8", "replace")
    _lib.liana_free_string(cptr)
    return s


class Session:
    """一个输入会话；JSON 语义与 liana.h 注释一致。"""

    def __init__(self, mode="pinyin", dict_path=None):
        if dict_path:
            self._h = _lib.liana_new_with_dict(mode.encode(), dict_path.encode())
        else:
            self._h = _lib.liana_new(mode.encode())
        if not self._h:
            raise RuntimeError("liana_new 失败")

    def __del__(self):
        if getattr(self, "_h", None):
            _lib.liana_free(self._h)
            self._h = None

    def feed(self, ch: str) -> bool:
        return _lib.liana_feed(self._h, ch.encode()) == 1

    def backspace(self) -> bool:
        return _lib.liana_backspace(self._h) == 1

    def clear(self):
        _lib.liana_clear(self._h)

    def set_mode(self, mode: str) -> bool:
        return _lib.liana_set_mode(self._h, mode.encode()) == 1

    @property
    def mode(self):
        return _take_str(_lib.liana_mode(self._h))

    def set_traditional(self, on: bool):
        _lib.liana_set_traditional(self._h, 1 if on else 0)

    @property
    def traditional(self) -> bool:
        return _lib.liana_traditional(self._h) == 1

    def composition(self) -> dict:
        js = _take_str(_lib.liana_composition_json(self._h))
        return json.loads(js) if js else {}

    def select(self, index: int):
        return _take_str(_lib.liana_select(self._h, index))

    def commit_raw(self):
        return _take_str(_lib.liana_commit_raw(self._h))

    def record_commit(self, text: str) -> bool:
        return _lib.liana_record_commit(self._h, text.encode()) == 0

    def user_export(self):
        return _take_str(_lib.liana_user_export(self._h))

    def user_import(self, tsv: str) -> bool:
        return _lib.liana_user_import(self._h, tsv.encode()) >= 0

    def backup_export(self):
        return _take_str(_lib.liana_backup_export(self._h))

    def backup_import(self, text: str, merge=True) -> bool:
        return _lib.liana_backup_import(self._h, text.encode(), 1 if merge else 0) >= 0


def version() -> str:
    # 静态字符串，勿释放（restype c_char_p 由 ctypes 自动转 bytes）
    return _lib.liana_version().decode("utf-8")