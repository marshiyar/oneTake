// Direct2D + DirectWrite + WIC behind the C interface in include/mpvfx_win32.h (the Windows CanvasContext backend).
#ifdef _WIN32
#include "com.hpp"
#include "mpvfx_win32.h"

#include <d2d1.h>
#include <d2d1helper.h>
#include <dwrite.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <new>
#include <utility>
#include <vector>
#include <wchar.h>

using mpvfx::Com;

namespace {

struct Factories {
    Com<ID2D1Factory> d2d;
    Com<IDWriteFactory> dwrite;
    Com<IWICImagingFactory> wic;
    HRESULT status = E_FAIL;
};

Factories &factories() {
    static Factories f;
    static std::once_flag once;
    std::call_once(once, [] {
        // Multi-threaded: export rasterises text off the UI thread while the window paints.
        HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, __uuidof(ID2D1Factory), nullptr, f.d2d.putVoid());
        if (SUCCEEDED(hr)) {
            hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                     reinterpret_cast<IUnknown **>(f.dwrite.put()));
        }
        if (SUCCEEDED(hr)) hr = mpvfx::ensureCom();
        if (SUCCEEDED(hr)) {
            hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory),
                                  f.wic.putVoid());
        }
        f.status = hr;
    });
    return f;
}

D2D1_COLOR_F color(float r, float g, float b, float a) { return D2D1::ColorF(r, g, b, a); }

/// The generic family names the editor uses, as installed Windows families (others pass through unchanged and
/// fall back through DirectWrite's system font fallback when not installed).
const wchar_t *windowsFamily(const wchar_t *family) {
    if (!family || !*family) return L"Segoe UI";
    if (_wcsicmp(family, L"Sans") == 0 || _wcsicmp(family, L"sans-serif") == 0 || _wcsicmp(family, L"system-ui") == 0)
        return L"Segoe UI";
    if (_wcsicmp(family, L"Monospace") == 0 || _wcsicmp(family, L"monospace") == 0) return L"Consolas";
    if (_wcsicmp(family, L"Serif") == 0 || _wcsicmp(family, L"serif") == 0) return L"Times New Roman";
    return family;
}

HRESULT makeLayout(const MpvfxText &text, Com<IDWriteTextLayout> &out) {
    Factories &f = factories();
    if (FAILED(f.status)) return f.status;
    Com<IDWriteTextFormat> format;
    const DWRITE_FONT_WEIGHT w = static_cast<DWRITE_FONT_WEIGHT>(std::clamp(text.weight, 1, 999));
    HRESULT hr = f.dwrite->CreateTextFormat(windowsFamily(reinterpret_cast<const wchar_t *>(text.family)), nullptr, w,
                                            text.italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
                                            DWRITE_FONT_STRETCH_NORMAL, std::max(text.size, 0.01f), L"en-us", format.put());
    if (FAILED(hr)) return hr;
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    return f.dwrite->CreateTextLayout(reinterpret_cast<const wchar_t *>(text.text), static_cast<UINT32>(std::max(text.length, 0)),
                                      format.get(), 1.0e6f, 1.0e6f, out.put());
}

}  // namespace

struct MpvfxD2DTarget {
    Com<ID2D1RenderTarget> rt;
    Com<ID2D1HwndRenderTarget> hwnd;   // window targets
    Com<IWICBitmap> bitmap;            // offscreen targets
    Com<ID2D1SolidColorBrush> brush;   // one brush, recoloured per call
    std::vector<Com<ID2D1Layer>> layers;
    uint32_t width = 0, height = 0;

    HRESULT finish() {
        rt->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        return rt->CreateSolidColorBrush(color(0, 0, 0, 1), brush.put());
    }
    ID2D1SolidColorBrush *paint(MpvfxColor c) {
        brush->SetColor(color(c.r, c.g, c.b, c.a));
        return brush.get();
    }
};

