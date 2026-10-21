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

public extension TimelineEditor {
    /// Validated document edit, recorded as one undo step and persisted through the normal project serializer.
    @discardableResult
    func setClipShape(clipId: String, _ shape: NativeClipShape?) -> Bool {
        do {
            guard let d = try nativeClipShapeEditPlan(document, clipId: clipId, shape: shape, engine: engine) else { return false }
            return commitPresets(d, label: "Set shape")
        } catch { return false }
    }
}
