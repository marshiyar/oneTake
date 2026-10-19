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
// Vulkan API declarations from the system headers (libvulkan-dev). Nothing links against libvulkan: CMpvfxVulkan opens
// the loader (libvulkan.so.1) at run time, so the app still starts, and grades on the CPU, on a machine without it.
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
