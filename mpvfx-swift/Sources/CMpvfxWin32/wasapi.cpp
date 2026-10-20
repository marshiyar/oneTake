// WASAPI shared-mode render stream behind include/mpvfx_win32.h: IAudioClient (shared, float32 with the engine's
// format conversion), IAudioRenderClient for the writes, IAudioClock for the played position.
#ifdef _WIN32
#include "com.hpp"
#include "mpvfx_win32.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <propidl.h>
#include <mmreg.h>
#include <ksmedia.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>

using mpvfx::Com;

struct MpvfxWasapi {
    Com<IMMDevice> device;
    Com<IAudioClient> client;
    Com<IAudioRenderClient> render;
    Com<IAudioClock> clock;
    UINT32 bufferFrames = 0;
    UINT64 clockFrequency = 1;
    uint32_t sampleRate = 48000, channels = 2;
    std::atomic<bool> running{false};
    /// Serialises the client calls of the feeder thread (write) and the UI thread (start, stop, flush).
    std::mutex lock;
};

namespace {
// PKEY_Device_FriendlyName ({a45c254e-df1c-4efd-8020-67d146a850e0}, 14), spelled out so no INITGUID translation unit
// is needed to define it.
const PROPERTYKEY kDeviceFriendlyName = {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

HRESULT makeEnumerator(Com<IMMDeviceEnumerator> &enumerator) {
    HRESULT hr = mpvfx::ensureCom();
    if (FAILED(hr)) return hr;
    return CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                            enumerator.putVoid());
}

/// The endpoint `id`, only while it is an active render endpoint (an unplugged one fails instead of opening).
HRESULT activeRenderDevice(IMMDeviceEnumerator *enumerator, const uint16_t *id, Com<IMMDevice> &device) {
    HRESULT hr = enumerator->GetDevice(reinterpret_cast<LPCWSTR>(id), device.put());
    if (FAILED(hr)) return hr;
    DWORD state = 0;
    hr = device->GetState(&state);
    if (FAILED(hr)) return hr;
    return state == DEVICE_STATE_ACTIVE ? S_OK : E_NOTFOUND;
}
}  // namespace

extern "C" {

mpvfx_hresult mpvfx_wasapi_devices(mpvfx_audio_device_callback cb, void *context) {
    Com<IMMDeviceEnumerator> enumerator;
    HRESULT hr = makeEnumerator(enumerator);
    Com<IMMDeviceCollection> collection;
    if (SUCCEEDED(hr)) hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, collection.put());
    UINT count = 0;
    if (SUCCEEDED(hr)) hr = collection->GetCount(&count);
    if (FAILED(hr)) return hr;
    for (UINT i = 0; i < count; ++i) {
        Com<IMMDevice> device;
        LPWSTR id = nullptr;
        if (FAILED(collection->Item(i, device.put())) || FAILED(device->GetId(&id))) continue;
        Com<IPropertyStore> props;
        PROPVARIANT name;
        PropVariantInit(&name);
        const bool named = SUCCEEDED(device->OpenPropertyStore(STGM_READ, props.put())) &&
                           SUCCEEDED(props->GetValue(kDeviceFriendlyName, &name)) && name.vt == VT_LPWSTR && name.pwszVal;
        cb(context, reinterpret_cast<const uint16_t *>(id), reinterpret_cast<const uint16_t *>(named ? name.pwszVal : id));
        PropVariantClear(&name);
        CoTaskMemFree(id);
    }
    return S_OK;
}

mpvfx_hresult mpvfx_wasapi_open(uint32_t sample_rate, uint32_t channels, uint32_t buffer_ms, MpvfxWasapi **out) {
    return mpvfx_wasapi_open_device(nullptr, sample_rate, channels, buffer_ms, out);
}

