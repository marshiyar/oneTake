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
    /// Swap only the source reference. Authored geometry, animation and effects remain on the clip;
    /// an untouched box follows the replacement asset's natural size; a placeholder marker on the clip goes, because
    /// the slot is filled. A new asset and the swap undo together.
    @discardableResult
    func replaceMedia(clipId: String, asset: NativeProjectAsset) -> Bool {
        lastFailure = nil
        do { return commit(try document.replacingMedia(clipId: clipId, with: asset), "Replace media") }
        catch let failure as NativeProjectClipFailure { lastFailure = failure; return false }
        catch { return false }
    }
}
