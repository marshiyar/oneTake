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

/// Clip fades set from the timeline: the fade handles, and Fade In / Fade Out / Remove Fades in the clip menu. A fade is
/// a whole number of frames in `fadeInFrames` / `fadeOutFrames` (`NativeClipFade`); each edit is one undo step.
public extension TimelineEditor {
    /// The length a menu "Fade In" / "Fade Out" gives a clip, in seconds (less when the clip has no room for it).
    static let defaultFadeSeconds = 1.0

    /// The clip's fades in frames (0 when none).
    func fadeFrames(clipId: String) -> (fadeIn: Double, fadeOut: Double) {
        guard let (_, c) = clip(clipId) else { return (0, 0) }
        return (c.fadeInFrames ?? 0, c.fadeOutFrames ?? 0)
    }

    /// The longest fade on `edge` (`.start` is the fade-in, `.end` the fade-out): the clip's length minus the fade on
    /// the other edge, so the two ramps never cross. Zero for a missing clip.
    func maxFadeFrames(clipId: String, edge: TrimEdge) -> Double {
        guard let (_, c) = clip(clipId) else { return 0 }
        let other = (edge == .start ? c.fadeOutFrames : c.fadeInFrames) ?? 0
        return max(0, c.durationFrames - other)
    }

    /// Sets the fade on `edge` to `frames` (rounded to whole frames; 0 removes it). Refused, with `lastFailure` saying
    /// why, on a locked track, for a length that is not a finite non-negative number, or one past `maxFadeFrames`.
    @discardableResult
    func setClipFade(clipId: String, edge: TrimEdge, frames: Double) -> Bool {
        guard let a = address(clipId: clipId) else {
            lastFailure = .init(code: .missingClip, message: "Clip \(clipId) is not in the project"); return false
        }
        guard !isTrackLocked(a.trackId) else { lastFailure = .init(code: .documentMismatch, message: "Track is locked"); return false }
        guard frames.isFinite, frames >= 0 else {
            lastFailure = .init(code: .invalidTrim, message: "A fade must be a non-negative number of frames"); return false
        }
        let whole = frames.rounded()
        guard whole <= maxFadeFrames(clipId: clipId, edge: edge) else {
            lastFailure = .init(code: .invalidTrim, message: "A fade cannot be longer than the clip or cross the other fade"); return false
        }
        return updateFades(a, edge == .start ? "Set fade in" : "Set fade out") { c in
            if edge == .start { c.fadeInFrames = whole > 0 ? whole : nil } else { c.fadeOutFrames = whole > 0 ? whole : nil }
        }
    }

    /// Gives the clip a fade of `defaultFadeSeconds` on `edge`, cut to the room the clip has. Refused when there is none.
    @discardableResult
    func addDefaultFade(clipId: String, edge: TrimEdge) -> Bool {
        let room = maxFadeFrames(clipId: clipId, edge: edge)
        let frames = min((Self.defaultFadeSeconds * fps).rounded(), room.rounded(.down))
        guard frames >= 1 else {
            lastFailure = .init(code: .invalidTrim, message: "The clip has no room for a fade"); return false
        }
        return setClipFade(clipId: clipId, edge: edge, frames: frames)
    }

    /// Removes both fades in one undo step. False (nothing changes) when the clip has none, or its track is locked.
    @discardableResult
    func removeFades(clipId: String) -> Bool {
        guard let a = address(clipId: clipId) else { return false }
        guard !isTrackLocked(a.trackId) else { lastFailure = .init(code: .documentMismatch, message: "Track is locked"); return false }
        return updateFades(a, "Remove fades") { $0.fadeInFrames = nil; $0.fadeOutFrames = nil }
    }

    private func updateFades(_ a: NativeProjectClipAddress, _ label: String, _ change: (inout NativeProjectClip) -> Void) -> Bool {
        var d = document
        guard let t = d.sequence.tracks.firstIndex(where: { $0.id == a.trackId }),
              let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == a.clipId }) else { return false }
        change(&d.sequence.tracks[t].clips[i])
        guard commit(d, label) else { return false }
        lastFailure = nil
        return true
    }
}