namespace {

/// The path arrays as a path geometry (non-zero winding; a line after a close starts at the closed figure's start).
HRESULT geometry(const MpvfxPath &path, Com<ID2D1PathGeometry> &out) {
    const uint8_t *kinds = path.kinds;
    const float *pts = path.points;
    const int32_t nkinds = path.count;
    Factories &f = factories();
    if (FAILED(f.status)) return f.status;
    HRESULT hr = f.d2d->CreatePathGeometry(out.put());
    if (FAILED(hr)) return hr;
    Com<ID2D1GeometrySink> sink;
    hr = out->Open(sink.put());
    if (FAILED(hr)) return hr;
    sink->SetFillMode(D2D1_FILL_MODE_WINDING);
    bool open = false;
    D2D1_POINT_2F start = D2D1::Point2F(0, 0), last = start;
    int32_t p = 0;
    auto begin = [&](D2D1_POINT_2F at) {
        sink->BeginFigure(at, D2D1_FIGURE_BEGIN_FILLED);
        open = true; start = at; last = at;
    };
    for (int32_t i = 0; i < nkinds; ++i) {
        switch (kinds[i]) {
        case MPVFX_PATH_MOVE: {
            if (open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
            begin(D2D1::Point2F(pts[p], pts[p + 1]));
            p += 2;
            break;
        }
        case MPVFX_PATH_LINE: {
            D2D1_POINT_2F to = D2D1::Point2F(pts[p], pts[p + 1]);
            p += 2;
            if (!open) begin(last);
            sink->AddLine(to);
            last = to;
            break;
        }
        case MPVFX_PATH_CUBIC: {
            D2D1_BEZIER_SEGMENT seg = {D2D1::Point2F(pts[p], pts[p + 1]), D2D1::Point2F(pts[p + 2], pts[p + 3]),
                                       D2D1::Point2F(pts[p + 4], pts[p + 5])};
            p += 6;
            if (!open) begin(last);
            sink->AddBezier(seg);
            last = seg.point3;
            break;
        }
        case MPVFX_PATH_CLOSE:
            if (open) { sink->EndFigure(D2D1_FIGURE_END_CLOSED); open = false; last = start; }
            break;
        default:
            sink->Close();
            return E_INVALIDARG;
        }
    }
    if (open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
    return sink->Close();
}

/// E_POINTER / E_INVALIDARG when the pixels cannot become a bitmap of `t` (missing, empty, larger than it allows).
HRESULT checkBitmapInput(const MpvfxD2DTarget *t, const MpvfxPixels *pixels) {
    if (!t || !t->rt || !pixels || !pixels->rgba) return E_POINTER;
    const UINT32 maxSide = t->rt->GetMaximumBitmapSize();
    const bool fits = pixels->width > 0 && pixels->height > 0 && pixels->width <= maxSide && pixels->height <= maxSide;
    return fits ? S_OK : E_INVALIDARG;
}

/// Straight RGBA8 -> premultiplied BGRA8 (rounded), the layout of the bitmap.
std::vector<uint8_t> premultipliedBGRA(const MpvfxPixels &pixels) {
    const uint8_t *rgba = pixels.rgba;
    std::vector<uint8_t> bgra(static_cast<size_t>(pixels.width) * pixels.height * 4);
    for (size_t i = 0; i < bgra.size(); i += 4) {
        const uint32_t a = rgba[i + 3];
        bgra[i + 0] = static_cast<uint8_t>((rgba[i + 2] * a + 127) / 255);
        bgra[i + 1] = static_cast<uint8_t>((rgba[i + 1] * a + 127) / 255);
        bgra[i + 2] = static_cast<uint8_t>((rgba[i + 0] * a + 127) / 255);
        bgra[i + 3] = static_cast<uint8_t>(a);
    }
    return bgra;
}

}  // namespace

extern "C" {

mpvfx_hresult mpvfx_d2d_init(void) { return factories().status; }

mpvfx_hresult mpvfx_d2d_target_create_hwnd(void *hwnd, MpvfxPixelSize size, float dpi, MpvfxD2DTarget **out) {
    const uint32_t width = size.width, height = size.height;
    *out = nullptr;
    Factories &f = factories();
    if (FAILED(f.status)) return f.status;
    auto *t = new MpvfxD2DTarget();
    const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), dpi, dpi);
    HRESULT hr = f.d2d->CreateHwndRenderTarget(
        props, D2D1::HwndRenderTargetProperties(static_cast<HWND>(hwnd), D2D1::SizeU(width, height)), t->hwnd.put());
    if (SUCCEEDED(hr)) {
        t->hwnd->QueryInterface(__uuidof(ID2D1RenderTarget), t->rt.putVoid());
        t->width = width; t->height = height;
        hr = t->finish();
    }
    if (FAILED(hr)) { delete t; return hr; }
    *out = t;
    return S_OK;
}

mpvfx_hresult mpvfx_d2d_target_create_bitmap(uint32_t width, uint32_t height, MpvfxD2DTarget **out) {
    *out = nullptr;
    Factories &f = factories();
    if (FAILED(f.status)) return f.status;
    if (width == 0 || height == 0) return E_INVALIDARG;
    auto *t = new MpvfxD2DTarget();
    HRESULT hr = f.wic->CreateBitmap(width, height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, t->bitmap.put());
    if (SUCCEEDED(hr)) {
        // Software: the pixels are read back on the CPU (tests, export text, snapshots).
        const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_SOFTWARE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            96.0f, 96.0f);
        hr = f.d2d->CreateWicBitmapRenderTarget(t->bitmap.get(), props, t->rt.put());
    }
    if (SUCCEEDED(hr)) {
        t->width = width; t->height = height;
        // Transparent background: ClearType would tint glyph edges with the colour of a background it cannot see.
        t->rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        hr = t->finish();
    }
    if (SUCCEEDED(hr)) {
        t->rt->BeginDraw();
        t->rt->Clear(color(0, 0, 0, 0));
        hr = t->rt->EndDraw();
    }
    if (FAILED(hr)) { delete t; return hr; }
    *out = t;
    return S_OK;
}

