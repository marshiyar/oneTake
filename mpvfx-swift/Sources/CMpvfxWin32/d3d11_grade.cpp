// The colour grade as Direct3D 11 compute behind include/mpvfx_win32.h: the kernels of scripts/gpu/generated/grade.hlsl
// (generated from the Metal shading body, the same source the Vulkan build compiles) and the multipass plan of the Metal
// and Vulkan pipelines (blur iterations, bloom at half size, Kuwahara moments and resolve, then the grade), taken from
// MpvfxGpuPlan.h, the plan the Vulkan host runs too. Every texture is a structured buffer: RGBA8 pictures one uint per
// texel, the moments and tables float4 per texel. Without MPVFX_D3D11_WARP only a hardware adapter is used: a software
// one (DXGI_ADAPTER_FLAG_SOFTWARE, or the Microsoft Basic Render Driver a GPU-less machine reports as hardware) is
// skipped, because the CPU port is the better use of the same cores.
#ifdef _WIN32
#include "com.hpp"
#include "mpvfx_win32.h"
#include "CMpvfxColorShared.h"   // textual, via the header search path in Package.swift
#include "MpvfxGpuJob.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>

#include <cstdio>
#include <cstring>
#include <cwchar>
#include <initializer_list>
#include <mutex>
#include <string>
#include <vector>

#include "mpvfx_grade_hlsl.h"

using mpvfx::Com;

namespace {

const char *const kEntry[MPVFX_GPU_KERNELS] = {"mpvfx_blur_pass", "mpvfx_kuwahara_moments", "mpvfx_kuwahara_resolve",
                                               "mpvfx_grade"};

// Parameter buffer layout (floats): the unorm table (256), then per dispatch hdr (64) and u (448).
constexpr UINT kConstFloats = 256, kStrideFloats = 512, kHdrFloats = 64, kMaxPasses = MPVFX_GPU_MAX_PASSES;
constexpr UINT kParamFloats = kConstFloats + kStrideFloats * kMaxPasses;
// SRV registers (scripts/gpu/hlsl.inc): t0 hdr, t1 u, t2..t5 pictures, t6 moments, t7..t10 tables, t11 unorm table.
constexpr UINT kSrvSlots = 12;

/// A structured buffer with its views (any may be absent).
struct Buffer {
    Com<ID3D11Buffer> buf;
    Com<ID3D11ShaderResourceView> srv;
    Com<ID3D11UnorderedAccessView> uav;
    UINT count = 0;
};

uint64_t fnv1a(const void *data, size_t n, uint64_t h = 1469598103934665603ull) {
    const uint8_t *p = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

std::string utf8(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? static_cast<size_t>(n) : 1, '\0');
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    s.resize(strlen(s.c_str()));
    return s;
}

}  // namespace

struct MpvfxD3D11Grade {
    Com<ID3D11Device> device;
    Com<ID3D11DeviceContext> context;
    Com<ID3D11ComputeShader> shaders[MPVFX_GPU_KERNELS];
    Buffer params;
    Com<ID3D11ShaderResourceView> hdrViews[kMaxPasses], uViews[kMaxPasses], unormView;
    std::vector<float> paramData = std::vector<float>(kParamFloats, 0.0f);
    // Per frame size: the plan's buffers by role (MpvfxGpuBuffer; each reallocated when its texel count changes) and
    // the read-back of the output.
    Buffer bufs[MPVFX_GPU_BUFFERS];
    Com<ID3D11Buffer> readback;
    UINT readbackCount = 0;
    // Per grade.
    uint64_t tableKey = 0;
    bool tablesValid = false;
    Buffer curves, hue, sec, lut;
    std::string name;
    bool software = false;
    std::string err;
    std::mutex lock;

    int fail(const char *what, HRESULT hr) {
        char b[256];
        snprintf(b, sizeof b, "%s (0x%08lx)", what, static_cast<unsigned long>(hr));
        err = b;
        return -1;
    }
};

