//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
// Flat C interface over the Windows graphics, audio and shell COM APIs the app uses: Direct2D and DirectWrite
// (editor canvas, offscreen text and snapshots), WIC (offscreen bitmaps, PNG), WASAPI (audio output), the
// common item dialogs and shell services (theme setting, dark frame, clipboard, Explorer, dropped files), and the
// Direct3D 11 compute colour grade.
// DirectWrite and the item dialogs are C++-only COM interfaces, so the calls live in C++ (*.cpp beside include/)
// and Swift sees plain functions. Every function exists only in Windows builds; on Linux and macOS the
// sources compile to nothing and no Swift code calls them.
#ifndef MPVFX_WIN32_H
#define MPVFX_WIN32_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// HRESULT as a plain int32 (negative = failure).
typedef int32_t mpvfx_hresult;

// MARK: Direct2D canvas

/// A render target with its brush cache and clip-layer stack: a window (ID2D1HwndRenderTarget) or an offscreen
/// premultiplied BGRA bitmap (WIC bitmap render target).
typedef struct MpvfxD2DTarget MpvfxD2DTarget;

/// Path element kinds for the path arrays below: each kind consumes this many points (x, y float pairs):
/// move 1, line 1, cubic 3 (c1, c2, end), close 0.
enum { MPVFX_PATH_MOVE = 0, MPVFX_PATH_LINE = 1, MPVFX_PATH_CUBIC = 2, MPVFX_PATH_CLOSE = 3 };

/// Straight RGBA, each 0...1.
typedef struct MpvfxColor { float r, g, b, a; } MpvfxColor;
typedef struct MpvfxPoint { float x, y; } MpvfxPoint;
typedef struct MpvfxRect { float x, y, w, h; } MpvfxRect;
/// A size in device pixels.
typedef struct MpvfxPixelSize { uint32_t width, height; } MpvfxPixelSize;
/// `count` element kinds and the points they consume (see the kinds above).
typedef struct MpvfxPath { const uint8_t *kinds; int32_t count; const float *points; } MpvfxPath;
/// A stroke `width` wide; `dashes` (in user units, `dash_count` entries, may be 0) as on a CSS canvas.
typedef struct MpvfxStroke { float width; const float *dashes; int32_t dash_count; } MpvfxStroke;
/// UTF-16 `text` (`length` code units) in font `family` (UTF-16, NUL-terminated) at `size` DIPs, `weight`
/// 100...900, `italic` 0/1.
typedef struct MpvfxText {
    const uint16_t *text;
    int32_t length;
    const uint16_t *family;
    float size;
    int32_t weight;
    int32_t italic;
} MpvfxText;
/// Straight-alpha RGBA8 pixels, `width` x `height`, tightly packed.
typedef struct MpvfxPixels { const uint8_t *rgba; uint32_t width, height; } MpvfxPixels;

/// The process-wide factories (Direct2D multi-threaded, DirectWrite shared, WIC). S_OK once they exist.
mpvfx_hresult mpvfx_d2d_init(void);

/// Window target on `hwnd` (an HWND) of `size` device pixels at `dpi` (96 = 100%): drawing units are DIPs.
mpvfx_hresult mpvfx_d2d_target_create_hwnd(void *hwnd, MpvfxPixelSize size, float dpi, MpvfxD2DTarget **out);
/// Offscreen target: a `width` x `height` premultiplied BGRA bitmap, cleared to transparent, at 96 DPI.
mpvfx_hresult mpvfx_d2d_target_create_bitmap(uint32_t width, uint32_t height, MpvfxD2DTarget **out);
void mpvfx_d2d_target_release(MpvfxD2DTarget *t);
/// Window targets only: new client size in device pixels.
mpvfx_hresult mpvfx_d2d_target_resize(MpvfxD2DTarget *t, uint32_t width, uint32_t height);
/// Window targets only: new DPI (WM_DPICHANGED).
void mpvfx_d2d_target_set_dpi(MpvfxD2DTarget *t, float dpi);

