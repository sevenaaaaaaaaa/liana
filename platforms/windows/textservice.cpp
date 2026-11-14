// Liana TSF 文本服务实现
//
// 按键流：OnKeyDown → liana_feed/liana_backspace → liana_composition_json
//         → TODO: edit session 组合上屏（微软 keystroke 样板的 ITfComposition 流程）
// 上屏流：数字键/空格 → liana_select → TODO: composition commit
//
// 说明：TSF 的组合文本（composition）与候选窗 UI 是本文件剩余工作量的大头，
// 需在 Windows 机器上配合微软 TextService 样板逐段调试；引擎调用部分已完整。
#include "textservice.h"

#include <new>  // std::nothrow（工厂 CreateInstance 用它做不抛异常的 new）

// textservice.h 里的 DEFINE_GUID 只是声明；这里给出唯一实体，否则链接报
// LNK2019: unresolved external symbol CLSID_LianaTextService。不用 INITGUID，
// 那会让 msctf.h 的 IID 也在本 TU 定义，与 midl 生成的 msctf_i.obj 重复。
const GUID CLSID_LianaTextService =
    {0xb8a9f9a0, 0x1c2d, 0x4e3f, {0x9a, 0x5b, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6}};

static HINSTANCE g_hInst = nullptr;
static ULONG g_cLock = 0;

// ---- IUnknown / 生命周期 ----

CTextService::CTextService() = default;

CTextService::~CTextService() {
    if (session_) liana_free(session_);
}

STDMETHODIMP CTextService::QueryInterface(REFIID riid, void **ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (riid == IID_IUnknown || riid == IID_ITfTextInputProcessor)
        *ppv = static_cast<ITfTextInputProcessor *>(this);
    else if (riid == IID_ITfKeyEventSink)
        *ppv = static_cast<ITfKeyEventSink *>(this);
    if (*ppv) {
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) CTextService::AddRef() { return InterlockedIncrement(&ref_); }

STDMETHODIMP_(ULONG) CTextService::Release() {
    ULONG c = InterlockedDecrement(&ref_);
    if (!c) delete this;
    return c;
}

// ---- Activate / Deactivate ----

STDMETHODIMP CTextService::Activate(ITfThreadMgr *ptim, TfClientId tid) {
    thread_mgr_ = ptim;
    client_id_ = tid;
    thread_mgr_->AddRef();

    // 内核会话：传 NULL 用内置词典；正式版改为从安装目录加载 base.ifd
    session_ = liana_new("pinyin");
    if (!session_) return E_OUTOFMEMORY;

    // TODO: AdviseKeyEventSink + 候选窗（ITfCandidateListUIElement 或自绘窗口）
    return S_OK;
}

STDMETHODIMP CTextService::Deactivate() {
    if (session_) {
        liana_free(session_);
        session_ = nullptr;
    }
    if (thread_mgr_) {
        thread_mgr_->Release();
        thread_mgr_ = nullptr;
    }
    return S_OK;
}

// ---- 按键 sink：WPARAM 的 ASCII 直接喂内核 ----

static bool KeyToChar(WPARAM wParam, char *out) {
    // MVP：仅可打印 ASCII；完整 IME 需 VK→char 走 ToAscii（含 Shift 状态）
    if (wParam < 0x21 || wParam > 0x7E) return false;
    *out = static_cast<char>(wParam);
    return true;
}

STDMETHODIMP CTextService::OnTestKeyDown(ITfContext *, WPARAM wParam, LPARAM, BOOL *pfEaten) {
    char ch;
    *pfEaten = session_ && KeyToChar(wParam, &ch) ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP CTextService::OnKeyDown(ITfContext *pic, WPARAM wParam, LPARAM, BOOL *pfEaten) {
    *pfEaten = FALSE;
    if (!session_) return S_OK;

    char ch;
    if (KeyToChar(wParam, &ch)) {
        if (liana_feed(session_, &ch) == 1) {
            // TODO: 取 liana_composition_json → edit session 显示 preedit/候选
            *pfEaten = TRUE;
        }
        return S_OK;
    }
    switch (wParam) {
        case VK_SPACE: {
            // TODO: 首选上屏（liana_select(0) → composition commit）
            *pfEaten = TRUE;
            break;
        }
        case '1': case '2': case '3': case '4': case '5':
        case '6': case '7': case '8': case '9': {
            // TODO: 数字选词
            *pfEaten = TRUE;
            break;
        }
        case VK_BACK: {
            liana_backspace(session_);
            *pfEaten = TRUE;
            break;
        }
        case VK_RETURN: {
            // TODO: 原样上屏（liana_commit_raw → composition commit）
            *pfEaten = TRUE;
            break;
        }
        case VK_ESCAPE: {
            liana_clear(session_);
            *pfEaten = TRUE;
            break;
        }
        default: break;
    }
    return S_OK;
}

STDMETHODIMP CTextService::OnSetFocus(BOOL) { return S_OK; }

STDMETHODIMP CTextService::OnTestKeyUp(ITfContext *, WPARAM, LPARAM, BOOL *pfEaten) {
    *pfEaten = FALSE;
    return S_OK;
}

STDMETHODIMP CTextService::OnKeyUp(ITfContext *, WPARAM, LPARAM, BOOL *pfEaten) {
    *pfEaten = FALSE;
    return S_OK;
}

STDMETHODIMP CTextService::OnPreservedKey(ITfContext *, REFGUID, BOOL *pfEaten) {
    *pfEaten = FALSE;
    return S_OK;
}

// ---- 类厂 + DllMain + 注册 ----

class CClassFactory final : public IClassFactory {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return 2; }
    STDMETHODIMP_(ULONG) Release() override { return 2; }
    STDMETHODIMP CreateInstance(IUnknown *punk, REFIID riid, void **ppv) override {
        if (punk) return CLASS_E_NOAGGREGATION;
        auto *svc = new (std::nothrow) CTextService();
        if (!svc) return E_OUTOFMEMORY;
        HRESULT hr = svc->QueryInterface(riid, ppv);
        svc->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL) override { return S_OK; }
};

static CClassFactory g_factory;

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD, LPVOID) {
    g_hInst = hInst;
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    if (rclsid != CLSID_LianaTextService) return CLASS_E_CLASSNOTAVAILABLE;
    return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow(void) {
    return g_cLock == 0 ? S_OK : S_FALSE;
}

// 注册：regsvr32 路线。TIP 注册表约定：
//   HKLM\Software\Microsoft\CTF\TIP\<clsid> + Enable/CLSID/KeyboardLayout
//   HKCR\CLSID\<clsid>\InprocServer32 = DLL 路径
// TODO: 语言栏配置（KeyboardLayout\zh-CN 子键）在 Windows 机上按官方样板上调齐
STDAPI DllRegisterServer(void) {
    return E_NOTIMPL; // TODO: 完整 CTF/TIP 注册表写入
}

STDAPI DllUnregisterServer(void) {
    return E_NOTIMPL; // TODO: 反注册
}