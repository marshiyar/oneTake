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
// Vulkan device, buffers and pipelines of the compute grade (header: include/mpvfx_vulkan.h; frames: vk_render.c).
// The loader is opened with dlopen so the app has no link-time dependency on libvulkan.
#include "vk_internal.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mpvfx_grade_spirv.h"

void vkg_fail(MpvfxVk *vk, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(vk->err, sizeof vk->err, fmt, ap);
    va_end(ap);
}

static int loadLoader(MpvfxVk *vk) {
    vk->lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!vk->lib) vk->lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!vk->lib) { vkg_fail(vk, "no Vulkan loader (libvulkan.so.1)"); return -1; }
    vk->f.vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(vk->lib, "vkGetInstanceProcAddr");
    if (!vk->f.vkGetInstanceProcAddr) { vkg_fail(vk, "libvulkan has no vkGetInstanceProcAddr"); return -1; }
    vk->f.vkCreateInstance = (PFN_vkCreateInstance)vk->f.vkGetInstanceProcAddr(NULL, "vkCreateInstance");
    if (!vk->f.vkCreateInstance) { vkg_fail(vk, "no vkCreateInstance"); return -1; }
    return 0;
}

static int createInstance(MpvfxVk *vk) {
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "MpVFX";
    app.pEngineName = "MpvfxColor";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo ci = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pApplicationInfo = &app;
    VkResult r = vk->f.vkCreateInstance(&ci, NULL, &vk->inst);
    if (r != VK_SUCCESS) { vkg_fail(vk, "vkCreateInstance: %d", (int)r); return -1; }
#define LOAD_INSTANCE(fn) \
    vk->f.fn = (PFN_##fn)vk->f.vkGetInstanceProcAddr(vk->inst, #fn); \
    if (!vk->f.fn) { vkg_fail(vk, "missing %s", #fn); return -1; }
    VKG_INSTANCE_FNS(LOAD_INSTANCE)
#undef LOAD_INSTANCE
    return 0;
}

/// Preference: discrete, integrated, virtual, other, software (only when allowed); -1 = not usable.
static int deviceScore(VkPhysicalDeviceType type, int allowSoftware) {
    switch (type) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return 5;
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 4;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return 3;
    case VK_PHYSICAL_DEVICE_TYPE_CPU: return allowSoftware ? 1 : -1;
    default: return 2;
    }
}

/// The first queue family that runs compute, or -1.
static int computeFamily(MpvfxVk *vk, VkPhysicalDevice p) {
    uint32_t n = 0;
    vk->f.vkGetPhysicalDeviceQueueFamilyProperties(p, &n, NULL);
    VkQueueFamilyProperties fam[32];
    if (n > 32) n = 32;
    vk->f.vkGetPhysicalDeviceQueueFamilyProperties(p, &n, fam);
    for (uint32_t i = 0; i < n; i++) {
        if ((fam[i].queueFlags & VK_QUEUE_COMPUTE_BIT) && fam[i].queueCount > 0) return (int)i;
    }
    return -1;
}

static int pickDevice(MpvfxVk *vk, int allowSoftware) {
    uint32_t n = 0;
    VkPhysicalDevice devs[16];
    if (vk->f.vkEnumeratePhysicalDevices(vk->inst, &n, NULL) != VK_SUCCESS || n == 0) { vkg_fail(vk, "no Vulkan device"); return -1; }
    if (n > 16) n = 16;
    if (vk->f.vkEnumeratePhysicalDevices(vk->inst, &n, devs) < 0) { vkg_fail(vk, "vkEnumeratePhysicalDevices failed"); return -1; }
    int best = -1, bestScore = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties props;
        vk->f.vkGetPhysicalDeviceProperties(devs[i], &props);
        int score = deviceScore(props.deviceType, allowSoftware);
        if (score > bestScore && computeFamily(vk, devs[i]) >= 0) { best = (int)i; bestScore = score; }
    }
    if (best < 0) { vkg_fail(vk, allowSoftware ? "no Vulkan device with compute" : "no hardware Vulkan device with compute"); return -1; }
    VkPhysicalDeviceProperties props;
    vk->phys = devs[best];
    vk->f.vkGetPhysicalDeviceProperties(vk->phys, &props);
    snprintf(vk->name, sizeof vk->name, "%s", props.deviceName);
    vk->software = props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU;
    vk->family = (uint32_t)computeFamily(vk, vk->phys);
    vk->f.vkGetPhysicalDeviceMemoryProperties(vk->phys, &vk->memProps);
    return 0;
}

static int createDevice(MpvfxVk *vk) {
    float priority = 1.0f;
    VkDeviceQueueCreateInfo q = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    q.queueFamilyIndex = vk->family;
    q.queueCount = 1;
    q.pQueuePriorities = &priority;
    VkDeviceCreateInfo ci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    ci.queueCreateInfoCount = 1;
    ci.pQueueCreateInfos = &q;
    VkResult r = vk->f.vkCreateDevice(vk->phys, &ci, NULL, &vk->dev);
    if (r != VK_SUCCESS) { vkg_fail(vk, "vkCreateDevice: %d", (int)r); return -1; }
#define LOAD_DEVICE(fn) \
    vk->f.fn = (PFN_##fn)vk->f.vkGetDeviceProcAddr(vk->dev, #fn); \
    if (!vk->f.fn) { vkg_fail(vk, "missing %s", #fn); return -1; }
    VKG_DEVICE_FNS(LOAD_DEVICE)
#undef LOAD_DEVICE
    vk->f.vkGetDeviceQueue(vk->dev, vk->family, 0, &vk->queue);
    return 0;
}

// MARK: Buffers

static int memoryType(const MpvfxVk *vk, uint32_t bits, VkMemoryPropertyFlags need, VkMemoryPropertyFlags want) {
    int fallback = -1;
    for (uint32_t i = 0; i < vk->memProps.memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = vk->memProps.memoryTypes[i].propertyFlags;
        if (!(bits & (1u << i)) || (f & need) != need) continue;
        if ((f & want) == want) return (int)i;
        if (fallback < 0) fallback = (int)i;
    }
    return fallback;
}

int vkg_buffer(MpvfxVk *vk, VkgBuf *b, VkDeviceSize size, int kind) {
    static const VkBufferUsageFlags usage[] = {
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    };
    static const VkMemoryPropertyFlags need[] = {0, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                                 VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT};
    static const VkMemoryPropertyFlags want[] = {VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, VK_MEMORY_PROPERTY_HOST_CACHED_BIT};
    memset(b, 0, sizeof *b);
    VkBufferCreateInfo ci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    ci.size = size < 16 ? 16 : size;
    ci.usage = usage[kind];
    if (vk->f.vkCreateBuffer(vk->dev, &ci, NULL, &b->buf) != VK_SUCCESS) { vkg_fail(vk, "vkCreateBuffer (%llu bytes)", (unsigned long long)size); return -1; }
    VkMemoryRequirements req;
    vk->f.vkGetBufferMemoryRequirements(vk->dev, b->buf, &req);
    int type = memoryType(vk, req.memoryTypeBits, need[kind], want[kind]);
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = (uint32_t)type;
    if (type < 0 || vk->f.vkAllocateMemory(vk->dev, &ai, NULL, &b->mem) != VK_SUCCESS) {
        vkg_fail(vk, "device memory (%llu bytes) unavailable", (unsigned long long)req.size);
        return -1;
    }
    b->size = ci.size;
    b->bytes = (int64_t)req.size;
    if (vk->f.vkBindBufferMemory(vk->dev, b->buf, b->mem, 0) != VK_SUCCESS) { vkg_fail(vk, "vkBindBufferMemory"); return -1; }
    if (kind != VKG_DEVICE && vk->f.vkMapMemory(vk->dev, b->mem, 0, VK_WHOLE_SIZE, 0, &b->map) != VK_SUCCESS) {
        vkg_fail(vk, "vkMapMemory");
        return -1;
    }
    return 0;
}

void vkg_buffer_free(MpvfxVk *vk, VkgBuf *b) {
    if (b->buf) vk->f.vkDestroyBuffer(vk->dev, b->buf, NULL);
    if (b->mem) vk->f.vkFreeMemory(vk->dev, b->mem, NULL);
    memset(b, 0, sizeof *b);
}

// MARK: Pipelines

static int readFile(MpvfxVk *vk, const char *path, uint32_t **words, size_t *count) {
    FILE *f = fopen(path, "rb");
    if (!f) { vkg_fail(vk, "cannot open %s", path); return -1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    *words = n > 0 && n % 4 == 0 ? malloc((size_t)n) : NULL;
    size_t got = *words ? fread(*words, 1, (size_t)n, f) : 0;
    fclose(f);
    if (!*words || got != (size_t)n) { free(*words); *words = NULL; vkg_fail(vk, "bad SPIR-V file %s", path); return -1; }
    *count = (size_t)n / 4;
    return 0;
}

typedef struct { const uint32_t *words; size_t count; const char *name, *entry; } KernelCode;

static const KernelCode builtin[VKG_KERNELS] = {
    {mpvfx_spirv_glsl_blur, sizeof mpvfx_spirv_glsl_blur / 4, "blur", "main"},
    {mpvfx_spirv_glsl_moments, sizeof mpvfx_spirv_glsl_moments / 4, "moments", "main"},
    {mpvfx_spirv_glsl_resolve, sizeof mpvfx_spirv_glsl_resolve / 4, "resolve", "main"},
    {mpvfx_spirv_glsl_grade, sizeof mpvfx_spirv_glsl_grade / 4, "grade", "main"},
};
static const char *const hlslEntry[VKG_KERNELS] = {"mpvfx_blur_pass", "mpvfx_kuwahara_moments", "mpvfx_kuwahara_resolve", "mpvfx_grade"};

static int createPipeline(MpvfxVk *vk, int k, const uint32_t *words, size_t count) {
    VkShaderModuleCreateInfo mi = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    mi.codeSize = count * 4;
    mi.pCode = words;
    VkShaderModule module;
    if (vk->f.vkCreateShaderModule(vk->dev, &mi, NULL, &module) != VK_SUCCESS) { vkg_fail(vk, "shader module %s", builtin[k].name); return -1; }
    VkComputePipelineCreateInfo ci = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    ci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    ci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    ci.stage.module = module;
    ci.stage.pName = vk->spirvFromFiles ? hlslEntry[k] : builtin[k].entry;
    ci.layout = vk->layout;
    VkResult r = vk->f.vkCreateComputePipelines(vk->dev, VK_NULL_HANDLE, 1, &ci, NULL, &vk->pipes[k]);
    vk->f.vkDestroyShaderModule(vk->dev, module, NULL);
    if (r != VK_SUCCESS) { vkg_fail(vk, "compute pipeline %s: %d", builtin[k].name, (int)r); return -1; }
    return 0;
}

static int createLayouts(MpvfxVk *vk) {
    VkDescriptorSetLayoutBinding b[VKG_BINDINGS];
    for (int i = 0; i < VKG_BINDINGS; i++) {
        b[i] = (VkDescriptorSetLayoutBinding){(uint32_t)i, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL};
    }
    VkDescriptorSetLayoutCreateInfo li = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    li.bindingCount = VKG_BINDINGS;
    li.pBindings = b;
    if (vk->f.vkCreateDescriptorSetLayout(vk->dev, &li, NULL, &vk->setLayout) != VK_SUCCESS) { vkg_fail(vk, "descriptor set layout"); return -1; }
    VkPipelineLayoutCreateInfo pi = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pi.setLayoutCount = 1;
    pi.pSetLayouts = &vk->setLayout;
    if (vk->f.vkCreatePipelineLayout(vk->dev, &pi, NULL, &vk->layout) != VK_SUCCESS) { vkg_fail(vk, "pipeline layout"); return -1; }
    VkDescriptorPoolSize size = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, VKG_BINDINGS * VKG_MAX_PASSES};
    VkDescriptorPoolCreateInfo dp = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dp.maxSets = VKG_MAX_PASSES;
    dp.poolSizeCount = 1;
    dp.pPoolSizes = &size;
    if (vk->f.vkCreateDescriptorPool(vk->dev, &dp, NULL, &vk->descPool) != VK_SUCCESS) { vkg_fail(vk, "descriptor pool"); return -1; }
    VkDescriptorSetLayout layouts[VKG_MAX_PASSES];
    for (int i = 0; i < VKG_MAX_PASSES; i++) layouts[i] = vk->setLayout;
    VkDescriptorSetAllocateInfo ai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    ai.descriptorPool = vk->descPool;
    ai.descriptorSetCount = VKG_MAX_PASSES;
    ai.pSetLayouts = layouts;
    if (vk->f.vkAllocateDescriptorSets(vk->dev, &ai, vk->sets) != VK_SUCCESS) { vkg_fail(vk, "descriptor sets"); return -1; }
    return 0;
}

static int createPipelines(MpvfxVk *vk, const char *spirvDir) {
    for (int k = 0; k < VKG_KERNELS; k++) {
        if (!spirvDir) {
            if (createPipeline(vk, k, builtin[k].words, builtin[k].count) != 0) return -1;
            continue;
        }
        char path[1024];
        snprintf(path, sizeof path, "%s/hlsl_%s.spv", spirvDir, builtin[k].name);
        uint32_t *words = NULL;
        size_t count = 0;
        if (readFile(vk, path, &words, &count) != 0) return -1;
        int r = createPipeline(vk, k, words, count);
        free(words);
        if (r != 0) return -1;
    }
    return 0;
}

static int createCommands(MpvfxVk *vk) {
    VkCommandPoolCreateInfo pi = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pi.queueFamilyIndex = vk->family;
    if (vk->f.vkCreateCommandPool(vk->dev, &pi, NULL, &vk->cmdPool) != VK_SUCCESS) { vkg_fail(vk, "command pool"); return -1; }
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    ai.commandPool = vk->cmdPool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    if (vk->f.vkAllocateCommandBuffers(vk->dev, &ai, &vk->cmd) != VK_SUCCESS) { vkg_fail(vk, "command buffer"); return -1; }
    VkFenceCreateInfo fi = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if (vk->f.vkCreateFence(vk->dev, &fi, NULL, &vk->fence) != VK_SUCCESS) { vkg_fail(vk, "fence"); return -1; }
    if (vkg_buffer(vk, &vk->params, VKG_PARAM_BYTES, VKG_DEVICE) != 0) return -1;
    // k / 255 as the CPU reference computes it (IEEE single division).
    for (int k = 0; k < 256; k++) vk->paramData[k] = (float)k / 255.0f;
    if (vkg_buffer(vk, &vk->dummy, 256, VKG_DEVICE) != 0) return -1;
    return 0;
}

MpvfxVk *mpvfx_vk_create(int flags, const char *spirvDir, char *err, int32_t errSize) {
    MpvfxVk *vk = calloc(1, sizeof *vk);
    if (!vk) { if (err && errSize > 0) snprintf(err, (size_t)errSize, "out of memory"); return NULL; }
    pthread_mutex_init(&vk->lock, NULL);
    vk->spirvFromFiles = spirvDir != NULL;
    int ok = loadLoader(vk) == 0 && createInstance(vk) == 0 && pickDevice(vk, flags & MPVFX_VK_ALLOW_SOFTWARE) == 0 &&
             createDevice(vk) == 0 && createLayouts(vk) == 0 && createPipelines(vk, spirvDir) == 0 && createCommands(vk) == 0;
    if (!ok) {
        if (err && errSize > 0) snprintf(err, (size_t)errSize, "%s", vk->err);
        mpvfx_vk_destroy(vk);
        return NULL;
    }
    return vk;
}

void mpvfx_vk_destroy(MpvfxVk *vk) {
    if (!vk) return;
    if (vk->dev) {
        vk->f.vkDeviceWaitIdle(vk->dev);
        vkg_release_frame_buffers(vk);
        vkg_buffer_free(vk, &vk->params);
        vkg_buffer_free(vk, &vk->dummy);
        if (vk->fence) vk->f.vkDestroyFence(vk->dev, vk->fence, NULL);
        if (vk->cmdPool) vk->f.vkDestroyCommandPool(vk->dev, vk->cmdPool, NULL);
        for (int k = 0; k < VKG_KERNELS; k++) if (vk->pipes[k]) vk->f.vkDestroyPipeline(vk->dev, vk->pipes[k], NULL);
        if (vk->descPool) vk->f.vkDestroyDescriptorPool(vk->dev, vk->descPool, NULL);
        if (vk->layout) vk->f.vkDestroyPipelineLayout(vk->dev, vk->layout, NULL);
        if (vk->setLayout) vk->f.vkDestroyDescriptorSetLayout(vk->dev, vk->setLayout, NULL);
        vk->f.vkDestroyDevice(vk->dev, NULL);
    }
    if (vk->inst && vk->f.vkDestroyInstance) vk->f.vkDestroyInstance(vk->inst, NULL);
    if (vk->lib) dlclose(vk->lib);
    pthread_mutex_destroy(&vk->lock);
    free(vk);
}

const char *mpvfx_vk_device_name(const MpvfxVk *vk) { return vk->name; }
int mpvfx_vk_device_is_software(const MpvfxVk *vk) { return vk->software; }
const char *mpvfx_vk_last_error(const MpvfxVk *vk) { return vk->err; }
