// Speech recognition behind include/mpvfx_win32.h: the in-process desktop recognizer of the Speech API (SAPI 5)
// reading a WAV file. Only the in-process recognizer is created (the input is the local file), general dictation is
// loaded with LoadDictation, and recognition ends with the stream.
#ifdef _WIN32
#include "com.hpp"
#include "mpvfx_win32.h"

#include <sapi.h>

#include <atomic>
#include <cstdlib>
#include <cwchar>
#include <string>
#include <vector>

using mpvfx::Com;

namespace {
std::atomic<int64_t> liveObjects{0};

/// A COM pointer counted in `liveObjects` while it holds an object, so a test can see that every one was released.
template <class T> class Counted {
public:
    Counted() = default;
    Counted(const Counted &) = delete;
    Counted &operator=(const Counted &) = delete;
    ~Counted() { reset(); }
    /// Out-parameter for a creating call; call `acquired()` when it succeeded.
    T **put() { reset(); return com_.put(); }
    void **putVoid() { reset(); return com_.putVoid(); }
    void acquired() { if (com_ && !held_) { ++liveObjects; held_ = true; } }
    /// Takes a new reference to `p` (replacing what is held).
    void adopt(T *p) { reset(); p->AddRef(); *com_.put() = p; acquired(); }
    void reset() { if (held_) { --liveObjects; held_ = false; } com_.reset(); }
    T *get() const { return com_.get(); }
    T *operator->() const { return com_.get(); }
private:
    Com<T> com_;
    bool held_ = false;
};

template <class T> HRESULT create(const CLSID &clsid, Counted<T> &out) {
    HRESULT hr = CoCreateInstance(clsid, nullptr, CLSCTX_ALL, __uuidof(T), out.putVoid());
    if (SUCCEEDED(hr)) out.acquired();
    return hr;
}

/// The language ids a recognizer token declares, from its "Attributes\Language" value ("409;9": hex ids).
std::vector<uint32_t> tokenLanguages(ISpObjectToken *token) {
    std::vector<uint32_t> ids;
    Counted<ISpDataKey> key;
    if (FAILED(token->OpenKey(L"Attributes", key.put()))) return ids;
    key.acquired();
    LPWSTR value = nullptr;
    if (FAILED(key->GetStringValue(L"Language", &value)) || !value) return ids;
    std::wstring text(value);
    CoTaskMemFree(value);
    size_t at = 0;
    while (at <= text.size()) {
        size_t end = text.find(L';', at);
        if (end == std::wstring::npos) end = text.size();
        if (end > at) ids.push_back(static_cast<uint32_t>(wcstoul(text.substr(at, end - at).c_str(), nullptr, 16)));
        at = end + 1;
    }
    return ids;
}

/// Calls `visit(token, languages)` for each installed recognizer token; stops when it returns true.
template <class F> HRESULT eachRecognizer(F visit) {
    HRESULT hr = mpvfx::ensureCom();
    if (FAILED(hr)) return hr;
    Counted<ISpObjectTokenCategory> category;
    hr = create<ISpObjectTokenCategory>(__uuidof(SpObjectTokenCategory), category);
    if (FAILED(hr)) return hr;
    hr = category->SetId(SPCAT_RECOGNIZERS, FALSE);
    if (FAILED(hr)) return hr;
    Counted<IEnumSpObjectTokens> tokens;
    hr = category->EnumTokens(nullptr, nullptr, tokens.put());
    if (FAILED(hr)) return hr;
    tokens.acquired();
    for (;;) {
        Counted<ISpObjectToken> token;
        ULONG fetched = 0;
        if (tokens->Next(1, token.put(), &fetched) != S_OK || fetched == 0) break;
        token.acquired();
        if (visit(token.get(), tokenLanguages(token.get()))) break;
    }
    return S_OK;
}

int matchRank(const std::vector<uint32_t> &ids, uint32_t lcid) {
    int best = 0;
    for (uint32_t id : ids) {
        if (id == lcid) return 2;
        if ((id & 0x3FF) == (lcid & 0x3FF)) best = 1;
    }
    return best;
}

void releaseEvent(SPEVENT &ev) {
    if (!ev.lParam) return;
    if (ev.elParamType == SPET_LPARAM_IS_OBJECT) reinterpret_cast<IUnknown *>(ev.lParam)->Release();
    else if (ev.elParamType == SPET_LPARAM_IS_POINTER || ev.elParamType == SPET_LPARAM_IS_STRING)
        CoTaskMemFree(reinterpret_cast<void *>(ev.lParam));
}

/// Reports the words of one recognition. The phrase position is bytes of the stream, converted with the file's rate.
void reportPhrase(ISpRecoResult *result, uint32_t bytesPerSecond, mpvfx_speech_word_callback word, void *context) {
    SPPHRASE *phrase = nullptr;
    if (FAILED(result->GetPhrase(&phrase)) || !phrase) return;
    const int64_t phraseStart = bytesPerSecond ? static_cast<int64_t>(phrase->ullAudioStreamPosition) * 10000000LL / bytesPerSecond : 0;
    for (ULONG i = 0; i < phrase->Rule.ulCountOfElements; ++i) {
        const SPPHRASEELEMENT &e = phrase->pElements[i];
        const WCHAR *text = e.pszDisplayText ? e.pszDisplayText : e.pszLexicalForm;
        if (!text) continue;
        word(context, reinterpret_cast<const uint16_t *>(text), static_cast<int32_t>(wcslen(text)),
             phraseStart + static_cast<int64_t>(e.ulAudioTimeOffset), static_cast<int64_t>(e.ulAudioSizeTime));
    }
    CoTaskMemFree(phrase);
}
}  // namespace

