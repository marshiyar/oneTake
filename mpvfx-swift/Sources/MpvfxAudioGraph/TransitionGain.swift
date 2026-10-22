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
// Gain ramps a cut transition puts on a clip's sound: an equal-power fade out on the clip before the cut and an
// equal-power fade in on the clip after it, over the transition's range (a dip fades out up to the cut and in after
// it). Applied to the stem before the clip's effects, so an effect's tail still rings out.
import Foundation

/// One equal-power ramp on the composition timeline, in seconds.
public struct AudioGainRamp: Equatable, Sendable {
    /// `fadeIn`: gain sin(p·π/2) rising 0 → 1; otherwise cos(p·π/2) falling 1 → 0, p the progress through the ramp.
    public var start: Double, end: Double, fadeIn: Bool
    public init(start: Double, end: Double, fadeIn: Bool) { self.start = start; self.end = end; self.fadeIn = fadeIn }

    public func gain(at t: Double) -> Double {
        let p = end > start ? min(1, max(0, (t - start) / (end - start))) : 1
        return fadeIn ? sin(p * .pi / 2) : cos(p * .pi / 2)
    }
}

/// The transition ramps on one track: a fade in where it comes in through a transition, a fade out where it leaves.
public struct AudioTransitionGain: Equatable, Sendable {
    public var fadeIn: AudioGainRamp?, fadeOut: AudioGainRamp?
    public init(fadeIn: AudioGainRamp? = nil, fadeOut: AudioGainRamp? = nil) { self.fadeIn = fadeIn; self.fadeOut = fadeOut }

    /// The gain at composition second `t` (1 outside both ramps' reach).
    public func gain(at t: Double) -> Double {
        var g = 1.0
        if let r = fadeIn, t < r.end { g *= r.gain(at: t) }
        if let r = fadeOut, t > r.start { g *= r.gain(at: t) }
        return g
    }

    /// Gains for stem frames [0, count) of a track starting at `start` seconds, at `sampleRate`.
    func samples(count: Int, start: Double, sampleRate: Double) -> [Float] {
        (0..<max(0, count)).map { Float(gain(at: start + Double($0) / sampleRate)) }
    }
}
