// Shared helpers of the Windows sources: an owning COM pointer and per-thread COM initialisation.
#pragma once
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objbase.h>

namespace mpvfx {

/// Owns one reference to a COM object; released on destruction.
template <class T> class Com {
public:
    Com() = default;
    Com(const Com &) = delete;
    Com &operator=(const Com &) = delete;
    Com(Com &&o) noexcept : p_(o.p_) { o.p_ = nullptr; }
    Com &operator=(Com &&o) noexcept {
        if (this != &o) { reset(); p_ = o.p_; o.p_ = nullptr; }
        return *this;
    }
    ~Com() { reset(); }
    void reset() { if (p_) { p_->Release(); p_ = nullptr; } }
    T *get() const { return p_; }
    T *operator->() const { return p_; }
    explicit operator bool() const { return p_ != nullptr; }
    /// Out-parameter for a creating call: releases what is held first.
    T **put() { reset(); return &p_; }
    void **putVoid() { reset(); return reinterpret_cast<void **>(&p_); }
    /// Takes over a reference the caller already owns.
    void attach(T *p) { reset(); p_ = p; }

private:
    T *p_ = nullptr;
};

/// COM on the calling thread, multi-threaded apartment unless the thread already chose one (a UI thread that
/// initialised an STA keeps it: RPC_E_CHANGED_MODE is not a failure, COM is usable either way).
inline HRESULT ensureCom() {
    thread_local bool tried = false;
    thread_local HRESULT state = S_OK;
    if (!tried) {
        tried = true;
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        state = (SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE) ? S_OK : hr;
    }
    return state;
}

}  // namespace mpvfx
#endif