void mpvfx_d2d_begin_draw(MpvfxD2DTarget *t);
/// Pops clip layers still pushed, then EndDraw. D2DERR_RECREATE_TARGET (0x8899000C) means the device was lost:
/// release the target and create a new one.
mpvfx_hresult mpvfx_d2d_end_draw(MpvfxD2DTarget *t);

/// Row-vector affine matrix (D2D1_MATRIX_3X2_F order: m11, m12, m21, m22, dx, dy).
void mpvfx_d2d_set_transform(MpvfxD2DTarget *t, const float m[6]);
/// Clears the target to `color`, ignoring the transform (clip layers still pushed limit it).
void mpvfx_d2d_clear(MpvfxD2DTarget *t, MpvfxColor color);

/// Fills the path (non-zero winding).
mpvfx_hresult mpvfx_d2d_fill_path(MpvfxD2DTarget *t, const MpvfxPath *path, MpvfxColor color);
mpvfx_hresult mpvfx_d2d_stroke_path(MpvfxD2DTarget *t, const MpvfxPath *path, const MpvfxStroke *stroke, MpvfxColor color);
/// Intersects the clip with the path (a layer with a geometric mask); undone by mpvfx_d2d_pop_clip.
mpvfx_hresult mpvfx_d2d_push_clip(MpvfxD2DTarget *t, const MpvfxPath *path);
void mpvfx_d2d_pop_clip(MpvfxD2DTarget *t);

/// Draws the text with the top of its em box at `origin` (placed as CSS does with a line height of 1: the baseline
/// at origin.y + 0.8 * size).
mpvfx_hresult mpvfx_d2d_draw_text(MpvfxD2DTarget *t, const MpvfxText *text, MpvfxPoint origin, MpvfxColor color);
/// Layout size of the text (advance width including trailing spaces, line height). Needs no target.
mpvfx_hresult mpvfx_d2d_measure_text(const MpvfxText *text, float *width, float *height);

/// The pixels as a premultiplied BGRA Direct2D bitmap of the render target that made it (a bitmap draws only on
/// that target). It keeps a reference to that target, so the target's address is never reused while it lives.
typedef struct MpvfxD2DBitmap MpvfxD2DBitmap;
/// Converts straight RGBA8 `pixels` to a bitmap of `t` once; draw it any number of times with mpvfx_d2d_draw_bitmap.
mpvfx_hresult mpvfx_d2d_bitmap_create(MpvfxD2DTarget *t, const MpvfxPixels *pixels, MpvfxD2DBitmap **out);
/// 1 when `b` was made by `t`'s current render target (so it can draw there), else 0.
int32_t mpvfx_d2d_bitmap_belongs_to(const MpvfxD2DBitmap *b, const MpvfxD2DTarget *t);
/// Bytes the bitmap's pixels take (width * height * 4).
uint64_t mpvfx_d2d_bitmap_bytes(const MpvfxD2DBitmap *b);
void mpvfx_d2d_bitmap_release(MpvfxD2DBitmap *b);
/// Draws the bitmap into the destination rectangle at `opacity`, linearly filtered. E_INVALIDARG when `b` belongs
/// to another target.
mpvfx_hresult mpvfx_d2d_draw_bitmap(MpvfxD2DTarget *t, const MpvfxD2DBitmap *b, MpvfxRect destination, float opacity);

/// Offscreen targets only: the bitmap as straight-alpha RGBA8 into `out` (width * height * 4 bytes).
mpvfx_hresult mpvfx_d2d_read_rgba(MpvfxD2DTarget *t, uint8_t *out, uint32_t size);
/// Offscreen targets only: the bitmap as a PNG file at `path` (UTF-16, NUL-terminated).
mpvfx_hresult mpvfx_d2d_write_png(MpvfxD2DTarget *t, const uint16_t *path);
uint32_t mpvfx_d2d_target_width(MpvfxD2DTarget *t);
uint32_t mpvfx_d2d_target_height(MpvfxD2DTarget *t);

