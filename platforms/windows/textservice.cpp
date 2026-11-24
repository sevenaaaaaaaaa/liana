// Liana TSF 文本服务实现
//
// 按键流：OnKeyDown → liana_feed/liana_backspace → liana_composition_json
//         → TODO: edit session 组合上屏（微软 keystroke 样板的 ITfComposition 流程）
// 上屏流：数字键/空格 → liana_select → TODO: composition commit
//
// 说明：TSF 的组合文本（composition）与候选窗 UI 是本文件剩余工作量的大头，
// 需在 Windows 机器上配合微软 TextService 样板逐段调试；引擎调用部分已完整。
#include "textservice.h"

#include <cstring>
#include <new>      // std::nothrow（工厂 CreateInstance 用它做不抛异常的 new）
#include <string>   // std::string（词典路径转 UTF-8）
#include <vector>

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

// ---- 词典路径 ----
// DLL 与 base.ifd / base.lm 同目录（build.cmd 生成、安装包同层分发）。
// 过去这里写的是 liana_new("pinyin")，内核退回 200 条内置词典，整句准确率与其它端差一大截。
static std::string DictPathNextToDll() {
    wchar_t path[MAX_PATH]{};
    if (!GetModuleFileNameW(g_hInst, path, MAX_PATH)) return {};
    std::wstring dir(path);
    const auto slash = dir.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    dir.resize(slash + 1);
    dir += L"base.ifd";
    // 栈缓冲直接转：路径不超过 MAX_PATH，不用 C++17 的 std::string::data() 可写重载
    // （build.cmd 没开 /std:c++17，那个重载在 C++14 下返回 const char*，MSVC 会报 C2664）
    char buf[MAX_PATH * 3]{};
    const int n = WideCharToMultiByte(CP_UTF8, 0, dir.c_str(), -1, buf, sizeof(buf), nullptr, nullptr);
    if (n <= 1) return {};
    return std::string(buf);
}

// ---- Activate / Deactivate ----

STDMETHODIMP CTextService::Activate(ITfThreadMgr *ptim, TfClientId tid) {
    thread_mgr_ = ptim;
    client_id_ = tid;
    thread_mgr_->AddRef();

    // 内核会话：优先加载 DLL 同目录的 base.ifd（旁边有 base.lm 时整句再看上下文）；
    // 文件缺失才退回内置词典。
    const std::string dict = DictPathNextToDll();
    session_ = dict.empty() ? nullptr : liana_new_with_dict("pinyin", dict.c_str());
    if (!session_) session_ = liana_new("pinyin");
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

namespace {

// 找 liana-peer.exe：先看 DLL 同目录，再看 PATH。
std::string PeerBinary() {
    wchar_t module[MAX_PATH]{};
    if (GetModuleFileNameW(g_hInst, module, MAX_PATH)) {
        std::wstring dir(module);
        const auto slash = dir.find_last_of(L"\\/");
        if (slash != std::wstring::npos) {
            dir.resize(slash + 1);
            std::wstring candidate = dir + L"liana-peer.exe";
            if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) {
                char buf[MAX_PATH * 3]{};
                const int n = WideCharToMultiByte(CP_UTF8, 0, candidate.c_str(), -1, buf, sizeof(buf), nullptr, nullptr);
                if (n > 1) return std::string(buf);
            }
        }
    }
    return "liana-peer.exe";
}

// 调 liana-peer pull，把 stdout 收回来。失败返回空串。
std::string RunPeerPull() {
    const std::string exe = PeerBinary();
    SECURITY_ATTRIBUTES sa{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE readEnd = nullptr, writeEnd = nullptr;
    if (!CreatePipe(&readEnd, &writeEnd, &sa, 0)) return {};
    SetHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = writeEnd;
    si.hStdError = writeEnd;
    si.hStdInput = nullptr;
    PROCESS_INFORMATION pi{};
    std::string command = "\"" + exe + "\" pull";
    std::vector<char> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back('\0');
    const BOOL started = CreateProcessA(nullptr, mutableCommand.data(), nullptr, nullptr, TRUE,
                                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(writeEnd);
    if (!started) {
        CloseHandle(readEnd);
        return {};
    }
    std::string output;
    char buffer[512];
    DWORD read = 0;
    while (ReadFile(readEnd, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
        output.append(buffer, read);
        if (output.size() > 64 * 1024) break;
    }
    WaitForSingleObject(pi.hProcess, 30000);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(readEnd);
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) output.pop_back();
    return output;
}

void CopyToClipboard(const std::string& utf8) {
    if (utf8.empty()) return;
    const int wideLen = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (wideLen <= 1) return;
    std::wstring wide(static_cast<size_t>(wideLen), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], wideLen);
    if (!OpenClipboard(nullptr)) return;
    EmptyClipboard();
    const size_t bytes = wide.size() * sizeof(wchar_t);
    if (HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
        if (void* target = GlobalLock(mem)) {
            memcpy(target, wide.data(), bytes);
            GlobalUnlock(mem);
            SetClipboardData(CF_UNICODETEXT, mem);
        }
    }
    CloseClipboard();
}

}  // namespace

STDMETHODIMP CTextService::OnKeyDown(ITfContext *pic, WPARAM wParam, LPARAM, BOOL *pfEaten) {
    *pfEaten = FALSE;
    // Ctrl+Alt+V：从同一局域网的 Mac 拉剪贴板。TSF 的组合上屏还没接，
    // 所以落到系统剪贴板，用户 Ctrl+V 即可——比什么都不做强，也不用等编辑会话。
    if ((GetKeyState(VK_CONTROL) & 0x8000) && (GetKeyState(VK_MENU) & 0x8000) && wParam == 'V') {
        const std::string text = RunPeerPull();
        if (!text.empty()) {
            CopyToClipboard(text);
            *pfEaten = TRUE;
        }
        return S_OK;
    }
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