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
// One frame of the Vulkan compute grade: the multipass plan of the Metal pipeline (blur iterations, bloom at half size,
// Kuwahara moments and resolve, then the grade), recorded into one command buffer between an upload and a read-back.
#include "vk_internal.h"

#include <stdio.h>
#include <string.h>

static uint64_t fnv1a(const char *s) {
    uint64_t h = 1469598103934665603ull;
    for (; s && *s; s++) { h ^= (uint8_t)*s; h *= 1099511628211ull; }
    return h;
}

static void freeTargets(MpvfxVk *vk, VkgTargets *t) {
    VkgBuf *all[] = {&t->upload, &t->download, &t->src, &t->out, &t->blurA, &t->blurB, &t->bloomA, &t->bloomB, &t->moments, &t->kuwahara};
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) vkg_buffer_free(vk, all[i]);
    memset(t, 0, sizeof *t);
}

static void freeTables(MpvfxVk *vk, VkgTables *t) {
    vkg_buffer_free(vk, &t->curves);
    vkg_buffer_free(vk, &t->hue);
    vkg_buffer_free(vk, &t->saturation);
    vkg_buffer_free(vk, &t->sec);
    vkg_buffer_free(vk, &t->lut);
    vkg_buffer_free(vk, &t->staging);
    memset(t, 0, sizeof *t);
}

void vkg_release_frame_buffers(MpvfxVk *vk) {
    freeTargets(vk, &vk->targets);
    freeTables(vk, &vk->tables);
}

void mpvfx_vk_release_buffers(MpvfxVk *vk) {
    if (!vk) return;
    pthread_mutex_lock(&vk->lock);
    vkg_release_frame_buffers(vk);  // frames complete before render returns: nothing is in flight
    pthread_mutex_unlock(&vk->lock);
}

int64_t mpvfx_vk_resident_bytes(const MpvfxVk *vk) {
    const VkgTargets *t = &vk->targets;
    const VkgBuf *all[] = {&t->upload, &t->download, &t->src, &t->out, &t->blurA, &t->blurB, &t->bloomA, &t->bloomB, &t->moments, &t->kuwahara};
    int64_t n = 0;
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) n += all[i]->bytes;
    return n;
}

/// A new frame size replaces every size-dependent buffer: the upload, the read-back, the source and the output.
static int ensureFrame(MpvfxVk *vk, const MpvfxGpuGradeJob *j) {
    VkgTargets *t = &vk->targets;
    if (t->width == j->width && t->height == j->height) return 0;
    VkDeviceSize px = (VkDeviceSize)j->width * (VkDeviceSize)j->height;
    freeTargets(vk, t);
    t->width = j->width;
    t->height = j->height;
    if (vkg_buffer(vk, &t->upload, px * 4, VKG_UPLOAD) || vkg_buffer(vk, &t->download, px * 4, VKG_DOWNLOAD) ||
        vkg_buffer(vk, &t->src, px * 4, VKG_DEVICE) || vkg_buffer(vk, &t->out, px * 4, VKG_DEVICE)) { freeTargets(vk, t); return -1; }
    return 0;
}

/// Pass buffers on first use (blur, bloom at its own size, Kuwahara).
static int ensurePassBuffers(MpvfxVk *vk, const MpvfxGpuGradeJob *j) {
    VkgTargets *t = &vk->targets;
    VkDeviceSize px = (VkDeviceSize)j->width * (VkDeviceSize)j->height;
    if (j->blurIterations > 0 && !t->blurA.buf &&
        (vkg_buffer(vk, &t->blurA, px * 4, VKG_DEVICE) || vkg_buffer(vk, &t->blurB, px * 4, VKG_DEVICE))) return -1;
    if (j->bloomWidth > 0 && (t->bloomWidth != j->bloomWidth || t->bloomHeight != j->bloomHeight)) {
        vkg_buffer_free(vk, &t->bloomA);
        vkg_buffer_free(vk, &t->bloomB);
        t->bloomWidth = t->bloomHeight = 0;
        VkDeviceSize b = (VkDeviceSize)j->bloomWidth * (VkDeviceSize)j->bloomHeight * 4;
        if (vkg_buffer(vk, &t->bloomA, b, VKG_DEVICE) || vkg_buffer(vk, &t->bloomB, b, VKG_DEVICE)) return -1;
        t->bloomWidth = j->bloomWidth;
        t->bloomHeight = j->bloomHeight;
    }
    if (j->kuwaharaRadius > 0 && !t->moments.buf &&
        (vkg_buffer(vk, &t->moments, px * 16, VKG_DEVICE) || vkg_buffer(vk, &t->kuwahara, px * 4, VKG_DEVICE))) return -1;
    return 0;
}

