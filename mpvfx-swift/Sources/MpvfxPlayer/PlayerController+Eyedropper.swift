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
import MpvfxCanvas

/// The stage eyedropper's state (issue #300): waiting for one click on the selected layer.
struct StageEyedropperSession {
    var clipId: String
    /// Called with the clip id and the click's place on the layer's visible box, 0…1 across each side.
    var onPick: (String, CanvasPoint) -> Void
}