extern "C" {

mpvfx_hresult mpvfx_speech_recognizer_installed(uint32_t lcid, int32_t *installed) {
    if (!installed) return E_POINTER;
    *installed = 0;
    return eachRecognizer([&](ISpObjectToken *, const std::vector<uint32_t> &ids) {
        if (matchRank(ids, lcid) > 0) *installed = 1;
        return *installed != 0;
    });
}

mpvfx_hresult mpvfx_speech_languages(mpvfx_speech_language_callback cb, void *context) {
    if (!cb) return E_POINTER;
    return eachRecognizer([&](ISpObjectToken *, const std::vector<uint32_t> &ids) {
        for (uint32_t id : ids) {
            WCHAR name[LOCALE_NAME_MAX_LENGTH] = {};
            if (LCIDToLocaleName(id, name, LOCALE_NAME_MAX_LENGTH, 0) > 0) cb(context, reinterpret_cast<const uint16_t *>(name));
        }
        return false;
    });
}

mpvfx_hresult mpvfx_speech_locale_lcid(const uint16_t *locale_name, uint32_t *lcid) {
    if (!locale_name || !lcid) return E_POINTER;
    LCID id = LocaleNameToLCID(reinterpret_cast<LPCWSTR>(locale_name), LOCALE_ALLOW_NEUTRAL_NAMES);
    if (id == 0) return E_INVALIDARG;
    *lcid = static_cast<uint32_t>(id);
    return S_OK;
}

mpvfx_hresult mpvfx_speech_recognize(const uint16_t *path, uint32_t lcid, uint32_t bytes_per_second,
                                     mpvfx_speech_word_callback word, void *word_context,
                                     mpvfx_speech_cancel_callback cancelled, void *cancel_context) {
    if (!path || !word) return E_POINTER;
    HRESULT hr = mpvfx::ensureCom();
    if (FAILED(hr)) return hr;
    // The recognizer token for the language: the best match among the installed ones.
    Counted<ISpObjectToken> chosen;
    int rank = 0;
    hr = eachRecognizer([&](ISpObjectToken *token, const std::vector<uint32_t> &ids) {
        int r = matchRank(ids, lcid);
        if (r > rank) { rank = r; chosen.adopt(token); }
        return r == 2;
    });
    if (FAILED(hr)) return hr;
    if (rank == 0) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);

    Counted<ISpRecognizer> recognizer;
    hr = create<ISpRecognizer>(__uuidof(SpInprocRecognizer), recognizer);
    if (FAILED(hr)) return hr;
    hr = recognizer->SetRecognizer(chosen.get());
    if (FAILED(hr)) return hr;
    Counted<ISpStream> stream;
    hr = create<ISpStream>(__uuidof(SpStream), stream);
    if (FAILED(hr)) return hr;
    hr = stream->BindToFile(reinterpret_cast<LPCWSTR>(path), SPFM_OPEN_READONLY, nullptr, nullptr, SPFEI_ALL_EVENTS);
    if (FAILED(hr)) return hr;
    hr = recognizer->SetInput(stream.get(), TRUE);
    if (FAILED(hr)) return hr;
    Counted<ISpRecoContext> context;
    hr = recognizer->CreateRecoContext(context.put());
    if (FAILED(hr)) return hr;
    context.acquired();
    hr = context->SetNotifyWin32Event();
    if (FAILED(hr)) return hr;
    const ULONGLONG interest = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_END_SR_STREAM);
    hr = context->SetInterest(interest, interest);
    if (FAILED(hr)) return hr;
    Counted<ISpRecoGrammar> grammar;
    hr = context->CreateGrammar(1, grammar.put());
    if (FAILED(hr)) return hr;
    grammar.acquired();
    hr = grammar->LoadDictation(nullptr, SPLO_STATIC);
    if (FAILED(hr)) return hr;
    hr = grammar->SetDictationState(SPRS_ACTIVE);
    if (FAILED(hr)) return hr;

    HANDLE notify = context->GetNotifyEventHandle();
    for (;;) {
        if (cancelled && cancelled(cancel_context)) {
            grammar->SetDictationState(SPRS_INACTIVE);
            return E_ABORT;
        }
        WaitForSingleObject(notify, 50);
        SPEVENT ev = {};
        ULONG fetched = 0;
        while (SUCCEEDED(context->GetEvents(1, &ev, &fetched)) && fetched == 1) {
            const WORD id = ev.eEventId;
            if (id == SPEI_RECOGNITION && ev.elParamType == SPET_LPARAM_IS_OBJECT && ev.lParam)
                reportPhrase(reinterpret_cast<ISpRecoResult *>(ev.lParam), bytes_per_second, word, word_context);
            releaseEvent(ev);
            if (id == SPEI_END_SR_STREAM) { grammar->SetDictationState(SPRS_INACTIVE); return S_OK; }
            ev = {};
            fetched = 0;
        }
    }
}

int64_t mpvfx_speech_live_objects(void) { return liveObjects.load(); }

}  // extern "C"
#endif
