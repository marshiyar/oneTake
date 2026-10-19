// Common item dialogs (IFileOpenDialog / IFileSaveDialog) behind include/mpvfx_win32.h: the Windows file pickers,
// folders included, which GetOpenFileNameW cannot pick.
#ifdef _WIN32
#include "com.hpp"
#include "mpvfx_win32.h"

#include <shobjidl.h>

using mpvfx::Com;

namespace {

HRESULT report(IShellItem *item, mpvfx_path_callback cb, void *context) {
    PWSTR path = nullptr;
    const HRESULT hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
    if (FAILED(hr)) return hr;
    cb(context, reinterpret_cast<const uint16_t *>(path));
    CoTaskMemFree(path);
    return S_OK;
}

/// S_FALSE for a cancelled dialog (the user closed it), the HRESULT for a real failure.
HRESULT shown(HRESULT hr) { return hr == HRESULT_FROM_WIN32(ERROR_CANCELLED) ? S_FALSE : hr; }

}  // namespace

extern "C" {

mpvfx_hresult mpvfx_dialog_open(const MpvfxDialog *request, mpvfx_path_callback cb, void *context) {
    HRESULT hr = mpvfx::ensureCom();
    Com<IFileOpenDialog> dialog;
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IFileOpenDialog),
                              dialog.putVoid());
    }
    if (FAILED(hr)) return hr;
    FILEOPENDIALOGOPTIONS options = 0;
    dialog->GetOptions(&options);
    options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
    if (request->folders) options |= FOS_PICKFOLDERS; else options |= FOS_FILEMUSTEXIST;
    if (request->multiple) options |= FOS_ALLOWMULTISELECT;
    dialog->SetOptions(options);
    if (request->title) dialog->SetTitle(reinterpret_cast<const wchar_t *>(request->title));
    hr = shown(dialog->Show(static_cast<HWND>(request->owner)));
    if (hr != S_OK) return hr;
    Com<IShellItemArray> items;
    hr = dialog->GetResults(items.put());
    if (FAILED(hr)) return hr;
    DWORD count = 0;
    items->GetCount(&count);
    for (DWORD i = 0; i < count && SUCCEEDED(hr); ++i) {
        Com<IShellItem> item;
        hr = items->GetItemAt(i, item.put());
        if (SUCCEEDED(hr)) hr = report(item.get(), cb, context);
    }
    return hr;
}

mpvfx_hresult mpvfx_dialog_save(const MpvfxDialog *request, mpvfx_path_callback cb, void *context) {
    HRESULT hr = mpvfx::ensureCom();
    Com<IFileSaveDialog> dialog;
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IFileSaveDialog),
                              dialog.putVoid());
    }
    if (FAILED(hr)) return hr;
    FILEOPENDIALOGOPTIONS options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT);
    auto wide = [](const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); };
    if (request->title) dialog->SetTitle(wide(request->title));
    if (request->default_name) dialog->SetFileName(wide(request->default_name));
    if (request->button) dialog->SetOkButtonLabel(wide(request->button));
    if (request->filter_spec) {
        const COMDLG_FILTERSPEC spec = {request->filter_name ? wide(request->filter_name) : L"", wide(request->filter_spec)};
        dialog->SetFileTypes(1, &spec);
    }
    hr = shown(dialog->Show(static_cast<HWND>(request->owner)));
    if (hr != S_OK) return hr;
    Com<IShellItem> item;
    hr = dialog->GetResult(item.put());
    if (FAILED(hr)) return hr;
    return report(item.get(), cb, context);
}

}  // extern "C"
#endif
