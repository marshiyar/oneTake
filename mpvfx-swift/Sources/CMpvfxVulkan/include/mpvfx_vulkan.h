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
// The colour grade as Vulkan compute (Linux): the kernels of scripts/gpu/generated/grade_<kernel>.comp, built from the
// same shading body as the Metal kernels, run on the best Vulkan device. Flat C interface for MpvfxColor's
// VulkanColorRenderer. The loader (libvulkan.so.1) is opened at run time; no loader, no device or kernels that do not
// build make mpvfx_vk_create return NULL and the caller grades on the CPU.
#ifndef MPVFX_VULKAN_H
#define MPVFX_VULKAN_H
#include <stdint.h>
#include "CMpvfxColorShared.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MpvfxVk MpvfxVk;

/// Accept a software device (Mesa lavapipe): tests and MPVFX_GPU=software. Without it only hardware devices are used.
#define MPVFX_VK_ALLOW_SOFTWARE 1

/// The compute grade on the best device (discrete, then integrated, then virtual, then software when allowed).
/// `spirvDir`: NULL for the built-in kernels, or a folder holding hlsl_{blur,moments,resolve,grade}.spv (the tests run
/// the Direct3D 11 shader source through glslang this way). On failure returns NULL with the reason in `err`.
MpvfxVk *mpvfx_vk_create(int flags, const char *spirvDir, char *err, int32_t errSize);
void mpvfx_vk_destroy(MpvfxVk *vk);
/// The device's name ("llvmpipe (LLVM ...)", "NVIDIA GeForce ...").
const char *mpvfx_vk_device_name(const MpvfxVk *vk);
/// 1 when the device is a CPU implementation (lavapipe).
int mpvfx_vk_device_is_software(const MpvfxVk *vk);
/// Grades `rgba` (job->width * job->height * 4 bytes, rows top first, straight alpha) in place. Thread-safe (frames
/// are serialised on the device's queue). Returns 0, or a negative code with the reason in mpvfx_vk_last_error; the
/// frame is then untouched.
int mpvfx_vk_render(MpvfxVk *vk, const MpvfxGpuGradeJob *job, uint8_t *rgba);
/// The last failure's description (empty when none); valid until the next call on `vk`.
const char *mpvfx_vk_last_error(const MpvfxVk *vk);
/// Bytes of device memory held by size-dependent buffers (tests, diagnostics).
int64_t mpvfx_vk_resident_bytes(const MpvfxVk *vk);
/// Frees the frame-size buffers and the cached tables (memory pressure); the next frame allocates them again.
void mpvfx_vk_release_buffers(MpvfxVk *vk);

#ifdef __cplusplus
}
#endif
#endif
