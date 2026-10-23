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
import Foundation
import MpvfxShared

/// A generated text or shape element needs no source media file.
/// The frame renderer draws both through the preview's shared painter.
func nativeIsTextClip(_ clip: NativeProjectClip, _ project: NativeProjectDocument) -> Bool {
    (clip.text != nil || clip.shape?.isSupported == true) && project.assets.first(where: { $0.id == clip.assetId })?.kind == .element
}
