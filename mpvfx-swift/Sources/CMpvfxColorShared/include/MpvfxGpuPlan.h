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
// The multipass plan of the compute grade, shared by the Vulkan (CMpvfxVulkan) and Direct3D 11 (CMpvfxWin32) hosts so
// both run the same dispatches in the same order on buffers of the same sizes: blur iterations (horizontal then
// vertical, at full size), bloom (thresholded horizontal pass from the source to the bloom size, then vertical), the
// Kuwahara moments and resolve, then the grade. Passes name buffers by role (MpvfxGpuBuffer); each host maps the roles
// to its own buffers. Every pass carries its parameters by value, so a pass can be copied freely. Plain C, header
// only, C++-compatible; the Swift tests call it too (GPUPlanTests).
#ifndef MPVFX_GPU_PLAN_H
#define MPVFX_GPU_PLAN_H
#include <stdint.h>
#include <string.h>

#include "../../MpvfxMetal/Shaders/MpvfxColorShared.h"
#include "MpvfxGpuJob.h"

/// Kernels in the order of the generated sources' entry points.
enum MpvfxGpuKernel { MPVFX_GPU_K_BLUR = 0, MPVFX_GPU_K_MOMENTS, MPVFX_GPU_K_RESOLVE, MPVFX_GPU_K_GRADE, MPVFX_GPU_KERNELS };
/// Buffer roles: packed RGBA8 (one uint per texel) except the moments (float4 per texel).
enum MpvfxGpuBuffer {
    MPVFX_GPU_B_NONE = 0, MPVFX_GPU_B_SRC, MPVFX_GPU_B_OUT, MPVFX_GPU_B_BLUR_A, MPVFX_GPU_B_BLUR_B, MPVFX_GPU_B_BLOOM_A,
    MPVFX_GPU_B_BLOOM_B, MPVFX_GPU_B_MOMENTS, MPVFX_GPU_B_KUWAHARA, MPVFX_GPU_BUFFERS
};
/// Dispatches per frame at most: 3 blur iterations x 2, bloom x 2, Kuwahara x 2, the grade.
#define MPVFX_GPU_MAX_PASSES 12
#define MPVFX_GPU_MAX_BLUR_ITERATIONS 3
/// The kernels' threadgroup ([numthreads(16, 8, 1)] / local_size 16 x 8).
#define MPVFX_GPU_GROUP_X 16u
#define MPVFX_GPU_GROUP_Y 8u
/// DXGI_ADAPTER_FLAG_SOFTWARE, and the PCI ids of the Microsoft Basic Render Driver / WARP adapter.
#define MPVFX_DXGI_ADAPTER_FLAG_SOFTWARE 2u
#define MPVFX_MICROSOFT_VENDOR_ID 0x1414u
#define MPVFX_BASIC_RENDER_DEVICE_ID 0x8cu

typedef struct MpvfxGpuPass {
    int32_t kernel;
    /// Input slots 0..3 (pictures), the moments input, the packed output and the moments output (MpvfxGpuBuffer).
    int32_t in[4], momIn, outPx, outMom;
    /// hdr: output size, then the sizes of slots 0..3 and of the moments (slot 4); 1 x 1 for an unbound slot.
    float hdr[12];
    /// The pass's own parameters (blur, moments, resolve); the grade pass reads the job's uniforms instead.
    float params[8];
    int32_t paramCount, usesJobUniforms;
    /// Threadgroups to dispatch: the output size rounded up to whole groups.
    uint32_t groupsX, groupsY;
} MpvfxGpuPass;

/// Threadgroups covering `n` threads in groups of `group` (0 for n <= 0).
static inline uint32_t mpvfx_gpu_groups(int32_t n, uint32_t group) {
    return n <= 0 ? 0u : ((uint32_t)n + group - 1u) / group;
}

/// Texels the buffer `role` holds for `j` (0 when the job does not use it): the bloom pair at the bloom size, every
/// other buffer at the frame size.
static inline uint64_t mpvfx_gpu_buffer_texels(const MpvfxGpuGradeJob *j, int32_t role) {
    uint64_t frame = (uint64_t)(j->width > 0 ? j->width : 0) * (uint64_t)(j->height > 0 ? j->height : 0);
    int bloom = j->bloomWidth > 0 && j->bloomHeight > 0;
    switch (role) {
    case MPVFX_GPU_B_SRC: case MPVFX_GPU_B_OUT: return frame;
    case MPVFX_GPU_B_BLUR_A: case MPVFX_GPU_B_BLUR_B: return j->blurIterations > 0 ? frame : 0;
    case MPVFX_GPU_B_BLOOM_A: case MPVFX_GPU_B_BLOOM_B: return bloom ? (uint64_t)j->bloomWidth * (uint64_t)j->bloomHeight : 0;
    case MPVFX_GPU_B_MOMENTS: case MPVFX_GPU_B_KUWAHARA: return j->kuwaharaRadius > 0 ? frame : 0;
    default: return 0;
    }
}

