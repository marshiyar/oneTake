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

/// The corner-pin distort of a clip: each edit is one undo step, validated like every document change.
public extension TimelineEditor {
    static let distortLabel = "Distort clip", resetDistortLabel = "Reset distort"

    /// The corners the clip shows at `time` (saved offsets with their keyframes evaluated); identity when none.
    func corners(clipId: String, time: Double) -> NativeClipCorners {
        guard let (_, c) = clip(clipId), let f = localFrame(clipId: clipId, time: time) else { return .identity }
        return (try? c.cornersAt(frame: f, engine: engine)) ?? (c.corners ?? .identity)
    }

    /// The clip has saved corners or corner keyframes (Reset would change something).
    func hasCornerState(clipId: String) -> Bool { clip(clipId)?.clip.hasCornerState ?? false }

    /// Sets the clip's corners at `time`: a key at that frame when corner components are keyframed (or `keyframed`
    /// starts keyframing), else the saved offsets. One undo step; false for a locked track or no change.
    @discardableResult
    func setCorners(clipId: String, _ new: NativeClipCorners, time: Double, keyframed: Bool = false) -> Bool {
        guard let (track, c) = clip(clipId), track.locked != true, let f = localFrame(clipId: clipId, time: time) else { return false }
        return edit(clipId: clipId, track: track, label: Self.distortLabel) { clip in
            clip.setCorners(new, atFrame: f, frameRate: document.frameRate, keyframed: keyframed || c.hasCornerKeyframes)
        }
    }

    /// Reset: the plain box again, saved corners and corner keyframes both gone. One undo step.
    @discardableResult
    func resetCorners(clipId: String) -> Bool {
        guard let (track, c) = clip(clipId), track.locked != true, c.hasCornerState else { return false }
        return edit(clipId: clipId, track: track, label: Self.resetDistortLabel) { $0.resetCorners() }
    }

    private func edit(clipId: String, track: NativeProjectTrack, label: String, _ body: (inout NativeProjectClip) -> Void) -> Bool {
        var doc = document
        guard let t = doc.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let i = doc.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        let old = doc.sequence.tracks[t].clips[i]
        body(&doc.sequence.tracks[t].clips[i])
        guard doc.sequence.tracks[t].clips[i] != old else { return false }
        let before = document
        guard let validated = try? parseNativeProjectDocument(doc, engine: engine) else { return false }
        withHistory(label) { replaceDocument(validated, inverse: .restoreDocument(before)) }
        return true
    }
}