mpvfx_hresult mpvfx_wasapi_open_device(const uint16_t *device_id, uint32_t sample_rate, uint32_t channels,
                                       uint32_t buffer_ms, MpvfxWasapi **out) {
    *out = nullptr;
    Com<IMMDeviceEnumerator> enumerator;
    HRESULT hr = makeEnumerator(enumerator);
    if (FAILED(hr)) return hr;
    auto *w = new MpvfxWasapi();
    w->sampleRate = sample_rate;
    w->channels = channels;
    hr = device_id ? activeRenderDevice(enumerator.get(), device_id, w->device)
                   : enumerator->GetDefaultAudioEndpoint(eRender, eConsole, w->device.put());
    if (SUCCEEDED(hr)) hr = w->device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, w->client.putVoid());
    if (SUCCEEDED(hr)) {
        WAVEFORMATEXTENSIBLE fmt = {};
        fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        fmt.Format.nChannels = static_cast<WORD>(channels);
        fmt.Format.nSamplesPerSec = sample_rate;
        fmt.Format.wBitsPerSample = 32;
        fmt.Format.nBlockAlign = static_cast<WORD>(channels * 4);
        fmt.Format.nAvgBytesPerSec = sample_rate * channels * 4;
        fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
        fmt.Samples.wValidBitsPerSample = 32;
        fmt.dwChannelMask = channels == 1 ? SPEAKER_FRONT_CENTER : (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT);
        fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
        // The audio engine converts rate and channel layout to the mix format (Windows 7 SP1+ shared mode).
        const DWORD flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        const REFERENCE_TIME duration = static_cast<REFERENCE_TIME>(std::max<uint32_t>(buffer_ms, 10)) * 10000;
        hr = w->client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, duration, 0,
                                   reinterpret_cast<WAVEFORMATEX *>(&fmt), nullptr);
    }
    if (SUCCEEDED(hr)) hr = w->client->GetBufferSize(&w->bufferFrames);
    if (SUCCEEDED(hr)) hr = w->client->GetService(__uuidof(IAudioRenderClient), w->render.putVoid());
    if (SUCCEEDED(hr)) hr = w->client->GetService(__uuidof(IAudioClock), w->clock.putVoid());
    if (SUCCEEDED(hr)) hr = w->clock->GetFrequency(&w->clockFrequency);
    if (FAILED(hr)) { delete w; return hr; }
    *out = w;
    return S_OK;
}

mpvfx_hresult mpvfx_wasapi_start(MpvfxWasapi *w) {
    std::lock_guard<std::mutex> g(w->lock);
    if (w->running) return S_OK;
    const HRESULT hr = w->client->Start();
    if (SUCCEEDED(hr)) w->running = true;
    return hr;
}

mpvfx_hresult mpvfx_wasapi_stop(MpvfxWasapi *w) {
    std::lock_guard<std::mutex> g(w->lock);
    if (!w->running) return S_OK;
    w->running = false;
    return w->client->Stop();
}

mpvfx_hresult mpvfx_wasapi_flush(MpvfxWasapi *w) {
    std::lock_guard<std::mutex> g(w->lock);
    const bool was = w->running;
    HRESULT hr = was ? w->client->Stop() : S_OK;
    if (SUCCEEDED(hr)) hr = w->client->Reset();   // drops the buffer, the clock position returns to 0
    if (SUCCEEDED(hr) && was) hr = w->client->Start();
    if (FAILED(hr)) w->running = false;
    return hr;
}

mpvfx_hresult mpvfx_wasapi_write(MpvfxWasapi *w, const float *samples, uint32_t frames) {
    uint32_t done = 0;
    while (done < frames) {
        UINT32 n = 0;
        {
            std::lock_guard<std::mutex> g(w->lock);
            if (!w->running) return AUDCLNT_E_NOT_INITIALIZED;   // stopped while waiting: the caller stops feeding
            UINT32 padding = 0;
            HRESULT hr = w->client->GetCurrentPadding(&padding);
            if (FAILED(hr)) return hr;
            n = std::min(w->bufferFrames - padding, frames - done);
            if (n > 0) {
                BYTE *data = nullptr;
                hr = w->render->GetBuffer(n, &data);
                if (FAILED(hr)) return hr;
                std::memcpy(data, samples + static_cast<size_t>(done) * w->channels, static_cast<size_t>(n) * w->channels * 4);
                hr = w->render->ReleaseBuffer(n, 0);
                if (FAILED(hr)) return hr;
                done += n;
            }
        }
        if (n == 0) Sleep(1);   // device buffer full: about a millisecond of audio plays before the next try
    }
    return S_OK;
}

mpvfx_hresult mpvfx_wasapi_position(MpvfxWasapi *w, uint64_t *frames) {
    std::lock_guard<std::mutex> g(w->lock);
    UINT64 position = 0;
    const HRESULT hr = w->clock->GetPosition(&position, nullptr);
    if (FAILED(hr)) { *frames = 0; return hr; }
    // Position is in clock units (GetFrequency per second), independent of the device's own rate.
    *frames = static_cast<uint64_t>(static_cast<long double>(position) * w->sampleRate / w->clockFrequency);
    return S_OK;
}

void mpvfx_wasapi_close(MpvfxWasapi *w) {
    if (!w) return;
    mpvfx_wasapi_stop(w);
    delete w;
}

}  // extern "C"
#endif