// MARK: WASAPI shared-mode output

typedef struct MpvfxWasapi MpvfxWasapi;

/// Opens the default render endpoint in shared mode for interleaved float32 at `sample_rate` x `channels`
/// (the engine converts to the mix format), with a device buffer of about `buffer_ms` milliseconds.
/// Not started. Fails with the HRESULT when no endpoint exists (E_NOTFOUND on a machine without audio).
mpvfx_hresult mpvfx_wasapi_open(uint32_t sample_rate, uint32_t channels, uint32_t buffer_ms, MpvfxWasapi **out);
/// The same on the active render endpoint whose id (IMMDevice::GetId, UTF-16, NUL-terminated) is `device_id`; NULL
/// opens the default endpoint. Fails with the HRESULT when that endpoint is gone (E_NOTFOUND, or not active).
mpvfx_hresult mpvfx_wasapi_open_device(const uint16_t *device_id, uint32_t sample_rate, uint32_t channels,
                                       uint32_t buffer_ms, MpvfxWasapi **out);
/// Called once per active render endpoint with its id and friendly name (UTF-16, valid during the call only).
typedef void (*mpvfx_audio_device_callback)(void *context, const uint16_t *id, const uint16_t *name);
/// Lists the active render endpoints in the system's order (Settings > Audio output).
mpvfx_hresult mpvfx_wasapi_devices(mpvfx_audio_device_callback cb, void *context);
mpvfx_hresult mpvfx_wasapi_start(MpvfxWasapi *w);
mpvfx_hresult mpvfx_wasapi_stop(MpvfxWasapi *w);
/// Stops, drops everything queued and resets the clock to 0 (IAudioClient::Reset); restarts when it was running.
mpvfx_hresult mpvfx_wasapi_flush(MpvfxWasapi *w);
/// Blocks until all `frames` interleaved frames are queued in the device buffer.
mpvfx_hresult mpvfx_wasapi_write(MpvfxWasapi *w, const float *samples, uint32_t frames);
/// Frames the device has played since open or the last flush (IAudioClock position scaled to the stream rate).
mpvfx_hresult mpvfx_wasapi_position(MpvfxWasapi *w, uint64_t *frames);
void mpvfx_wasapi_close(MpvfxWasapi *w);

// MARK: WASAPI shared-mode capture (microphone)

typedef struct MpvfxWasapiCapture MpvfxWasapiCapture;

/// Called once per active capture endpoint with its id and friendly name (UTF-16, valid during the call only) and
/// whether it is the default capture endpoint.
typedef void (*mpvfx_capture_device_callback)(void *context, const uint16_t *id, const uint16_t *name, int32_t is_default);
mpvfx_hresult mpvfx_wasapi_capture_devices(mpvfx_capture_device_callback cb, void *context);
/// Opens the capture endpoint `device_id` (NULL: the default one) in shared mode for interleaved float32 at
/// `sample_rate` x `channels` (the engine converts from the device's mix format). Not started. Fails with the HRESULT:
/// E_ACCESSDENIED when Windows blocks microphone access, E_NOTFOUND when the endpoint is gone or none exists.
mpvfx_hresult mpvfx_wasapi_capture_open(const uint16_t *device_id, uint32_t sample_rate, uint32_t channels, uint32_t buffer_ms,
                                        MpvfxWasapiCapture **out);
