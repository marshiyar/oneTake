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
// One frame of compute-grade work for the Vulkan (CMpvfxVulkan) and Direct3D 11 (CMpvfxWin32) backends, as plain C:
// the same numbers MpvfxColor's `ColorGradeRenderer.gpuFrame` packs for Metal. Arrays are borrowed for the call.
#ifndef MPVFX_GPU_JOB_H
#define MPVFX_GPU_JOB_H
#include <stdint.h>

typedef struct MpvfxGpuGradeJob {
    int32_t width, height;
    /// GU_COUNT + EK_COUNT floats (layout: MpvfxColorShared.h).
    const float *uniforms;
    int32_t uniformCount;
    /// float4 texels: RGB curves (r, g, b, master), hue curves (hue, sat, luma, Luma/Sat), and Sat/Sat, 1024 each or none; five per enabled secondary.
    const float *curves, *hue, *secondaries, *saturation;
    int32_t curveTexels, hueTexels, secondaryTexels, saturationTexels;
    /// lutSize^3 float4 texels, red fastest; lutSize 0 = no LUT.
    const float *lut;
    int32_t lutSize;
    /// Multipass plan (0 iterations / 0 x 0 bloom / radius 0 = pass off).
    float blurRadius, blurAmount;
    int32_t blurIterations;
    int32_t bloomWidth, bloomHeight;
    float bloomRadius;
    int32_t kuwaharaRadius;
    float kuwaharaExponent, kuwaharaSaturation;
    /// Identifies the tables and LUT (the grade's signature): an equal key reuses the tables already on the device.
    const char *tableKey;
} MpvfxGpuGradeJob;

#endif