static int ensureTargets(MpvfxVk *vk, const MpvfxGpuGradeJob *j) {
    if (ensureFrame(vk, j) != 0) return -1;
    if (ensurePassBuffers(vk, j) != 0) { freeTargets(vk, &vk->targets); return -1; }
    return 0;
}

/// Tables for a new key: device buffers plus one staging buffer holding curves, hue, secondaries and LUT back to back.
/// Returns 1 when the copies must be recorded this frame, 0 when the device already holds them, -1 on failure.
static int ensureTables(MpvfxVk *vk, const MpvfxGpuGradeJob *j) {
    VkgTables *t = &vk->tables;
    char key[64];
    snprintf(key, sizeof key, "%016llx", (unsigned long long)fnv1a(j->tableKey));
    if (t->valid && strcmp(t->key, key) == 0) return 0;
    freeTables(vk, t);
    VkDeviceSize c = (VkDeviceSize)j->curveTexels * 16, h = (VkDeviceSize)j->hueTexels * 16, s = (VkDeviceSize)j->secondaryTexels * 16;
    VkDeviceSize sat = (VkDeviceSize)j->saturationTexels * 16;
    VkDeviceSize l = (VkDeviceSize)j->lutSize * (VkDeviceSize)j->lutSize * (VkDeviceSize)j->lutSize * 16;
    if (vkg_buffer(vk, &t->curves, c, VKG_DEVICE) || vkg_buffer(vk, &t->hue, h, VKG_DEVICE) || vkg_buffer(vk, &t->sec, s, VKG_DEVICE) ||
        vkg_buffer(vk, &t->saturation, sat, VKG_DEVICE) || vkg_buffer(vk, &t->lut, l, VKG_DEVICE) || vkg_buffer(vk, &t->staging, c + h + s + l + sat, VKG_UPLOAD)) { freeTables(vk, t); return -1; }
    uint8_t *m = t->staging.map;
    if (c) memcpy(m, j->curves, (size_t)c);
    if (h) memcpy(m + c, j->hue, (size_t)h);
    if (s) memcpy(m + c + h, j->secondaries, (size_t)s);
    if (l) memcpy(m + c + h + s, j->lut, (size_t)l);
    if (sat) memcpy(m + c + h + s + l, j->saturation, (size_t)sat);
    snprintf(t->key, sizeof t->key, "%s", key);
    t->valid = 1;
    return 1;
}

static void recordTableCopies(MpvfxVk *vk, const MpvfxGpuGradeJob *j) {
    VkgTables *t = &vk->tables;
    VkDeviceSize sizes[5] = {(VkDeviceSize)j->curveTexels * 16, (VkDeviceSize)j->hueTexels * 16, (VkDeviceSize)j->secondaryTexels * 16,
                             (VkDeviceSize)j->lutSize * (VkDeviceSize)j->lutSize * (VkDeviceSize)j->lutSize * 16, (VkDeviceSize)j->saturationTexels * 16};
    VkBuffer dst[5] = {t->curves.buf, t->hue.buf, t->sec.buf, t->lut.buf, t->saturation.buf};
    VkDeviceSize at = 0;
    for (int i = 0; i < 5; i++) {
        if (sizes[i] == 0) continue;
        VkBufferCopy region = {at, 0, sizes[i]};
        vk->f.vkCmdCopyBuffer(vk->cmd, t->staging.buf, dst[i], 1, &region);
        at += sizes[i];
    }
}

// MARK: Plan (MpvfxGpuPlan.h, shared with the Direct3D 11 host)

/// The buffer a plan role names; unbound slots get the dummy buffer (Vulkan needs every binding written).
static VkBuffer roleBuffer(const MpvfxVk *vk, int32_t role) {
    const VkgTargets *t = &vk->targets;
    const VkgBuf *byRole[MPVFX_GPU_BUFFERS] = {&vk->dummy, &t->src, &t->out, &t->blurA, &t->blurB, &t->bloomA, &t->bloomB,
                                               &t->moments, &t->kuwahara};
    return role > 0 && role < MPVFX_GPU_BUFFERS && byRole[role]->buf ? byRole[role]->buf : vk->dummy.buf;
}