mpvfx_hresult mpvfx_wasapi_capture_start(MpvfxWasapiCapture *c);
mpvfx_hresult mpvfx_wasapi_capture_stop(MpvfxWasapiCapture *c);
/// Waits up to `timeout_ms` for audio and copies up to `max_frames` interleaved frames into `out`; `*got` is 0 when the
/// wait timed out. AUDCLNT_E_NOT_INITIALIZED means the capture was stopped.
mpvfx_hresult mpvfx_wasapi_capture_read(MpvfxWasapiCapture *c, float *out, uint32_t max_frames, uint32_t timeout_ms, uint32_t *got);
/// Packets the device flagged as a data discontinuity (audio lost between two packets).
mpvfx_hresult mpvfx_wasapi_capture_discontinuities(MpvfxWasapiCapture *c, uint64_t *count);
void mpvfx_wasapi_capture_close(MpvfxWasapiCapture *c);

// MARK: Speech recognition (SAPI 5, in-process, from a WAV file)

/// Whether an installed desktop speech recognizer handles `lcid` (a Windows locale id): an exact match, else the
/// same primary language. Only the registry of recognizer tokens is read; no recognizer is created.
mpvfx_hresult mpvfx_speech_recognizer_installed(uint32_t lcid, int32_t *installed);
/// Called once per installed recognizer language with its locale name (BCP 47, UTF-16, NUL-terminated; valid during the call).
typedef void (*mpvfx_speech_language_callback)(void *context, const uint16_t *locale_name);
mpvfx_hresult mpvfx_speech_languages(mpvfx_speech_language_callback cb, void *context);
/// The locale id of a BCP 47 name (UTF-16, NUL-terminated); fails when Windows does not know the name.
mpvfx_hresult mpvfx_speech_locale_lcid(const uint16_t *locale_name, uint32_t *lcid);
/// One recognised word: UTF-16 `text` (`length` code units), `start_100ns` from the start of the file and its length.
typedef void (*mpvfx_speech_word_callback)(void *context, const uint16_t *text, int32_t length, int64_t start_100ns,
                                           int64_t duration_100ns);
/// Polled between recognizer events; non-zero stops the recognition.
typedef int32_t (*mpvfx_speech_cancel_callback)(void *context);
/// Recognises the speech in the 16-bit mono WAV file at `path` (UTF-16, NUL-terminated) with the in-process
/// recognizer for `lcid`, reporting each word through `word`. `bytes_per_second` is the file's PCM rate (the phrase
/// position is in bytes). Returns S_OK at the end of the stream, E_ABORT when `cancelled` asked to stop, else the
/// failing HRESULT. Every COM object it makes is released before it returns.
mpvfx_hresult mpvfx_speech_recognize(const uint16_t *path, uint32_t lcid, uint32_t bytes_per_second,
                                     mpvfx_speech_word_callback word, void *word_context,
                                     mpvfx_speech_cancel_callback cancelled, void *cancel_context);
/// COM objects the speech functions hold right now (acquired minus released); 0 when none is running.
int64_t mpvfx_speech_live_objects(void);

// MARK: Shell dialogs (IFileOpenDialog / IFileSaveDialog)

/// Called once per chosen path (UTF-16, NUL-terminated) with `context`.
typedef void (*mpvfx_path_callback)(void *context, const uint16_t *path);

/// A dialog owned by `owner` (an HWND or NULL) with `title`. Open dialogs: folders when `folders`, several items
/// when `multiple`. Save dialogs: `default_name` pre-filled, `filter_spec` a ";"-joined list of patterns
/// ("*.mp4;*.mov") named `filter_name`, or NULL, `button` the OK label or NULL. Strings are UTF-16, NUL-terminated.
typedef struct MpvfxDialog {
    void *owner;
    const uint16_t *title;
    int32_t folders, multiple;
    const uint16_t *default_name, *filter_name, *filter_spec, *button;
} MpvfxDialog;

/// S_OK with the paths reported through `cb`; S_FALSE when cancelled.
mpvfx_hresult mpvfx_dialog_open(const MpvfxDialog *dialog, mpvfx_path_callback cb, void *context);
/// S_OK with the one path through `cb`; S_FALSE when cancelled.
mpvfx_hresult mpvfx_dialog_save(const MpvfxDialog *dialog, mpvfx_path_callback cb, void *context);