/// Bytes per texel of the buffer `role`: 16 for the moments (float4), 4 for packed RGBA8.
static inline uint32_t mpvfx_gpu_buffer_stride(int32_t role) { return role == MPVFX_GPU_B_MOMENTS ? 16u : 4u; }

/// A pass of `kernel` writing a `w` x `h` output, nothing bound yet.
static inline MpvfxGpuPass mpvfx_gpu_pass(int32_t kernel, int32_t w, int32_t h) {
    MpvfxGpuPass p;
    memset(&p, 0, sizeof p);
    p.kernel = kernel;
    for (int i = 0; i < 12; i++) p.hdr[i] = 1;
    p.hdr[0] = (float)w;
    p.hdr[1] = (float)h;
    p.groupsX = mpvfx_gpu_groups(w, MPVFX_GPU_GROUP_X);
    p.groupsY = mpvfx_gpu_groups(h, MPVFX_GPU_GROUP_Y);
    return p;
}

/// Binds buffer `role` of size `w` x `h` to input slot `s` (0..3 pictures, 4 the moments).
static inline void mpvfx_gpu_slot(MpvfxGpuPass *p, int s, int32_t role, const int32_t wh[2]) {
    if (s < 4) p->in[s] = role; else p->momIn = role;
    p->hdr[2 + 2 * s] = (float)wh[0];
    p->hdr[3 + 2 * s] = (float)wh[1];
}

/// One blur or bloom pass: `io` = {input role, output role}; `dims` = input w, h, output w, h; `flags` = bloom pass
/// 0/1, threshold (< 0: none), source image-oriented 0/1; `dirRadius` = direction x, y and the radius.
static inline MpvfxGpuPass mpvfx_gpu_blur_pass(const int32_t io[2], const int32_t dims[4], const float flags[3], const float dirRadius[3]) {
    MpvfxGpuPass p = mpvfx_gpu_pass(MPVFX_GPU_K_BLUR, dims[2], dims[3]);
    mpvfx_gpu_slot(&p, 0, io[0], dims);
    p.outPx = io[1];
    p.params[BLUR_DIR_X] = dirRadius[0];
    p.params[BLUR_DIR_Y] = dirRadius[1];
    p.params[BLUR_RADIUS] = dirRadius[2];
    p.params[BLUR_BLOOM_PASS] = flags[0];
    p.params[BLUR_THRESHOLD] = flags[1];
    p.params[BLUR_SOURCE_FLIPPED] = flags[2];
    p.paramCount = BLUR_PARAM_COUNT;
    return p;
}

/// The blur iterations (ping-pong through blur A and B; the result ends in B), then the bloom pair; returns the count.
static inline int mpvfx_gpu_plan_blur(const MpvfxGpuGradeJob *j, MpvfxGpuPass *p) {
    int n = 0;
    const int32_t full[4] = {j->width, j->height, j->width, j->height};
    for (int i = 0; i < j->blurIterations && i < MPVFX_GPU_MAX_BLUR_ITERATIONS; i++) {
        const int32_t across[2] = {i == 0 ? MPVFX_GPU_B_SRC : MPVFX_GPU_B_BLUR_B, MPVFX_GPU_B_BLUR_A};
        const int32_t down[2] = {MPVFX_GPU_B_BLUR_A, MPVFX_GPU_B_BLUR_B};
        const float first[3] = {0, -1, i == 0 ? 1.0f : 0.0f}, second[3] = {0, -1, 0};
        const float h[3] = {1, 0, j->blurRadius}, v[3] = {0, 1, j->blurRadius};
        p[n++] = mpvfx_gpu_blur_pass(across, full, first, h);
        p[n++] = mpvfx_gpu_blur_pass(down, full, second, v);
    }
    if (j->bloomWidth > 0 && j->bloomHeight > 0) {
        const int32_t across[2] = {MPVFX_GPU_B_SRC, MPVFX_GPU_B_BLOOM_A}, down[2] = {MPVFX_GPU_B_BLOOM_A, MPVFX_GPU_B_BLOOM_B};
        const int32_t first[4] = {j->width, j->height, j->bloomWidth, j->bloomHeight};
        const int32_t second[4] = {j->bloomWidth, j->bloomHeight, j->bloomWidth, j->bloomHeight};
        const float thresholded[3] = {1, 0.5f, 1}, plain[3] = {1, -1, 0};
        const float h[3] = {1, 0, j->bloomRadius}, v[3] = {0, 1, j->bloomRadius};
        p[n++] = mpvfx_gpu_blur_pass(across, first, thresholded, h);
        p[n++] = mpvfx_gpu_blur_pass(down, second, plain, v);
    }
    return n;
}

