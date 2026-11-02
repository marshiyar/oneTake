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
// Caption lane edits on the editor: each plan from NativeCaptionEditPlan.swift is committed as one undo step through the
// document's history, so it persists with the rest of the edit history across a restart. A drag keeps its preview in the
// view and calls one of these once on release.
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// The cues of the caption track in start order; empty when the project has none.
    var captionCues: [NativeCaptionCue] { document.sequence.captions?.cues ?? [] }

    /// One frame of the sequence in whole milliseconds, the shortest a cue may be.
    var captionMinimumDurationMs: Int { nativeCaptionMinimumDurationMs(frameRate: fps) }

    /// Moves a cue to start at `startMs`, clamped against its neighbours. False when the cue is unknown or does not move.
    @discardableResult
    func moveCaptionCue(_ id: String, toStartMs startMs: Int) -> Bool {
        commitCaptions(label: "Move caption") { try planCaptionMove($0, cueId: id, toStartMs: startMs) }
    }

    /// Moves one edge of a cue to `ms`, clamped against its neighbours and the one-frame minimum.
    @discardableResult
    func trimCaptionCue(_ id: String, edge: NativeCaptionEdge, toMs ms: Int) -> Bool {
        let rate = fps
        return commitCaptions(label: "Trim caption") { try planCaptionTrim($0, cueId: id, edge: edge, toMs: ms, frameRate: rate) }
    }

    /// Retypes a cue. False when the text is not storable (empty, a blank line, `-->`, control characters) or unchanged.
    @discardableResult
    func setCaptionText(_ id: String, to text: String) -> Bool {
        commitCaptions(label: "Edit caption") { try planCaptionRetext($0, cueId: id, text: text) }
    }

    /// Adds a cue at `startMs`: 2 s, or up to the next cue when the gap is shorter. Returns its id, or nil when there is no
    /// room for a frame there.
    @discardableResult
    func addCaptionCue(atMs startMs: Int) -> String? {
        guard let planned = try? planCaptionAdd(document.sequence.captions, atMs: startMs, frameRate: fps) else { return nil }
        var d = document
        d.sequence.captions = planned.track
        return commitPresets(d, label: "Add caption") ? planned.cueId : nil
    }

    /// Sets the look every cue shares (nil goes back to the default look). False when there is no caption track, nothing
    /// changes, or the look is not storable.
    @discardableResult
    func setCaptionLook(_ look: NativeCaptionLook?) -> Bool {
        commitCaptions(label: "Change caption look") { var t = $0; t.look = look; return t }
    }

    /// Sets where one cue sits (nil makes it follow the track look again).
    @discardableResult
    func setCaptionPosition(_ id: String, to position: NativeCaptionPosition?) -> Bool {
        commitCaptions(label: "Move caption on screen") { track in
            guard let i = track.cues.firstIndex(where: { $0.id == id }) else { throw NativeCaptionEditError.unknownCue(id) }
            var t = track; t.cues[i].position = position; return t
        }
    }

    private func commitCaptions(label: String, _ plan: (NativeCaptionTrack) throws -> NativeCaptionTrack) -> Bool {
        guard let track = document.sequence.captions, let edited = try? plan(track), edited != track else { return false }
        var d = document
        d.sequence.captions = edited
        return commitPresets(d, label: label)
    }
}