// MARK: Shell services

/// 1 when Windows apps use the dark theme (HKCU ...\Themes\Personalize AppsUseLightTheme = 0), else 0.
int32_t mpvfx_system_prefers_dark(void);
/// 1 when a WM_SETTINGCHANGE setting name (its lParam, UTF-16) is the light/dark switch ("ImmersiveColorSet").
int32_t mpvfx_is_appearance_change(const uint16_t *setting);
/// Dark or light title bar and frame for `hwnd` (DWMWA_USE_IMMERSIVE_DARK_MODE).
mpvfx_hresult mpvfx_window_set_dark_frame(void *hwnd, int32_t dark);
/// Puts UTF-16, NUL-terminated `text` on the clipboard (CF_UNICODETEXT), owned by `hwnd`.
mpvfx_hresult mpvfx_clipboard_set_text(void *hwnd, const uint16_t *text);
/// Opens an Explorer window on the item's folder with the item selected.
mpvfx_hresult mpvfx_reveal_in_explorer(const uint16_t *path);
/// Opens a folder in Explorer, a file in its default app (ShellExecuteW "open").
mpvfx_hresult mpvfx_shell_open(const uint16_t *path);
/// Files dropped on a DragAcceptFiles window: the WM_DROPFILES handle's count, and each path through `cb`.
int32_t mpvfx_dropped_file_count(void *drop);
mpvfx_hresult mpvfx_dropped_file(void *drop, int32_t index, mpvfx_path_callback cb, void *context);

// MARK: Direct3D 11 compute grade

/// The grade's compute kernels (scripts/gpu/generated/grade.hlsl, compiled at run time by d3dcompiler_47.dll and
/// cached under %LOCALAPPDATA%\MpVFX\ShaderCache) on one Direct3D 11 device (feature level 11_0).
typedef struct MpvfxD3D11Grade MpvfxD3D11Grade;
/// The WARP software device instead of the hardware one (tests on machines without a GPU).
#define MPVFX_D3D11_WARP 1
/// NULL with the reason in `err` when there is no device, no compiler or the kernels do not build. Without
/// MPVFX_D3D11_WARP only a hardware adapter is used: software adapters (DXGI_ADAPTER_FLAG_SOFTWARE, or the Microsoft
/// Basic Render Driver, which GPU-less machines report as hardware) are refused.
MpvfxD3D11Grade *mpvfx_d3d11_grade_create(int32_t flags, char *err, int32_t errSize);
void mpvfx_d3d11_grade_destroy(MpvfxD3D11Grade *g);
/// The adapter's description, UTF-8.
const char *mpvfx_d3d11_grade_device_name(const MpvfxD3D11Grade *g);
/// 1 when the device runs on a software adapter (WARP).
int32_t mpvfx_d3d11_grade_device_is_software(const MpvfxD3D11Grade *g);
/// Grades `rgba` (job->width * job->height * 4 bytes, rows top first, straight alpha) in place. Thread-safe (frames
/// are serialised on the immediate context). 0, or a negative code with the reason in mpvfx_d3d11_grade_last_error;
/// the frame is then untouched.
/// `job` points at a MpvfxGpuGradeJob (CMpvfxColorShared/include/MpvfxGpuJob.h). It is untyped here so this header
/// names no other C module: Windows builds C++ with explicit clang modules and would need that module map.
int32_t mpvfx_d3d11_grade_render(MpvfxD3D11Grade *g, const void *job, uint8_t *rgba);
const char *mpvfx_d3d11_grade_last_error(const MpvfxD3D11Grade *g);
/// Frees the frame-size buffers and the cached tables (memory pressure); the next frame allocates them again.
void mpvfx_d3d11_grade_release_buffers(MpvfxD3D11Grade *g);

#ifdef __cplusplus
}
#endif

#endif
