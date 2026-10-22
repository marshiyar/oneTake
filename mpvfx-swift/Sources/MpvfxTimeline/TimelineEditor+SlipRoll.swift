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

/// Slip and roll as timeline edits: each clamps the request to what the source media allows and commits one undo step
/// through `apply` (which refuses locked tracks). The document commands are in `MpvfxShared` (NativeTimelineSlipRoll.swift).
public extension TimelineEditor {
    /// The slip deltas (timeline frames) the clip accepts; nil for a still, a text clip, a locked track or a missing clip.
    func slipRange(clipId: String) -> ClosedRange<Double>? {
        guard let a = address(clipId: clipId), !isTrackLocked(a.trackId) else { return nil }
        return nativeSlipRange(document, a)
    }

    /// Slip the clip's content by `frames` timeline frames (+ shows later source), clamped at the start and end of its
    /// source media. Position, length and keyframes stay. False when nothing changed or the clip cannot slip.
    @discardableResult
    func slip(clipId: String, byFrames frames: Double) -> Bool {
        guard frames.isFinite, let a = address(clipId: clipId), let range = slipRange(clipId: clipId) else { return false }
        let delta = min(max(frames.rounded(), range.lowerBound), range.upperBound)
        guard delta != 0 else { return false }
        return apply(.slip(address: a, deltaFrames: delta))
    }

    /// `timelineFrames` of the clip's playback as a fraction of its source media (the slip preview shifts the waveform
    /// by it); 0 when the asset has no length.
    func sourceFraction(clipId: String, timelineFrames: Double) -> Double {
        guard let c = clip(clipId)?.clip, let asset = document.assets.first(where: { $0.id == c.assetId }), asset.durationFrames > 0 else { return 0 }
        let rate = c.playbackRate.map { $0.denominator != 0 ? $0.numerator / $0.denominator : 1 } ?? 1
        return timelineFrames * rate / asset.durationFrames
    }

    /// The clip touching `edge` on the same track (the incoming clip after `.end`, the outgoing one before `.start`).
    func rollPartner(clipId: String, edge: TrimEdge) -> String? {
        guard let a = address(clipId: clipId), let track = document.sequence.tracks.first(where: { $0.id == a.trackId }),
              let c = track.clips.first(where: { $0.id == clipId }) else { return nil }
        let cut = edge == .end ? c.startFrame + c.durationFrames : c.startFrame
        return track.clips.first { other in
            other.id != clipId && (edge == .end ? other.startFrame == cut : other.startFrame + other.durationFrames == cut)
        }?.id
    }

    /// Where the cut at the clip's `edge` can roll to, in timeline frames; nil with no touching clip or on a locked track.
    func rollRange(clipId: String, edge: TrimEdge) -> ClosedRange<Double>? {
        guard let roll = rollAddresses(clipId: clipId, edge: edge), !isTrackLocked(roll.outgoing.trackId),
              let range = nativeRollRange(document, outgoing: roll.outgoing, incoming: roll.incoming) else { return nil }
        return (roll.cut + range.lowerBound)...(roll.cut + range.upperBound)
    }

    /// Roll the cut at the clip's `edge` to `frame`, clamped where either clip runs out of source media or would drop
    /// below one frame. An edge with no clip touching it is trimmed instead, so a roll never opens a gap. One undo step.
    @discardableResult
    func roll(clipId: String, edge: TrimEdge, toFrame frame: Double) -> Bool {
        guard frame.isFinite, let a = address(clipId: clipId), !isTrackLocked(a.trackId) else { return false }
        guard let roll = rollAddresses(clipId: clipId, edge: edge) else {
            return apply(edge == .start ? .trimIn(address: a, startFrame: frame.rounded()) : .trimOut(address: a, endFrameExclusive: frame.rounded()))
        }
        guard let range = rollRange(clipId: clipId, edge: edge) else { return false }
        let target = min(max(frame.rounded(), range.lowerBound), range.upperBound)
        guard target != roll.cut else { return false }
        return apply(.roll(.init(outgoing: roll.outgoing, incoming: roll.incoming, deltaFrames: target - roll.cut)))
    }

    /// The outgoing/incoming pair and the current cut frame for the clip's `edge`.
    internal func rollAddresses(clipId: String, edge: TrimEdge) -> (outgoing: NativeProjectClipAddress, incoming: NativeProjectClipAddress, cut: Double)? {
        guard let partner = rollPartner(clipId: clipId, edge: edge), let mine = address(clipId: clipId),
              let theirs = address(clipId: partner), let c = clip(clipId)?.clip else { return nil }
        return edge == .end ? (mine, theirs, c.startFrame + c.durationFrames) : (theirs, mine, c.startFrame)
    }
}