namespace {

// MARK: Buffers

/// `count` elements of `stride` bytes; `views`: 1 SRV, 2 UAV (bit mask); `data` optional initial contents.
struct BufferSpec {
    UINT stride, count;
    int views;
    const void *data;
};
constexpr int kSrv = 1, kSrvUav = 3;

HRESULT makeBuffer(MpvfxD3D11Grade *g, Buffer &b, const BufferSpec &spec) {
    const UINT stride = spec.stride, count = spec.count;
    const int views = spec.views;
    const void *data = spec.data;
    b = Buffer();
    D3D11_BUFFER_DESC d = {};
    d.ByteWidth = stride * (count > 0 ? count : 1);
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = ((views & 1) ? D3D11_BIND_SHADER_RESOURCE : 0) | ((views & 2) ? D3D11_BIND_UNORDERED_ACCESS : 0);
    d.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    d.StructureByteStride = stride;
    D3D11_SUBRESOURCE_DATA init = {data, 0, 0};
    HRESULT hr = g->device->CreateBuffer(&d, data ? &init : nullptr, b.buf.put());
    if (SUCCEEDED(hr) && (views & 1)) hr = g->device->CreateShaderResourceView(b.buf.get(), nullptr, b.srv.put());
    if (SUCCEEDED(hr) && (views & 2)) hr = g->device->CreateUnorderedAccessView(b.buf.get(), nullptr, b.uav.put());
    b.count = count;
    return hr;
}

HRESULT bufferView(MpvfxD3D11Grade *g, UINT first, UINT count, Com<ID3D11ShaderResourceView> &view) {
    D3D11_SHADER_RESOURCE_VIEW_DESC d = {};
    d.Format = DXGI_FORMAT_UNKNOWN;
    d.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
    d.Buffer.FirstElement = first;
    d.Buffer.NumElements = count;
    return g->device->CreateShaderResourceView(g->params.buf.get(), &d, view.put());
}

HRESULT makeParams(MpvfxD3D11Grade *g) {
    // k / 255 as the CPU reference computes it (IEEE single division).
    for (UINT k = 0; k < 256; k++) g->paramData[k] = static_cast<float>(k) / 255.0f;
    HRESULT hr = makeBuffer(g, g->params, {4, kParamFloats, kSrv, g->paramData.data()});
    if (SUCCEEDED(hr)) hr = bufferView(g, 0, kConstFloats, g->unormView);
    for (UINT i = 0; SUCCEEDED(hr) && i < kMaxPasses; i++) {
        UINT at = kConstFloats + i * kStrideFloats;
        hr = bufferView(g, at, kHdrFloats, g->hdrViews[i]);
        if (SUCCEEDED(hr)) hr = bufferView(g, at + kHdrFloats, kStrideFloats - kHdrFloats, g->uViews[i]);
    }
    return hr;
}

// MARK: Kernels

std::string shaderSource() {
    std::string s;
    for (const char *line : mpvfx_grade_hlsl_lines) s += line;
    return s;
}

/// %LOCALAPPDATA%\MpVFX\ShaderCache\<name>, created on demand; empty when there is no such folder.
std::wstring cachePath(const wchar_t *name) {
    wchar_t base[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return std::wstring();
    std::wstring dir = std::wstring(base) + L"\\MpVFX";
    CreateDirectoryW(dir.c_str(), nullptr);
    dir += L"\\ShaderCache";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\" + name;
}

bool readFile(const std::wstring &path, std::vector<uint8_t> &out) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size = {};
    DWORD got = 0;
    bool ok = GetFileSizeEx(f, &size) && size.QuadPart > 0 && size.QuadPart < (64 << 20);
    if (ok) {
        out.resize(static_cast<size_t>(size.QuadPart));
        ok = ReadFile(f, out.data(), static_cast<DWORD>(out.size()), &got, nullptr) && got == out.size();
    }
    CloseHandle(f);
    return ok;
}

void writeFileAtomically(const std::wstring &path, const void *data, size_t n) {
    std::wstring tmp = path + L".tmp";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD put = 0;
    bool ok = WriteFile(f, data, static_cast<DWORD>(n), &put, nullptr) && put == n;
    CloseHandle(f);
    if (!ok || !MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) DeleteFileW(tmp.c_str());
}

// IEEE strictness: no fused multiply-add and no float rewrites, the CPU reference's arithmetic.
constexpr UINT kCompileFlags = D3DCOMPILE_IEEE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;

/// The bytecode of `entry`: from the cache when the source and flags hash to a cached file, else compiled.
int compileKernel(MpvfxD3D11Grade *g, pD3DCompile compile, const std::string &source, int k) {
    uint64_t h = fnv1a(source.data(), source.size());
    h = fnv1a(kEntry[k], strlen(kEntry[k]), h);
    h = fnv1a(&kCompileFlags, sizeof kCompileFlags, h);
    wchar_t name[64];
    swprintf(name, 64, L"grade-%016llx.cso", static_cast<unsigned long long>(h));
    std::wstring path = cachePath(name);
    std::vector<uint8_t> code;
    if (path.empty() || !readFile(path, code)) {
        Com<ID3DBlob> blob, errors;
        HRESULT hr = compile(source.data(), source.size(), "grade.hlsl", nullptr, nullptr, kEntry[k], "cs_5_0", kCompileFlags, 0,
                             blob.put(), errors.put());
        if (FAILED(hr)) {
            g->err = std::string("D3DCompile ") + kEntry[k] + ": " +
                     (errors ? std::string(static_cast<const char *>(errors->GetBufferPointer()), errors->GetBufferSize()) : "failed");
            return -1;
        }
        const uint8_t *p = static_cast<const uint8_t *>(blob->GetBufferPointer());
        code.assign(p, p + blob->GetBufferSize());
        if (!path.empty()) writeFileAtomically(path, code.data(), code.size());
    }
    HRESULT hr = g->device->CreateComputeShader(code.data(), code.size(), nullptr, g->shaders[k].put());
    return FAILED(hr) ? g->fail(kEntry[k], hr) : 0;
}

int makeKernels(MpvfxD3D11Grade *g) {
    HMODULE dll = LoadLibraryW(L"d3dcompiler_47.dll");
    auto compile = dll ? reinterpret_cast<pD3DCompile>(reinterpret_cast<void *>(GetProcAddress(dll, "D3DCompile"))) : nullptr;
    if (!compile) { g->err = "d3dcompiler_47.dll (D3DCompile) is not available"; return -1; }
    std::string source = shaderSource();
    for (int k = 0; k < MPVFX_GPU_KERNELS; k++) {
        if (compileKernel(g, compile, source, k) != 0) return -1;
    }
    return 0;
}

// MARK: Device

bool adapterIsSoftware(const DXGI_ADAPTER_DESC1 &d) {
    return mpvfx_dxgi_adapter_is_software(d.VendorId, d.DeviceId, d.Flags) != 0;
}

/// The first hardware adapter in DXGI's order (the primary GPU first); software adapters are skipped. `seen` lists
/// every adapter for the error message.
HRESULT firstHardwareAdapter(Com<IDXGIAdapter1> &found, std::string &seen) {
    Com<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), factory.putVoid());
    if (FAILED(hr)) return hr;
    for (UINT i = 0;; i++) {
        Com<IDXGIAdapter1> a;
        if (FAILED(factory->EnumAdapters1(i, a.put()))) break;  // DXGI_ERROR_NOT_FOUND past the last one
        DXGI_ADAPTER_DESC1 d = {};
        if (!a || FAILED(a->GetDesc1(&d))) continue;
        bool soft = adapterIsSoftware(d);
        seen += (seen.empty() ? "" : ", ") + utf8(d.Description) + (soft ? " (software)" : "");
        if (!soft) { found = std::move(a); return S_OK; }
    }
    return DXGI_ERROR_NOT_FOUND;
}

