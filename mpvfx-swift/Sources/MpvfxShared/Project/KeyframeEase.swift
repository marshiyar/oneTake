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
// Ease maths for the keyframe Easing panel: eased progress and speed of one segment, and the influence / velocity
// form of its cubic timing curve. The keyframe engine owns interpolation; this file mirrors its segment timing so the
// panel can draw a curve without a track, and `KeyframeEaseParityTests` holds the two together frame by frame.
import Foundation

public enum KeyframeEase {
    /// The two handles of a cubic timing curve as a graph editor shows them. Influence is the handle's reach as a
    /// fraction of the segment (0…1); slope is the speed at that end relative to the segment's linear speed.
    public struct Handles: Equatable, Sendable {
        public var outInfluence: Double, outSlope: Double, inInfluence: Double, inSlope: Double
        public init(outInfluence: Double, outSlope: Double, inInfluence: Double, inSlope: Double) {
            self.outInfluence = outInfluence; self.outSlope = outSlope; self.inInfluence = inInfluence; self.inSlope = inSlope
        }
    }

    /// Handle reach: 0.1 % (a zero reach has no defined slope) to 100 %, which keeps x inside the engine's 0…1.
    public static let influenceRange: ClosedRange<Double> = 0.001...1
    /// Handle height, as the inspector's curve fields clamp it.
    public static let yRange: ClosedRange<Double> = -1...2
    /// Easy ease: one third of the segment, speed 0 (the After Effects default influence of 33.33 %).
    public static let easyEaseInfluence = 1.0 / 3

    /// Eased progress at segment fraction `t` (clamped to 0…1): 0 at the leaving key, 1 at the next.
    public static func progress(_ ease: NativeInterpolation, at t: Double) -> Double {
        let t = clampUnit(t)
        switch ease {
        case .hold: return t >= 1 ? 1 : 0
        case .linear: return t
        case .cubicBezier(let p):
            guard let c = Curve(p) else { return t }
            return c.y(c.solve(t))
        }
    }

    /// d(progress)/dt at `t`: 1 is the linear speed of the segment, 0 standing still.
    public static func slope(_ ease: NativeInterpolation, at t: Double) -> Double {
        let t = clampUnit(t)
        switch ease {
        case .hold: return 0
        case .linear: return 1
        case .cubicBezier(let p):
            guard let c = Curve(p) else { return 1 }
            return c.slope(at: c.solve(t))
        }
    }

    /// The influence / slope form of a curve; nil when a control point is not finite.
    public static func handles(_ p: CubicBezierControlPoints) -> Handles? {
        guard [p.x1, p.y1, p.x2, p.y2].allSatisfy(\.isFinite) else { return nil }
        let outReach = clamp(p.x1, influenceRange), inReach = clamp(1 - p.x2, influenceRange)
        return Handles(outInfluence: clamp(p.x1, 0...1), outSlope: p.y1 / outReach,
                       inInfluence: clamp(1 - p.x2, 0...1), inSlope: (1 - p.y2) / inReach)
    }

    /// Control points for handles, clamped so the engine accepts them (x in 0…1) and y stays in `yRange`.
    public static func points(_ h: Handles) -> CubicBezierControlPoints {
        let outReach = clamp(h.outInfluence, influenceRange), inReach = clamp(h.inInfluence, influenceRange)
        return CubicBezierControlPoints(x1: outReach, y1: clamp(finite(h.outSlope) * outReach, yRange),
                                        x2: 1 - inReach, y2: clamp(1 - finite(h.inSlope) * inReach, yRange))
    }

    /// Speed in property units per second for a slope on a segment that changes by `valueChange` over `seconds`.
    public static func velocity(slope: Double, valueChange: Double, seconds: Double) -> Double {
        guard seconds > 0, seconds.isFinite else { return 0 }
        return finite(slope * abs(valueChange) / seconds)
    }

    /// The slope that gives `velocity` units per second on that segment; 0 when the segment does not move.
    public static func slope(velocity: Double, valueChange: Double, seconds: Double) -> Double {
        let linear = Self.velocity(slope: 1, valueChange: valueChange, seconds: seconds)
        return linear > 0 ? finite(velocity / linear) : 0
    }

    /// Easy ease on one or both ends of a segment: that handle gets one third reach and speed 0; the other end keeps
    /// its shape (a linear segment keeps its linear speed there). A hold has no handles and stays a hold.
    public static func easyEase(_ ease: NativeInterpolation, out: Bool, in inSide: Bool) -> NativeInterpolation {
        var p: CubicBezierControlPoints
        switch ease {
        case .hold: return .hold
        case .linear: p = CubicBezierControlPoints(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        case .cubicBezier(let q): p = q
        }
        if out { p.x1 = easyEaseInfluence; p.y1 = 0 }
        if inSide { p.x2 = 1 - easyEaseInfluence; p.y2 = 1 }
        return .cubicBezier(p)
    }

    // MARK: - Curve

    /// The cubic through (0,0), (x1,y1), (x2,y2), (1,1), x control points clamped to 0…1 so x(s) is monotone.
    struct Curve {
        let x1, y1, x2, y2: Double
        init?(_ p: CubicBezierControlPoints) {
            guard [p.x1, p.y1, p.x2, p.y2].allSatisfy(\.isFinite) else { return nil }
            x1 = clampUnit(p.x1); x2 = clampUnit(p.x2); y1 = p.y1; y2 = p.y2
        }
        static func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        static func derivative(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
        }
        func x(_ s: Double) -> Double { Self.bezier(x1, x2, s) }
        func y(_ s: Double) -> Double { Self.bezier(y1, y2, s) }

        /// The curve parameter where x(s) = t: Newton steps from s = t, then bisection when they leave the bracket.
        func solve(_ t: Double) -> Double {
            var s = t
            for _ in 0..<8 {
                let err = x(s) - t, d = Self.derivative(x1, x2, s)
                if abs(err) < 1e-14 { return s }
                guard abs(d) > 1e-12 else { break }
                s -= err / d
                guard (0...1).contains(s) else { break }
            }
            return bisect(t)
        }

        func bisect(_ t: Double) -> Double {
            var lo = 0.0, hi = 1.0, s = t
            for _ in 0..<60 {
                s = (lo + hi) / 2
                if x(s) < t { lo = s } else { hi = s }
            }
            return s
        }

        /// dy/dx at parameter s; where dx/ds vanishes (a zero-reach handle) the limit is taken just inside.
        func slope(at s: Double) -> Double {
            var dx = Self.derivative(x1, x2, s), dy = Self.derivative(y1, y2, s)
            if abs(dx) < 1e-9 {
                let inner = s < 0.5 ? s + 1e-6 : s - 1e-6
                dx = Self.derivative(x1, x2, inner); dy = Self.derivative(y1, y2, inner)
            }
            return abs(dx) < 1e-12 ? 0 : finite(dy / dx)
        }
    }

    static func clampUnit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : (v == .infinity ? 1 : 0) }
    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isNaN ? r.lowerBound : min(r.upperBound, max(r.lowerBound, v)) }
    static func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
}