void mpvfx_d2d_target_release(MpvfxD2DTarget *t) { delete t; }

mpvfx_hresult mpvfx_d2d_target_resize(MpvfxD2DTarget *t, uint32_t width, uint32_t height) {
    if (!t->hwnd) return E_NOTIMPL;
    HRESULT hr = t->hwnd->Resize(D2D1::SizeU(width, height));
    if (SUCCEEDED(hr)) { t->width = width; t->height = height; }
    return hr;
}

void mpvfx_d2d_target_set_dpi(MpvfxD2DTarget *t, float dpi) { t->rt->SetDpi(dpi, dpi); }

void mpvfx_d2d_begin_draw(MpvfxD2DTarget *t) { t->rt->BeginDraw(); }

mpvfx_hresult mpvfx_d2d_end_draw(MpvfxD2DTarget *t) {
    while (!t->layers.empty()) mpvfx_d2d_pop_clip(t);
    return t->rt->EndDraw();
}

void mpvfx_d2d_set_transform(MpvfxD2DTarget *t, const float m[6]) {
    const D2D1_MATRIX_3X2_F matrix = D2D1::Matrix3x2F(m[0], m[1], m[2], m[3], m[4], m[5]);
    t->rt->SetTransform(matrix);
}

void mpvfx_d2d_clear(MpvfxD2DTarget *t, MpvfxColor c) {
    t->rt->Clear(color(c.r, c.g, c.b, c.a));   // the colour API takes straight alpha
}

mpvfx_hresult mpvfx_d2d_fill_path(MpvfxD2DTarget *t, const MpvfxPath *path, MpvfxColor c) {
    Com<ID2D1PathGeometry> geo;
    HRESULT hr = geometry(*path, geo);
    if (FAILED(hr)) return hr;
    t->rt->FillGeometry(geo.get(), t->paint(c));
    return S_OK;
}

mpvfx_hresult mpvfx_d2d_stroke_path(MpvfxD2DTarget *t, const MpvfxPath *path, const MpvfxStroke *stroke, MpvfxColor c) {
    const float width = stroke->width;
    const float *dashes = stroke->dashes;
    const int32_t ndashes = stroke->dash_count;
    Com<ID2D1PathGeometry> geo;
    HRESULT hr = geometry(*path, geo);
    if (FAILED(hr)) return hr;
    Com<ID2D1StrokeStyle> style;
    if (ndashes > 0 && width > 0) {
        // Direct2D dash lengths are multiples of the stroke width; an odd list repeats once (canvas setLineDash).
        std::vector<float> scaled;
        const int32_t n = (ndashes % 2 == 1) ? ndashes * 2 : ndashes;
        for (int32_t i = 0; i < n; ++i) scaled.push_back(std::max(dashes[i % ndashes], 0.0f) / width);
        const D2D1_STROKE_STYLE_PROPERTIES props = D2D1::StrokeStyleProperties(
            D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_LINE_JOIN_MITER, 10.0f,
            D2D1_DASH_STYLE_CUSTOM, 0.0f);
        hr = factories().d2d->CreateStrokeStyle(props, scaled.data(), static_cast<UINT32>(scaled.size()), style.put());
        if (FAILED(hr)) return hr;
    }
    t->rt->DrawGeometry(geo.get(), t->paint(c), width, style.get());
    return S_OK;
}