HRESULT createDevice(MpvfxD3D11Grade *g, IDXGIAdapter *adapter, D3D_DRIVER_TYPE type) {
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDevice(adapter, type, nullptr, 0, levels, 2, D3D11_SDK_VERSION, g->device.put(), &got, g->context.put());
    if (hr == E_INVALIDARG) {  // Windows 7-era runtimes do not know 11_1
        hr = D3D11CreateDevice(adapter, type, nullptr, 0, levels + 1, 1, D3D11_SDK_VERSION, g->device.put(), &got, g->context.put());
    }
    return hr;
}

/// The name and software flag of the adapter the device runs on.
void describeDevice(MpvfxD3D11Grade *g, bool warp) {
    Com<IDXGIDevice> dxgi;
    Com<IDXGIAdapter> adapter;
    Com<IDXGIAdapter1> adapter1;
    DXGI_ADAPTER_DESC1 desc = {};
    g->software = warp;
    if (SUCCEEDED(g->device->QueryInterface(__uuidof(IDXGIDevice), dxgi.putVoid())) && SUCCEEDED(dxgi->GetAdapter(adapter.put())) &&
        SUCCEEDED(adapter->QueryInterface(__uuidof(IDXGIAdapter1), adapter1.putVoid())) && SUCCEEDED(adapter1->GetDesc1(&desc))) {
        g->name = utf8(desc.Description);
        g->software = warp || adapterIsSoftware(desc);
    }
    if (g->name.empty()) g->name = warp ? "Microsoft Basic Render Driver" : "Direct3D 11 device";
}

