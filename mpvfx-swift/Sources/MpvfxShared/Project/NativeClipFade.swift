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
// Clip fades: `fadeInFrames` / `fadeOutFrames` on a clip, in project frames, measured from the clip's start and up to
// its end. They are clip fields, not keyframes: a fade handle stays put when keyframed values change, and its gain
// multiplies whatever the keyframes give (volume today, opacity in a later slice). Linear ramps only.
import Foundation

public enum NativeClipFade {
    /// The edge of a clip a trim moves; that edge's fade gives way first when the clip gets too short for both.
    public enum Edge: Sendable { case start, end }

    /// The fade gain at clip-local `frame` (fractional frames allowed) of a clip `durationFrames` long: a linear ramp
    /// from 0 at the clip start to 1 after `fadeInFrames`, and from 1 down to 0 at the clip end over `fadeOutFrames`,
    /// multiplied and clamped to 0…1. Absent or zero fades give 1 inside the clip.
    public static func gain(atFrame frame: Double, durationFrames: Double, fadeInFrames: Double?, fadeOutFrames: Double?) -> Double {
        ramp(frame, fadeInFrames) * ramp(durationFrames - frame, fadeOutFrames)
    }

    /// One ramp: `distance` from its edge over `length`; no length is unity.
    static func ramp(_ distance: Double, _ length: Double?) -> Double {
        guard let length, length > 0 else { return distance < 0 ? 0 : 1 }
        return max(0, min(1, distance / length))
    }

    /// Fades that fit a clip `durationFrames` long: the fade on the edge that did not move keeps its length (cut to
    /// the clip), the one on `movedEdge` gets what is left. A fade cut to nothing is removed; one that fits is
    /// returned unchanged.
    public static func clamped(fadeIn: Double?, fadeOut: Double?, durationFrames: Double,
                               movedEdge: Edge) -> (fadeIn: Double?, fadeOut: Double?) {
        let limit = max(0, durationFrames)
        switch movedEdge {
        case .end:
            let kept = clamp(fadeIn, limit)
            return (kept, clamp(fadeOut, limit - (kept ?? 0)))
        case .start:
            let kept = clamp(fadeOut, limit)
            return (clamp(fadeIn, limit - (kept ?? 0)), kept)
        }
    }

    static func clamp(_ length: Double?, _ limit: Double) -> Double? {
        guard let length, length > limit else { return length }
        return limit > 0 ? limit : nil
    }
}

public extension NativeProjectClip {
    /// `NativeClipFade.gain` for this clip at clip-local `frame`.
    func fadeGain(atFrame frame: Double) -> Double {
        NativeClipFade.gain(atFrame: frame, durationFrames: durationFrames, fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
    }

    /// Cuts the fades to the clip's current `durationFrames` after a trim of `movedEdge` (`NativeClipFade.clamped`).
    mutating func clampFades(movedEdge: NativeClipFade.Edge) {
        (fadeInFrames, fadeOutFrames) = NativeClipFade.clamped(fadeIn: fadeInFrames, fadeOut: fadeOutFrames,
                                                               durationFrames: durationFrames, movedEdge: movedEdge)
    }
}

/// Each fade, when present, is a finite non-negative number of frames, and the two together fit the clip.
func validateNativeClipFades(_ clip: NativeJSONValue, _ clipPath: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    var lengths: [Double] = []
    var valid = true
    for name in ["fadeInFrames", "fadeOutFrames"] {
        guard let value = clip[name] else { continue }
        guard let n = value.numberValue, n.isFinite, n >= 0 else {
            pushIssue(&issues, .invalidFade, "\(clipPath).\(name)", "Fade length must be a finite non-negative number of frames")
            valid = false
            continue
        }
        lengths.append(n)
    }
    guard valid, !lengths.isEmpty, let duration = clip["durationFrames"]?.numberValue, duration.isFinite else { return }
    if lengths.reduce(0, +) > duration {
        pushIssue(&issues, .fadeExceedsClip, clipPath, "Fade in and fade out together must not be longer than the clip")
    }
}
