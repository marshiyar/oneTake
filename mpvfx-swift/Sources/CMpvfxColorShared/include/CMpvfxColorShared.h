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
// The uniform/parameter layout shared with the Metal kernels. The one copy of it lives beside the shader
// (Sources/MpvfxMetal/Shaders/MpvfxColorShared.h) so the shader's resource bundle carries it too.
#include "../../MpvfxMetal/Shaders/MpvfxColorShared.h"
// The job the Vulkan and Direct3D 11 compute backends take.
#include "MpvfxGpuJob.h"
// Their multipass plan (dispatch order, buffer roles and sizes, threadgroup counts) and the DXGI adapter test.
#include "MpvfxGpuPlan.h"