int makeDevice(MpvfxD3D11Grade *g, bool warp) {
    if (warp) {
        HRESULT hr = createDevice(g, nullptr, D3D_DRIVER_TYPE_WARP);
        if (FAILED(hr)) return g->fail("no WARP device", hr);
    } else {
        Com<IDXGIAdapter1> adapter;
        std::string seen;
        HRESULT hr = firstHardwareAdapter(adapter, seen);
        if (FAILED(hr)) {
            g->err = "no hardware Direct3D 11 adapter (adapters: " + (seen.empty() ? std::string("none") : seen) + ")";
            return -1;
        }
        hr = createDevice(g, adapter.get(), D3D_DRIVER_TYPE_UNKNOWN);
        if (FAILED(hr)) return g->fail("no Direct3D 11 hardware device", hr);
    }
    describeDevice(g, warp);
    if (g->software && !warp) {
        g->err = "the Direct3D 11 device " + g->name + " is a software adapter";
        return -1;
    }
    return 0;
}

// MARK: Frame buffers

/// Every buffer the plan of `j` uses, at its texel count (MpvfxGpuPlan.h): a buffer whose count differs (a new frame
/// or bloom size) is replaced, and the read-back follows the output.
int ensureTargets(MpvfxD3D11Grade *g, const MpvfxGpuGradeJob *j) {
    HRESULT hr = S_OK;
    for (int r = MPVFX_GPU_B_SRC; SUCCEEDED(hr) && r < MPVFX_GPU_BUFFERS; r++) {
        UINT texels = static_cast<UINT>(mpvfx_gpu_buffer_texels(j, r));
        if (texels == 0 || (g->bufs[r].buf && g->bufs[r].count == texels)) continue;
        hr = makeBuffer(g, g->bufs[r], {mpvfx_gpu_buffer_stride(r), texels, r == MPVFX_GPU_B_SRC ? kSrv : kSrvUav, nullptr});
        if (FAILED(hr)) g->bufs[r] = Buffer();
    }
    UINT px = static_cast<UINT>(mpvfx_gpu_buffer_texels(j, MPVFX_GPU_B_OUT));
    if (SUCCEEDED(hr) && (!g->readback || g->readbackCount != px)) {
        g->readbackCount = 0;
        D3D11_BUFFER_DESC d = {};
        d.ByteWidth = px * 4;
        d.Usage = D3D11_USAGE_STAGING;
        d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        d.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;  // CopyResource needs the source's layout
        d.StructureByteStride = 4;
        hr = g->device->CreateBuffer(&d, nullptr, g->readback.put());
        if (SUCCEEDED(hr)) g->readbackCount = px;
    }
    return FAILED(hr) ? g->fail("frame buffers", hr) : 0;
}

