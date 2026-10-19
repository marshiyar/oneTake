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

/// Clip speed (the inspector's Rate row and any timeline speed control share it).
public extension TimelineEditor {
    func playbackRate(clipId: String) -> Double {
        guard let r = clip(clipId)?.clip.playbackRate, r.denominator != 0 else { return 1 }
        return r.numerator / r.denominator
    }

    /// Sets the clip's speed. The clip keeps its source range, so its timeline length scales by old/new rate.
    /// One undo step ("Change speed"); refused on a locked track.
    @discardableResult
    func setPlaybackRate(clipId: String, _ rate: Double) -> Bool {
        guard rate.isFinite, rate > 0, !isClipLocked(clipId) else { return false }
        let old = playbackRate(clipId: clipId)
        guard abs(old - rate) > 1e-9 else { return false }
        var d = document
        for t in d.sequence.tracks.indices {
            guard let i = d.sequence.tracks[t].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var c = d.sequence.tracks[t].clips[i]
            c.durationFrames = max(1, (c.durationFrames * old / rate).rounded())
            c.playbackRate = abs(rate - 1) < 1e-9 ? nil : NativePlaybackRate(numerator: (rate * 1000).rounded(), denominator: 1000)
            d.sequence.tracks[t].clips[i] = c
            return commit(d, "Change speed")
        }
        return false
    }
}
