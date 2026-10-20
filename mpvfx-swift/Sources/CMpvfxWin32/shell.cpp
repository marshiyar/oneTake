// Desktop shell services behind include/mpvfx_win32.h: the system light/dark setting, the window frame's dark
// mode, the text clipboard and Explorer.
#ifdef _WIN32
#include "com.hpp"
#include "mpvfx_win32.h"

#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>

#include <cstring>

extern "C" {

int32_t mpvfx_system_prefers_dark(void) {
    DWORD light = 1, size = sizeof(light);
    const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                        L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
    // No value (Windows before 10 1809, or never set): Windows apps default to light.
    return status == ERROR_SUCCESS && light == 0 ? 1 : 0;
}

int32_t mpvfx_is_appearance_change(const uint16_t *setting) {
    return setting && wcscmp(reinterpret_cast<const wchar_t *>(setting), L"ImmersiveColorSet") == 0 ? 1 : 0;
}

mpvfx_hresult mpvfx_window_set_dark_frame(void *hwnd, int32_t dark) {
    const BOOL value = dark ? TRUE : FALSE;
    // DWMWA_USE_IMMERSIVE_DARK_MODE (20) from Windows 10 20H1 on.
    return DwmSetWindowAttribute(static_cast<HWND>(hwnd), 20, &value, sizeof(value));
}

mpvfx_hresult mpvfx_clipboard_set_text(void *hwnd, const uint16_t *text) {
    const size_t bytes = (wcslen(reinterpret_cast<const wchar_t *>(text)) + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) return HRESULT_FROM_WIN32(GetLastError());
    void *data = GlobalLock(memory);
    if (!data) {
        const DWORD error = GetLastError();
        GlobalFree(memory);
        return HRESULT_FROM_WIN32(error);
    }
    std::memcpy(data, text, bytes);
    GlobalUnlock(memory);
    if (!OpenClipboard(static_cast<HWND>(hwnd))) {
        const DWORD error = GetLastError();
        GlobalFree(memory);
        return HRESULT_FROM_WIN32(error);
    }
    EmptyClipboard();
    const bool placed = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
    const DWORD error = GetLastError();
    CloseClipboard();
    if (!placed) { GlobalFree(memory); return HRESULT_FROM_WIN32(error); }
    return S_OK;   // the clipboard owns the memory now
}

mpvfx_hresult mpvfx_reveal_in_explorer(const uint16_t *path) {
    HRESULT hr = mpvfx::ensureCom();
    if (FAILED(hr)) return hr;
    PIDLIST_ABSOLUTE item = ILCreateFromPathW(reinterpret_cast<const wchar_t *>(path));
    if (!item) return E_INVALIDARG;
    hr = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    ILFree(item);
    return hr;
}

mpvfx_hresult mpvfx_shell_open(const uint16_t *path) {
    const HINSTANCE result = ShellExecuteW(nullptr, L"open", reinterpret_cast<const wchar_t *>(path), nullptr, nullptr, SW_SHOWNORMAL);
    // ShellExecuteW reports success as a value above 32.
    return reinterpret_cast<INT_PTR>(result) > 32 ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}

int32_t mpvfx_dropped_file_count(void *drop) { return static_cast<int32_t>(DragQueryFileW(static_cast<HDROP>(drop), 0xFFFFFFFF, nullptr, 0)); }

mpvfx_hresult mpvfx_dropped_file(void *drop, int32_t index, mpvfx_path_callback cb, void *context) {
    const UINT length = DragQueryFileW(static_cast<HDROP>(drop), static_cast<UINT>(index), nullptr, 0);
    if (length == 0) return E_INVALIDARG;
    wchar_t *buffer = new wchar_t[length + 1];
    DragQueryFileW(static_cast<HDROP>(drop), static_cast<UINT>(index), buffer, length + 1);
    cb(context, reinterpret_cast<const uint16_t *>(buffer));
    delete[] buffer;
    return S_OK;
}

}  // extern "C"
#endif