int ensureTables(MpvfxD3D11Grade *g, const MpvfxGpuGradeJob *j) {
    const char *key = j->tableKey ? j->tableKey : "";
    uint64_t h = fnv1a(key, strlen(key));
    if (g->tablesValid && g->tableKey == h) return 0;
    g->tablesValid = false;
    for (Buffer *b : {&g->curves, &g->hue, &g->sec, &g->lut}) *b = Buffer();
    UINT lutTexels = static_cast<UINT>(j->lutSize) * static_cast<UINT>(j->lutSize) * static_cast<UINT>(j->lutSize);
    HRESULT hr = S_OK;
    if (j->curveTexels > 0) hr = makeBuffer(g, g->curves, {16, static_cast<UINT>(j->curveTexels), kSrv, j->curves});
    if (SUCCEEDED(hr) && j->hueTexels > 0) hr = makeBuffer(g, g->hue, {16, static_cast<UINT>(j->hueTexels), kSrv, j->hue});
    if (SUCCEEDED(hr) && j->secondaryTexels > 0) hr = makeBuffer(g, g->sec, {16, static_cast<UINT>(j->secondaryTexels), kSrv, j->secondaries});
    if (SUCCEEDED(hr) && lutTexels > 0) hr = makeBuffer(g, g->lut, {16, lutTexels, kSrv, j->lut});
    if (FAILED(hr)) return g->fail("grade tables", hr);
    g->tableKey = h;
    g->tablesValid = true;
    return 0;
}

// MARK: Dispatch

ID3D11ShaderResourceView *srvOf(MpvfxD3D11Grade *g, int32_t role) {
    return role > MPVFX_GPU_B_NONE && role < MPVFX_GPU_BUFFERS ? g->bufs[role].srv.get() : nullptr;
}

ID3D11UnorderedAccessView *uavOf(MpvfxD3D11Grade *g, int32_t role) {
    return role > MPVFX_GPU_B_NONE && role < MPVFX_GPU_BUFFERS ? g->bufs[role].uav.get() : nullptr;
}

/// A pass that reads a buffer it also writes would have Direct3D silently unbind the SRV (reads return 0).
bool passAliases(const MpvfxGpuPass &p) {
    const int32_t reads[5] = {p.in[0], p.in[1], p.in[2], p.in[3], p.momIn};
    for (int32_t r : reads) {
        if (r != MPVFX_GPU_B_NONE && (r == p.outPx || r == p.outMom)) return true;
    }
    return false;
}

void dispatch(MpvfxD3D11Grade *g, const MpvfxGpuPass &p, int i) {
    ID3D11ShaderResourceView *srv[kSrvSlots] = {g->hdrViews[i].get(), g->uViews[i].get(), srvOf(g, p.in[0]), srvOf(g, p.in[1]),
                                                srvOf(g, p.in[2]), srvOf(g, p.in[3]), srvOf(g, p.momIn), g->curves.srv.get(),
                                                g->hue.srv.get(), g->sec.srv.get(), g->lut.srv.get(), g->unormView.get()};
    ID3D11UnorderedAccessView *uav[2] = {uavOf(g, p.outPx), uavOf(g, p.outMom)};
    g->context->CSSetShader(g->shaders[p.kernel].get(), nullptr, 0);
    g->context->CSSetShaderResources(0, kSrvSlots, srv);
    g->context->CSSetUnorderedAccessViews(0, 2, uav, nullptr);
    g->context->Dispatch(p.groupsX, p.groupsY, 1);
    // Unbind, so the next pass can read what this one wrote (D3D11 orders dispatches on one context and makes UAV
    // writes visible to later reads once the UAV is unbound).
    ID3D11ShaderResourceView *noSrv[kSrvSlots] = {};
    ID3D11UnorderedAccessView *noUav[2] = {};
    g->context->CSSetShaderResources(0, kSrvSlots, noSrv);
    g->context->CSSetUnorderedAccessViews(0, 2, noUav, nullptr);
}

/// Each pass's hdr and u into its stride of the parameter buffer; -1 when a pass would read what it writes.
int writeParams(MpvfxD3D11Grade *g, const MpvfxGpuGradeJob *j, const MpvfxGpuPass *passes, int n) {
    for (int i = 0; i < n; i++) {
        if (passAliases(passes[i])) { g->err = "a pass reads the buffer it writes"; return -1; }
        int32_t count = 0;
        const float *u = mpvfx_gpu_pass_uniforms(&passes[i], j, &count);
        float *at = g->paramData.data() + kConstFloats + i * kStrideFloats;
        memset(at, 0, kStrideFloats * sizeof(float));
        memcpy(at, passes[i].hdr, sizeof passes[i].hdr);
        memcpy(at + kHdrFloats, u, static_cast<size_t>(count) * sizeof(float));
    }
    return 0;
}

