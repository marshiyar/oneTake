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
// Shared state of the Vulkan compute grade (vk_device.c: device, buffers, pipelines; vk_render.c: frames).
#pragma once
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include <pthread.h>
#include <stdint.h>

#include "mpvfx_vulkan.h"

#define VKG_INSTANCE_FNS(X) \
    X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) X(vkCreateDevice) X(vkGetDeviceProcAddr)
#define VKG_DEVICE_FNS(X) \
    X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) \
    X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory) X(vkMapMemory) X(vkCreateShaderModule) \
    X(vkDestroyShaderModule) X(vkCreateDescriptorSetLayout) X(vkDestroyDescriptorSetLayout) X(vkCreatePipelineLayout) \
    X(vkDestroyPipelineLayout) X(vkCreateComputePipelines) X(vkDestroyPipeline) X(vkCreateDescriptorPool) \
    X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) X(vkCreateCommandPool) \
    X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkResetCommandBuffer) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) X(vkCmdDispatch) X(vkCmdPipelineBarrier) \
    X(vkCmdCopyBuffer) X(vkCmdUpdateBuffer) X(vkCreateFence) X(vkDestroyFence) X(vkResetFences) X(vkWaitForFences) X(vkQueueSubmit) \
    X(vkDeviceWaitIdle)

typedef struct {
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
    PFN_vkCreateInstance vkCreateInstance;
#define VKG_DECLARE(fn) PFN_##fn fn;
    VKG_INSTANCE_FNS(VKG_DECLARE)
    VKG_DEVICE_FNS(VKG_DECLARE)
#undef VKG_DECLARE
} VkgFns;

/// Buffer kinds: device-local storage, host-visible upload (staging, parameters), host-visible read-back.
enum { VKG_DEVICE = 0, VKG_UPLOAD = 1, VKG_DOWNLOAD = 2 };
/// Kernels in the plan's order (MpvfxGpuPlan.h).
enum { VKG_K_BLUR = MPVFX_GPU_K_BLUR, VKG_K_MOMENTS = MPVFX_GPU_K_MOMENTS, VKG_K_RESOLVE = MPVFX_GPU_K_RESOLVE,
       VKG_K_GRADE = MPVFX_GPU_K_GRADE, VKG_KERNELS = MPVFX_GPU_KERNELS };
/// Descriptor bindings (scripts/gpu/glsl.inc).
enum {
    VKG_B_HDR = 0, VKG_B_U, VKG_B_IN0, VKG_B_IN1, VKG_B_IN2, VKG_B_IN3, VKG_B_MOM_IN, VKG_B_CURVES, VKG_B_HUE, VKG_B_SEC,
    VKG_B_LUT, VKG_B_OUT_PX, VKG_B_OUT_MOM, VKG_B_UNORM, VKG_B_SATURATION, VKG_BINDINGS
};
/// Dispatches per frame (the plan's bound): 3 blur iterations x 2, bloom x 2, Kuwahara x 2, the grade.
#define VKG_MAX_PASSES MPVFX_GPU_MAX_PASSES
/// The device-local parameter buffer, refilled with vkCmdUpdateBuffer at the start of every frame: the 8-bit unorm
/// table (256 floats) at 0, then per dispatch hdr (sizes) at +0 and u (uniforms or pass parameters) at +256 from
/// VKG_CONST_BYTES + i * VKG_PARAM_STRIDE (every device's storage-buffer offset alignment divides 256).
#define VKG_CONST_BYTES 1024
#define VKG_PARAM_STRIDE 2048
#define VKG_HDR_BYTES 256
#define VKG_PARAM_BYTES (VKG_CONST_BYTES + VKG_PARAM_STRIDE * VKG_MAX_PASSES)

typedef struct {
    VkBuffer buf;
    VkDeviceMemory mem;
    VkDeviceSize size;
    int64_t bytes;
    void *map;
} VkgBuf;

/// Size-dependent buffers of one frame size; the pass buffers are allocated on first use.
typedef struct {
    int32_t width, height;
    VkgBuf upload, download, src, out;
    VkgBuf blurA, blurB, bloomA, bloomB, moments, kuwahara;
    int32_t bloomWidth, bloomHeight;
} VkgTargets;

/// The grade's tables on the device (staging copies kept to refill them).
typedef struct {
    char key[512];
    int valid;
    VkgBuf curves, hue, sec, lut, saturation, staging;
} VkgTables;

struct MpvfxVk {
    void *lib;
    VkgFns f;
    VkInstance inst;
    VkPhysicalDevice phys;
    VkDevice dev;
    VkQueue queue;
    uint32_t family;
    VkPhysicalDeviceMemoryProperties memProps;
    char name[256];
    int software, spirvFromFiles;
    VkDescriptorSetLayout setLayout;
    VkPipelineLayout layout;
    VkPipeline pipes[VKG_KERNELS];
    VkDescriptorPool descPool;
    VkDescriptorSet sets[VKG_MAX_PASSES];
    VkCommandPool cmdPool;
    VkCommandBuffer cmd;
    VkFence fence;
    VkgBuf params, dummy;
    /// What the next frame writes into `params` (unorm table, then the dispatches' hdr and u).
    float paramData[VKG_PARAM_BYTES / 4];
    VkgTargets targets;
    VkgTables tables;
    /// The job being recorded (table sizes for the copies).
    const MpvfxGpuGradeJob *current;
    pthread_mutex_t lock;
    char err[512];
};

void vkg_fail(MpvfxVk *vk, const char *fmt, ...);
int vkg_buffer(MpvfxVk *vk, VkgBuf *b, VkDeviceSize size, int kind);
void vkg_buffer_free(MpvfxVk *vk, VkgBuf *b);
/// Frees the per-size targets and the tables (vk_render.c).
void vkg_release_frame_buffers(MpvfxVk *vk);
