// Liana NAPI 垫片（鸿蒙）
//
// 与 macOS/Android/iOS 同构：Rust 侧保持纯 C ABI（liana.h），
// 本文件是 ArkTS ↔ C ABI 的唯一边界，静态链接 libliana_ffi.a。
// 构建：OHOS SDK 的 clang（aarch64-unknown-linux-ohos），见 build_ohos.sh。
#include <napi.h>
#include <cstdlib>
#include <cstring>
#include <string>
#include "liana.h"

static LianaSession *ptr_from(long v) { return reinterpret_cast<LianaSession *>(v); }

static std::string take(char *cstr) {
    if (!cstr) return "";
    std::string s(cstr);
    liana_free_string(cstr);
    return s;
}

Napi::Value New(const Napi::CallbackInfo &info) {
    std::string mode = info[0].As<Napi::String>();
    auto h = reinterpret_cast<long>(liana_new(mode.c_str()));
    return Napi::Number::New(info.Env(), static_cast<double>(h));
}

Napi::Value NewWithDict(const Napi::CallbackInfo &info) {
    std::string mode = info[0].As<Napi::String>();
    std::string dict = info[1].As<Napi::String>();
    auto h = reinterpret_cast<long>(liana_new_with_dict(mode.c_str(), dict.c_str()));
    return Napi::Number::New(info.Env(), static_cast<double>(h));
}

void Free(const Napi::CallbackInfo &info) { liana_free(ptr_from(info[0].As<Napi::Number>().Int64Value())); }

Napi::Value Feed(const Napi::CallbackInfo &info) {
    auto s = ptr_from(info[0].As<Napi::Number>().Int64Value());
    std::string ch = info[1].As<Napi::String>();
    return Napi::Boolean::New(info.Env(), liana_feed(s, ch.c_str()) == 1);
}

Napi::Value Backspace(const Napi::CallbackInfo &info) {
    return Napi::Boolean::New(info.Env(), liana_backspace(ptr_from(info[0].As<Napi::Number>().Int64Value())) == 1);
}

void Clear(const Napi::CallbackInfo &info) { liana_clear(ptr_from(info[0].As<Napi::Number>().Int64Value())); }

Napi::Value SetMode(const Napi::CallbackInfo &info) {
    auto s = ptr_from(info[0].As<Napi::Number>().Int64Value());
    std::string mode = info[1].As<Napi::String>();
    return Napi::Boolean::New(info.Env(), liana_set_mode(s, mode.c_str()) == 1);
}

Napi::Value CompositionJson(const Napi::CallbackInfo &info) {
    auto s = ptr_from(info[0].As<Napi::Number>().Int64Value());
    return Napi::String::New(info.Env(), take(liana_composition_json(s)));
}

Napi::Value Select(const Napi::CallbackInfo &info) {
    auto s = ptr_from(info[0].As<Napi::Number>().Int64Value());
    int index = info[1].As<Napi::Number>().Uint32Value();
    return Napi::String::New(info.Env(), take(liana_select(s, index)));
}

Napi::Value CommitRaw(const Napi::CallbackInfo &info) {
    return Napi::String::New(info.Env(), take(liana_commit_raw(ptr_from(info[0].As<Napi::Number>().Int64Value()))));
}

Napi::Value Version(const Napi::CallbackInfo &info) {
    return Napi::String::New(info.Env(), liana_version());
}

// 内置语言清单（JSON）。菜单的唯一来源：ArkTS 侧不再写死 ['pinyin','en']。
Napi::Value Languages(const Napi::CallbackInfo &info) {
    return Napi::String::New(info.Env(), take(liana_languages()));
}

Napi::Object InitLiana(Napi::Env env, Napi::Object exports) {
    exports.Set("new", Napi::Function::New(env, New));
    exports.Set("newWithDict", Napi::Function::New(env, NewWithDict));
    exports.Set("free", Napi::Function::New(env, Free));
    exports.Set("feed", Napi::Function::New(env, Feed));
    exports.Set("backspace", Napi::Function::New(env, Backspace));
    exports.Set("clear", Napi::Function::New(env, Clear));
    exports.Set("setMode", Napi::Function::New(env, SetMode));
    exports.Set("compositionJson", Napi::Function::New(env, CompositionJson));
    exports.Set("select", Napi::Function::New(env, Select));
    exports.Set("commitRaw", Napi::Function::New(env, CommitRaw));
    exports.Set("version", Napi::Function::New(env, Version));
    exports.Set("languages", Napi::Function::New(env, Languages));
    return exports;
}

NODE_API_MODULE(liana, InitLiana)