mpvfx_hresult mpvfx_d2d_push_clip(MpvfxD2DTarget *t, const MpvfxPath *path) {
    Com<ID2D1PathGeometry> geo;
    HRESULT hr = geometry(*path, geo);
    if (FAILED(hr)) return hr;
    Com<ID2D1Layer> layer;
    hr = t->rt->CreateLayer(nullptr, layer.put());
    if (FAILED(hr)) return hr;
    // The mask is in user space: the current transform applies to it as to the drawing.
    D2D1_MATRIX_3X2_F current;
    t->rt->GetTransform(&current);
    t->rt->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(), geo.get(), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, current),
                     layer.get());
    t->layers.push_back(std::move(layer));
    return S_OK;
}

void mpvfx_d2d_pop_clip(MpvfxD2DTarget *t) {
    if (t->layers.empty()) return;
    t->rt->PopLayer();
    t->layers.pop_back();
}

mpvfx_hresult mpvfx_d2d_draw_text(MpvfxD2DTarget *t, const MpvfxText *text, MpvfxPoint origin, MpvfxColor c) {
    Com<IDWriteTextLayout> layout;
    HRESULT hr = makeLayout(*text, layout);
    if (FAILED(hr)) return hr;
    DWRITE_LINE_METRICS line = {};
    UINT32 lines = 0;
    hr = layout->GetLineMetrics(&line, 1, &lines);
    if (FAILED(hr) && hr != E_NOT_SUFFICIENT_BUFFER) return hr;
    // Placed as the Cairo backend places text (a line height of 1): the baseline sits 0.8 em below the em box top.
    const float top = origin.y + 0.8f * text->size - line.baseline;
    t->rt->DrawTextLayout(D2D1::Point2F(origin.x, top), layout.get(), t->paint(c), D2D1_DRAW_TEXT_OPTIONS_NONE);
    return S_OK;
}

mpvfx_hresult mpvfx_d2d_measure_text(const MpvfxText *text, float *width, float *height) {
    *width = 0; *height = 0;
    Com<IDWriteTextLayout> layout;
    HRESULT hr = makeLayout(*text, layout);
    if (FAILED(hr)) return hr;
    DWRITE_TEXT_METRICS m = {};
    hr = layout->GetMetrics(&m);
    if (FAILED(hr)) return hr;
    *width = m.widthIncludingTrailingWhitespace; *height = m.height;
    return S_OK;
}

struct MpvfxD2DBitmap {
    Com<ID2D1Bitmap> bitmap;
    Com<ID2D1RenderTarget> owner;   // the render target that made it (held, so its address stays unique)
    uint32_t width = 0, height = 0;
};

mpvfx_hresult mpvfx_d2d_bitmap_create(MpvfxD2DTarget *t, const MpvfxPixels *pixels, MpvfxD2DBitmap **out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    const HRESULT valid = checkBitmapInput(t, pixels);
    if (FAILED(valid)) return valid;
    const uint32_t width = pixels->width, height = pixels->height;
    const std::vector<uint8_t> bgra = premultipliedBGRA(*pixels);
    const D2D1_BITMAP_PROPERTIES props =
        D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
    Com<ID2D1Bitmap> bitmap;
    HRESULT hr = t->rt->CreateBitmap(D2D1::SizeU(width, height), bgra.data(), width * 4, props, bitmap.put());
    if (FAILED(hr)) return hr;
    auto *made = new (std::nothrow) MpvfxD2DBitmap();
    if (!made) return E_OUTOFMEMORY;
    made->bitmap = std::move(bitmap);
    t->rt->AddRef();
    made->owner.attach(t->rt.get());
    made->width = width; made->height = height;
    *out = made;
    return S_OK;
}

