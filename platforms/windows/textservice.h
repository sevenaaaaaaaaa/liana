// Liana TSF 文本服务（Windows）
//
// 架构与其它端一致：COM/TSF 协议翻译在 C++，引擎逻辑在 Rust 内核
// （libliana_ffi.lib 静态链接，直调 liana.h）。
//
// 状态：结构完整骨架。按键处理与引擎调用已接通；组合文本上屏
// （ITfComposition / edit session）按微软 keystroke TSF 样板补全 TODO 后
// 需在 Windows 机器上调试。
#ifndef LIANA_TEXTSERVICE_H
#define LIANA_TEXTSERVICE_H

#include <windows.h>
#include <msctf.h>
#include "liana.h"

// {B8A9F9A0-1L2B-4C3D-9E5F-A1B2C3D4E5F6} —— 正式发布前用 uuidgen 重新生成
DEFINE_GUID(CLSID_LianaTextService,
    0xb8a9f9a0, 0x1c2d, 0x4e3f, 0x9a, 0x5b, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6);

class CTextService final
    : public ITfTextInputProcessor
    , public ITfKeyEventSink {
public:
    CTextService();
    ~CTextService();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfTextInputProcessor
    STDMETHODIMP Activate(ITfThreadMgr *ptim, TfClientId tid) override;
    STDMETHODIMP Deactivate() override;

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL fForeground) override;
    STDMETHODIMP OnTestKeyDown(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnKeyDown(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnKeyUp(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext *pic, REFGUID rguid, BOOL *pfEaten) override;

    LianaSession *Session() const { return session_; }

private:
    LONG ref_ = 1;
    ITfThreadMgr *thread_mgr_ = nullptr;
    TfClientId client_id_ = 0;
    LianaSession *session_ = nullptr;
};

// 注册：regsvr32 需要的四个导出（见 dllmain.cpp）
STDAPI DllRegisterServer(void);
STDAPI DllUnregisterServer(void);

#endif // LIANA_TEXTSERVICE_H