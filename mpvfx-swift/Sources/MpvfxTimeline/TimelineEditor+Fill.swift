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
    /// Sets what fills the frame behind clips that do not cover it, for the whole project (nil: nothing). One undo
    /// step; false, with nothing recorded, when the document refuses the fill or it is the one already set.
    @discardableResult
    func setCompositionCanvasFill(_ fill: NativeFill?) -> Bool {
        guard document.compositionFill != fill else { return false }
        var d = document
        d.compositionFill = fill
        return commitPresets(d, label: "Set canvas fill")
    }

    /// Sets one clip's own fill (`inherit` or nil takes the project's). One undo step; false when the clip is not
    /// there, nothing changes, or the document refuses the fill.
    @discardableResult
    func setClipCanvasFill(clipId: String, _ fill: NativeFill?) -> Bool {
        var d = document
        var found = false
        for t in d.sequence.tracks.indices {
            guard let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            guard d.sequence.tracks[t].clips[i].fill != fill else { return false }
            d.sequence.tracks[t].clips[i].fill = fill; found = true
        }
        return found && commitPresets(d, label: "Set clip fill")
    }
}
