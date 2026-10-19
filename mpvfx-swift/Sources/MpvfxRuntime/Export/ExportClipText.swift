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

/// A clip that draws text: a `clip.text` on an element asset (native media documents have no other element layers).
/// The frame renderer lays its words out with the preview's text renderer, so exported text is the preview's.
func nativeIsTextClip(_ clip: NativeProjectClip, _ project: NativeProjectDocument) -> Bool {
    clip.text != nil && project.assets.first(where: { $0.id == clip.assetId })?.kind == .element
}