int renderLocked(MpvfxD3D11Grade *g, const MpvfxGpuGradeJob *j, uint8_t *rgba) {
    if (ensureTargets(g, j) != 0 || ensureTables(g, j) != 0) return -2;
    MpvfxGpuPass passes[kMaxPasses];
    int n = mpvfx_gpu_plan(j, passes);
    if (writeParams(g, j, passes, n) != 0) return -2;
    size_t bytes = static_cast<size_t>(j->width) * static_cast<size_t>(j->height) * 4;
    g->context->UpdateSubresource(g->bufs[MPVFX_GPU_B_SRC].buf.get(), 0, nullptr, rgba, 0, 0);
    g->context->UpdateSubresource(g->params.buf.get(), 0, nullptr, g->paramData.data(), 0, 0);
    for (int i = 0; i < n; i++) dispatch(g, passes[i], i);
    g->context->CopyResource(g->readback.get(), g->bufs[MPVFX_GPU_B_OUT].buf.get());
    D3D11_MAPPED_SUBRESOURCE m = {};
    HRESULT hr = g->context->Map(g->readback.get(), 0, D3D11_MAP_READ, 0, &m);
    if (FAILED(hr)) {
        HRESULT removed = g->device->GetDeviceRemovedReason();
        g->tablesValid = false;
        return g->fail(FAILED(removed) ? "device removed" : "read-back Map", FAILED(removed) ? removed : hr);
    }
    memcpy(rgba, m.pData, bytes);
    g->context->Unmap(g->readback.get(), 0);
    return 0;
}

}  // namespace

extern "C" MpvfxD3D11Grade *mpvfx_d3d11_grade_create(int32_t flags, char *err, int32_t errSize) {
    MpvfxD3D11Grade *g = new MpvfxD3D11Grade();
    int ok = makeDevice(g, (flags & MPVFX_D3D11_WARP) != 0) == 0 && makeKernels(g) == 0;
    if (ok) {
        HRESULT hr = makeParams(g);
        if (FAILED(hr)) ok = g->fail("parameter buffer", hr) == 0;
    }
    if (!ok) {
        if (err && errSize > 0) snprintf(err, static_cast<size_t>(errSize), "%s", g->err.c_str());
        delete g;
        return nullptr;
    }
    return g;
}

extern "C" void mpvfx_d3d11_grade_destroy(MpvfxD3D11Grade *g) { delete g; }

extern "C" void mpvfx_d3d11_grade_release_buffers(MpvfxD3D11Grade *g) {
    if (!g) return;
    std::lock_guard<std::mutex> hold(g->lock);
    for (Buffer &b : g->bufs) b = Buffer();
    for (Buffer *b : {&g->curves, &g->hue, &g->sec, &g->lut}) *b = Buffer();
    g->readback.reset();
    g->readbackCount = 0;
    g->tablesValid = false;
}

extern "C" const char *mpvfx_d3d11_grade_device_name(const MpvfxD3D11Grade *g) { return g->name.c_str(); }

extern "C" int32_t mpvfx_d3d11_grade_device_is_software(const MpvfxD3D11Grade *g) { return g->software ? 1 : 0; }

extern "C" const char *mpvfx_d3d11_grade_last_error(const MpvfxD3D11Grade *g) { return g->err.c_str(); }

extern "C" int32_t mpvfx_d3d11_grade_render(MpvfxD3D11Grade *g, const void *job, uint8_t *rgba) {
    const MpvfxGpuGradeJob *j = static_cast<const MpvfxGpuGradeJob *>(job);
    if (!g || !j || !rgba) return -1;
    std::lock_guard<std::mutex> hold(g->lock);
    g->err.clear();
    if (j->width <= 0 || j->height <= 0 || j->width > 16384 || j->height > 16384 || !j->uniforms ||
        j->uniformCount < 0 || j->uniformCount > static_cast<int32_t>(kStrideFloats - kHdrFloats) || j->lutSize < 0 || j->lutSize > 256) {
        g->err = "bad job";
        return -1;
    }
    return renderLocked(g, j, rgba);
}
#endif