int32_t mpvfx_d2d_bitmap_belongs_to(const MpvfxD2DBitmap *b, const MpvfxD2DTarget *t) {
    return (b && t && t->rt && b->owner.get() == t->rt.get()) ? 1 : 0;
}

uint64_t mpvfx_d2d_bitmap_bytes(const MpvfxD2DBitmap *b) {
    return b ? static_cast<uint64_t>(b->width) * b->height * 4 : 0;
}

void mpvfx_d2d_bitmap_release(MpvfxD2DBitmap *b) { delete b; }

mpvfx_hresult mpvfx_d2d_draw_bitmap(MpvfxD2DTarget *t, const MpvfxD2DBitmap *b, MpvfxRect dst, float opacity) {
    if (!t || !b) return E_POINTER;
    if (!mpvfx_d2d_bitmap_belongs_to(b, t)) return E_INVALIDARG;
    const D2D1_RECT_F src = D2D1::RectF(0, 0, static_cast<float>(b->width), static_cast<float>(b->height));
    t->rt->DrawBitmap(b->bitmap.get(), D2D1::RectF(dst.x, dst.y, dst.x + dst.w, dst.y + dst.h), std::clamp(opacity, 0.0f, 1.0f),
                      D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, &src);
    return S_OK;
}

mpvfx_hresult mpvfx_d2d_read_rgba(MpvfxD2DTarget *t, uint8_t *out, uint32_t size) {
    if (!t->bitmap) return E_NOTIMPL;
    if (size < t->width * t->height * 4) return E_INVALIDARG;
    Com<IWICBitmapLock> lock;
    const WICRect rect = {0, 0, static_cast<INT>(t->width), static_cast<INT>(t->height)};
    HRESULT hr = t->bitmap->Lock(&rect, WICBitmapLockRead, lock.put());
    if (FAILED(hr)) return hr;
    UINT stride = 0, bytes = 0;
    BYTE *data = nullptr;
    hr = lock->GetStride(&stride);
    if (SUCCEEDED(hr)) hr = lock->GetDataPointer(&bytes, &data);
    if (FAILED(hr)) return hr;
    for (uint32_t row = 0; row < t->height; ++row) {
        const BYTE *src = data + static_cast<size_t>(row) * stride;
        uint8_t *dst = out + static_cast<size_t>(row) * t->width * 4;
        for (uint32_t col = 0; col < t->width; ++col) {
            const uint32_t b = src[col * 4], g = src[col * 4 + 1], r = src[col * 4 + 2], a = src[col * 4 + 3];
            auto un = [a](uint32_t c) { return static_cast<uint8_t>(a == 0 ? 0 : std::min<uint32_t>(255, (c * 255 + a / 2) / a)); };
            dst[col * 4] = un(r); dst[col * 4 + 1] = un(g); dst[col * 4 + 2] = un(b); dst[col * 4 + 3] = static_cast<uint8_t>(a);
        }
    }
    return S_OK;
}

mpvfx_hresult mpvfx_d2d_write_png(MpvfxD2DTarget *t, const uint16_t *path) {
    if (!t->bitmap) return E_NOTIMPL;
    Factories &f = factories();
    HRESULT hr = mpvfx::ensureCom();
    Com<IWICStream> stream;
    Com<IWICBitmapEncoder> encoder;
    Com<IWICBitmapFrameEncode> frame;
    if (SUCCEEDED(hr)) hr = f.wic->CreateStream(stream.put());
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(reinterpret_cast<const wchar_t *>(path), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = f.wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.put());
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(frame.put(), nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->SetSize(t->width, t->height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    // WriteSource converts the premultiplied bitmap to the frame's straight BGRA.
    if (SUCCEEDED(hr)) hr = frame->WriteSource(t->bitmap.get(), nullptr);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    return hr;
}

uint32_t mpvfx_d2d_target_width(MpvfxD2DTarget *t) { return t->width; }
uint32_t mpvfx_d2d_target_height(MpvfxD2DTarget *t) { return t->height; }

}  // extern "C"
#endif