// MARK: Recording

static VkBuffer tableOr(const MpvfxVk *vk, const VkgBuf *b, int32_t texels) { return texels > 0 ? b->buf : vk->dummy.buf; }

static void writeSet(MpvfxVk *vk, int i, const MpvfxGpuPass *p, const MpvfxGpuGradeJob *j) {
    const VkgTables *t = &vk->tables;
    VkBuffer b[VKG_BINDINGS] = {vk->params.buf, vk->params.buf, roleBuffer(vk, p->in[0]), roleBuffer(vk, p->in[1]),
                                roleBuffer(vk, p->in[2]), roleBuffer(vk, p->in[3]), roleBuffer(vk, p->momIn),
                                tableOr(vk, &t->curves, j->curveTexels), tableOr(vk, &t->hue, j->hueTexels),
                                tableOr(vk, &t->sec, j->secondaryTexels), tableOr(vk, &t->lut, j->lutSize), roleBuffer(vk, p->outPx),
                                roleBuffer(vk, p->outMom), vk->params.buf, tableOr(vk, &t->saturation, j->saturationTexels)};
    VkDescriptorBufferInfo info[VKG_BINDINGS];
    VkWriteDescriptorSet w[VKG_BINDINGS];
    for (int k = 0; k < VKG_BINDINGS; k++) {
        info[k] = (VkDescriptorBufferInfo){b[k], 0, VK_WHOLE_SIZE};
        w[k] = (VkWriteDescriptorSet){VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        w[k].dstSet = vk->sets[i];
        w[k].dstBinding = (uint32_t)k;
        w[k].descriptorCount = 1;
        w[k].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        w[k].pBufferInfo = &info[k];
    }
    VkDeviceSize at = VKG_CONST_BYTES + (VkDeviceSize)i * VKG_PARAM_STRIDE;
    info[VKG_B_HDR] = (VkDescriptorBufferInfo){vk->params.buf, at, VKG_HDR_BYTES};
    info[VKG_B_U] = (VkDescriptorBufferInfo){vk->params.buf, at + VKG_HDR_BYTES, VKG_PARAM_STRIDE - VKG_HDR_BYTES};
    info[VKG_B_UNORM] = (VkDescriptorBufferInfo){vk->params.buf, 0, VKG_CONST_BYTES};
    vk->f.vkUpdateDescriptorSets(vk->dev, VKG_BINDINGS, w, 0, NULL);
    float *slotParams = vk->paramData + at / 4;
    memset(slotParams, 0, VKG_PARAM_STRIDE);
    memcpy(slotParams, p->hdr, sizeof p->hdr);
    int32_t uCount = 0;
    const float *u = mpvfx_gpu_pass_uniforms(p, j, &uCount);
    memcpy(slotParams + VKG_HDR_BYTES / 4, u, (size_t)uCount * 4);
}

enum { BARRIER_TRANSFER_COMPUTE, BARRIER_COMPUTE_COMPUTE, BARRIER_COMPUTE_TRANSFER, BARRIER_TRANSFER_HOST };

static void barrier(MpvfxVk *vk, int kind) {
    static const VkPipelineStageFlags srcStage[] = {VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                                    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT};
    static const VkPipelineStageFlags dstStage[] = {VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                                    VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT};
    static const VkAccessFlags srcAccess[] = {VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_HOST_WRITE_BIT, VK_ACCESS_SHADER_WRITE_BIT,
                                              VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT};
    static const VkAccessFlags dstAccess[] = {VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
                                              VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_HOST_READ_BIT};
    VkMemoryBarrier m = {VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    m.srcAccessMask = srcAccess[kind];
    m.dstAccessMask = dstAccess[kind];
    VkPipelineStageFlags src = kind == BARRIER_TRANSFER_COMPUTE ? (srcStage[kind] | VK_PIPELINE_STAGE_HOST_BIT) : srcStage[kind];
    vk->f.vkCmdPipelineBarrier(vk->cmd, src, dstStage[kind], 0, 1, &m, 0, NULL, 0, NULL);
}

static int record(MpvfxVk *vk, const MpvfxGpuPass *p, int n, int copyTables) {
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vk->f.vkResetCommandBuffer(vk->cmd, 0) != VK_SUCCESS || vk->f.vkBeginCommandBuffer(vk->cmd, &bi) != VK_SUCCESS) {
        vkg_fail(vk, "cannot begin the command buffer");
        return -1;
    }
    const VkgTargets *t = &vk->targets;
    VkBufferCopy whole = {0, 0, (VkDeviceSize)t->width * (VkDeviceSize)t->height * 4};
    vk->f.vkCmdCopyBuffer(vk->cmd, t->upload.buf, t->src.buf, 1, &whole);
    vk->f.vkCmdUpdateBuffer(vk->cmd, vk->params.buf, 0, VKG_CONST_BYTES + (VkDeviceSize)n * VKG_PARAM_STRIDE, vk->paramData);
    if (copyTables) recordTableCopies(vk, vk->current);
    barrier(vk, BARRIER_TRANSFER_COMPUTE);
    for (int i = 0; i < n; i++) {
        vk->f.vkCmdBindPipeline(vk->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, vk->pipes[p[i].kernel]);
        vk->f.vkCmdBindDescriptorSets(vk->cmd, VK_PIPELINE_BIND_POINT_COMPUTE, vk->layout, 0, 1, &vk->sets[i], 0, NULL);
        vk->f.vkCmdDispatch(vk->cmd, p[i].groupsX, p[i].groupsY, 1);
        barrier(vk, i + 1 < n ? BARRIER_COMPUTE_COMPUTE : BARRIER_COMPUTE_TRANSFER);
    }
    vk->f.vkCmdCopyBuffer(vk->cmd, t->out.buf, t->download.buf, 1, &whole);
    barrier(vk, BARRIER_TRANSFER_HOST);
    if (vk->f.vkEndCommandBuffer(vk->cmd) != VK_SUCCESS) { vkg_fail(vk, "cannot end the command buffer"); return -1; }
    return 0;
}

static int submitAndWait(MpvfxVk *vk) {
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1;
    si.pCommandBuffers = &vk->cmd;
    VkResult r = vk->f.vkResetFences(vk->dev, 1, &vk->fence);
    if (r == VK_SUCCESS) r = vk->f.vkQueueSubmit(vk->queue, 1, &si, vk->fence);
    // A minute: a 4K heavy frame on a software device takes seconds; longer means the device is lost.
    if (r == VK_SUCCESS) r = vk->f.vkWaitForFences(vk->dev, 1, &vk->fence, VK_TRUE, 60ull * 1000 * 1000 * 1000);
    if (r != VK_SUCCESS) { vkg_fail(vk, "frame did not complete: %d", (int)r); return -1; }
    return 0;
}

static int renderLocked(MpvfxVk *vk, const MpvfxGpuGradeJob *j, uint8_t *rgba) {
    if (ensureTargets(vk, j) != 0) return -2;
    int copyTables = ensureTables(vk, j);
    if (copyTables < 0) return -2;
    size_t bytes = (size_t)j->width * (size_t)j->height * 4;
    memcpy(vk->targets.upload.map, rgba, bytes);
    MpvfxGpuPass passes[MPVFX_GPU_MAX_PASSES];
    int n = mpvfx_gpu_plan(j, passes);
    for (int i = 0; i < n; i++) writeSet(vk, i, &passes[i], j);
    vk->current = j;
    int r = record(vk, passes, n, copyTables);
    vk->current = NULL;
    if (r != 0) return -3;
    if (submitAndWait(vk) != 0) {
        vk->tables.valid = 0;  // the copies may not have run
        return -4;
    }
    memcpy(rgba, vk->targets.download.map, bytes);
    return 0;
}

int mpvfx_vk_render(MpvfxVk *vk, const MpvfxGpuGradeJob *j, uint8_t *rgba) {
    if (!vk || !j || !rgba) return -1;
    pthread_mutex_lock(&vk->lock);
    vk->err[0] = 0;
    int r;
    if (j->width <= 0 || j->height <= 0 || j->width > 16384 || j->height > 16384 || !j->uniforms ||
        j->uniformCount * 4 > VKG_PARAM_STRIDE - VKG_HDR_BYTES || j->lutSize < 0 || j->lutSize > 256) {
        vkg_fail(vk, "bad job (%dx%d, %d uniforms, LUT %d)", j->width, j->height, j->uniformCount, j->lutSize);
        r = -1;
    } else {
        r = renderLocked(vk, j, rgba);
    }
    pthread_mutex_unlock(&vk->lock);
    return r;
}
