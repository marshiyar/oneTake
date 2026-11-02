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

    /// Whether the clip draws a fill behind it: its own, or the project's when it has none or says `inherit`. A fill
    /// this version cannot read is not drawn, so it is off.
    func canvasFillIsOn(clipId: String) -> Bool {
        guard let clip = clip(clipId)?.clip else { return false }
        let own = clip.fill.flatMap { $0.kind == "inherit" ? nil : $0 }
        guard let shown = own ?? document.compositionFill, shown.isSupported else { return false }
        return shown.kind != "none"
    }

    /// True when every one of the existing clips shows a fill; false for none.
    func canvasFillIsOn(clipIds: Set<String>) -> Bool {
        let existing = clipIds.filter { clip($0) != nil }
        return !existing.isEmpty && existing.allSatisfy { canvasFillIsOn(clipId: $0) }
    }

    /// The clip menu's "Fill empty area" for the selected clips, in one undo step. When every clip shows a fill it turns
    /// them all off (`none`); otherwise it turns the others on: back to the project's fill when the project has one,
    /// else a blurred, darkened copy. Clips on a locked track are left alone; false, with nothing recorded, when
    /// there is no clip to change.
    @discardableResult
    func toggleCanvasFill(clipIds: Set<String>) -> Bool {
        let targets = clipIds.filter { clip($0) != nil && !isClipLocked($0) }
        guard !targets.isEmpty else { return false }
        let turnOff = targets.allSatisfy { canvasFillIsOn(clipId: $0) }
        let projectShows = document.compositionFill.map { $0.isSupported && $0.kind != "none" } ?? false
        var d = document
        for t in d.sequence.tracks.indices {
            for i in d.sequence.tracks[t].clips.indices where targets.contains(d.sequence.tracks[t].clips[i].id) {
                if turnOff {
                    d.sequence.tracks[t].clips[i].fill = NativeFill(kind: "none")
                } else if !canvasFillIsOn(clipId: d.sequence.tracks[t].clips[i].id) {
                    d.sequence.tracks[t].clips[i].fill = projectShows ? nil : NativeFill(kind: "blur")
                }
            }
        }
        return commitPresets(d, label: "Set canvas fill")
    }
}