/// The Kuwahara moments (from the source, mixed with the blur when there is one) and resolve, after `n` passes.
static inline int mpvfx_gpu_plan_kuwahara(const MpvfxGpuGradeJob *j, MpvfxGpuPass *p, int n) {
    const int32_t full[2] = {j->width, j->height};
    if (j->kuwaharaRadius <= 0) return n;
    p[n] = mpvfx_gpu_pass(MPVFX_GPU_K_MOMENTS, j->width, j->height);
    mpvfx_gpu_slot(&p[n], 0, MPVFX_GPU_B_SRC, full);
    if (j->blurIterations > 0) mpvfx_gpu_slot(&p[n], 1, MPVFX_GPU_B_BLUR_B, full);
    p[n].outMom = MPVFX_GPU_B_MOMENTS;
    p[n].params[MOMENTS_RADIUS] = (float)j->kuwaharaRadius;
    p[n].params[MOMENTS_BLUR_AMOUNT] = j->blurIterations > 0 ? j->blurAmount : 0.0f;
    p[n++].paramCount = MOMENTS_PARAM_COUNT;
    p[n] = mpvfx_gpu_pass(MPVFX_GPU_K_RESOLVE, j->width, j->height);
    mpvfx_gpu_slot(&p[n], 4, MPVFX_GPU_B_MOMENTS, full);
    p[n].outPx = MPVFX_GPU_B_KUWAHARA;
    p[n].params[RESOLVE_RADIUS] = (float)j->kuwaharaRadius;
    p[n].params[RESOLVE_EXPONENT] = j->kuwaharaExponent;
    p[n].params[RESOLVE_SATURATION] = j->kuwaharaSaturation;
    p[n++].paramCount = RESOLVE_PARAM_COUNT;
    return n;
}

/// Every dispatch of the frame `j` into `p` (room for MPVFX_GPU_MAX_PASSES); returns the count. The grade is last.
static inline int mpvfx_gpu_plan(const MpvfxGpuGradeJob *j, MpvfxGpuPass *p) {
    const int32_t full[2] = {j->width, j->height}, bloom[2] = {j->bloomWidth, j->bloomHeight};
    int n = mpvfx_gpu_plan_kuwahara(j, p, mpvfx_gpu_plan_blur(j, p));
    p[n] = mpvfx_gpu_pass(MPVFX_GPU_K_GRADE, j->width, j->height);
    mpvfx_gpu_slot(&p[n], 0, MPVFX_GPU_B_SRC, full);
    if (j->blurIterations > 0) mpvfx_gpu_slot(&p[n], 1, MPVFX_GPU_B_BLUR_B, full);
    if (j->kuwaharaRadius > 0) mpvfx_gpu_slot(&p[n], 2, MPVFX_GPU_B_KUWAHARA, full);
    if (j->bloomWidth > 0 && j->bloomHeight > 0) mpvfx_gpu_slot(&p[n], 3, MPVFX_GPU_B_BLOOM_B, bloom);
    p[n].outPx = MPVFX_GPU_B_OUT;
    p[n].usesJobUniforms = 1;
    return n + 1;
}

/// The floats a pass's `u` buffer receives: the job's uniforms for the grade, else the pass's own parameters.
static inline const float *mpvfx_gpu_pass_uniforms(const MpvfxGpuPass *p, const MpvfxGpuGradeJob *j, int32_t *count) {
    *count = p->usesJobUniforms ? j->uniformCount : p->paramCount;
    return p->usesJobUniforms ? j->uniforms : p->params;
}

/// 1 when a DXGI adapter is a software rasteriser: DXGI_ADAPTER_FLAG_SOFTWARE, or the Microsoft Basic Render Driver
/// (vendor 0x1414, device 0x8c), which WARP and GPU-less machines (CI runners) report without that flag.
static inline int mpvfx_dxgi_adapter_is_software(uint32_t vendorId, uint32_t deviceId, uint32_t flags) {
    if (flags & MPVFX_DXGI_ADAPTER_FLAG_SOFTWARE) return 1;
    return vendorId == MPVFX_MICROSOFT_VENDOR_ID && deviceId == MPVFX_BASIC_RENDER_DEVICE_ID;
}

#endif
