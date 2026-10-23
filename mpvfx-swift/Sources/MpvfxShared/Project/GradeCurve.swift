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

/// The one grade curve every consumer evaluates: the renderer's lookup tables (MpvfxColor `ColorCurves`), the preview
/// grade, export, and the inspector's curve graph (MpvfxPanels). Keeping a single evaluator is what makes the drawn
/// curve the curve that renders: the graph used its own spline (arithmetic-mean tangents, no limiter), which overshot
/// far outside 0…1 next to a steep segment and drew through the panel above the graph.
///
/// The interpolant is the TS curve compiler's (colorGradingCurves.js): a shape-preserving cubic Hermite with
/// Fritsch–Butland tangents (a weighted harmonic mean of the neighbouring slopes at interior points, zero at a local
/// extremum or a flat neighbour; a limited three-point slope at the ends). Each tangent is at most three times the
/// slope of the segments beside it, so every segment is monotone and stays between its two points' values.
public enum GradeCurve {
    public static let maxPoints = 16
    public static let identity: [[Double]] = [[0, 0], [1, 1]]

    public static let flatDelta: [[Double]] = [[0, 0], [1, 0]]

    /// Nonperiodic unit-input saturation deltas, with neutral anchors at missing edges.
    public static func normalizedDelta(_ raw: [[Double]]) -> [[Double]] {
        guard raw.count >= 2, raw.count <= maxPoints else { return flatDelta }
        var points: [[Double]] = []
        for p in raw {
            guard p.count == 2, p[0].isFinite, p[1].isFinite else { return flatDelta }
            points.append([clamp(p[0], 0, 1), clamp(p[1], -1, 1)])
        }
        points.sort { $0[0] < $1[0] }
        if zip(points, points.dropFirst()).contains(where: { $0[0] == $1[0] }) { return flatDelta }
        if (points.first?[0] ?? 0) > 0 { points.insert([0, 0], at: 0) }
        if (points.last?[0] ?? 1) < 1 { points.append([1, 0]) }
        return points.count > maxPoints ? flatDelta : points
    }

    public static func valueDelta(_ normalized: [[Double]], at x: Double) -> Double {
        clamp(Spline(normalized).value(at: clamp(x, 0, 1)), -1, 1)
    }

    // MARK: Normalization (the shapes the renderer accepts)

    /// An RGB curve as the renderer reads it: inputs and outputs clamped to 0…1, sorted by input, an end point added
    /// at (0,0) / (1,1) when the curve does not reach an edge. Two points on one input, fewer than two points or more
    /// than `maxPoints` after the ends are added fall back to the identity.
    public static func normalizedRGB(_ raw: [[Double]]) -> [[Double]] {
        guard raw.count >= 2 else { return identity }
        var points: [[Double]] = []
        for p in raw {
            guard p.count == 2, p[0].isFinite, p[1].isFinite else { return identity }
            points.append([clamp(p[0], 0, 1), clamp(p[1], 0, 1)])
        }
        points.sort { $0[0] < $1[0] }
        if zip(points, points.dropFirst()).contains(where: { $0[0] == $1[0] }) { return identity }
        if (points.first?[0] ?? 0) > 0 { points.insert([0, 0], at: 0) }
        if (points.last?[0] ?? 1) < 1 { points.append([1, 1]) }
        return points.count > maxPoints ? identity : points
    }

    /// A hue curve (degrees, delta) as the renderer reads it: hues wrapped into [0, 360), deltas clamped to `limit`,
    /// sorted. Fewer than three or more than `maxPoints` points, or two points on one hue, make it flat ([]).
    public static func normalizedHue(_ raw: [[Double]], limit: ClosedRange<Double>) -> [[Double]] {
        guard raw.count >= 3, raw.count <= maxPoints else { return [] }
        var points: [[Double]] = []
        for p in raw {
            guard p.count == 2, p[0].isFinite, p[1].isFinite else { return [] }
            points.append([wrapHue(p[0]), clamp(p[1], limit.lowerBound, limit.upperBound)])
        }
        points.sort { $0[0] < $1[0] }
        return zip(points, points.dropFirst()).contains(where: { $0[0] == $1[0] }) ? [] : points
    }

    /// A hue in degrees wrapped into [0, 360) as `normalizedHue` reads it. Adding 360 rounds most values (106.619
    /// reads back as 106.61900000000003). For a hue already in [0, 360) the result is a fixed point (wrapping it again
    /// changes nothing: x + 360 − 360 is exact there), so an editor that stores wrapped hues stores exactly what the
    /// renderer reads; a hue outside it needs two wraps to reach that point.
    public static func wrapHue(_ h: Double) -> Double {
        (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// A sorted hue curve made periodic: the last two points repeated 360° earlier and the first two 360° later, so the
    /// spline is smooth across 0°/360°.
    public static func periodic(_ sorted: [[Double]]) -> [[Double]] {
        let before = sorted.suffix(2).map { [$0[0] - 360, $0[1]] }
        let after = sorted.prefix(2).map { [$0[0] + 360, $0[1]] }
        return before + sorted + after
    }

    // MARK: Evaluation

    /// Evaluates normalized RGB points (`normalizedRGB`) at input `x`; the result is in 0…1.
    public static func valueRGB(_ normalized: [[Double]], at x: Double) -> Double {
        clamp(Spline(normalized).value(at: clamp(x, 0, 1)), 0, 1)
    }

    /// Evaluates normalized hue points (`normalizedHue`) at `hue` degrees; flat (0) when the curve is empty, and the
    /// result is in `limit`.
    public static func valueHue(_ normalized: [[Double]], at hue: Double, limit: ClosedRange<Double>) -> Double {
        guard normalized.count >= 3 else { return 0 }
        return clamp(Spline(periodic(normalized)).value(at: hue), limit.lowerBound, limit.upperBound)
    }

    /// The cubic through strictly increasing points (at least two).
    public struct Spline {
        public let points: [[Double]]
        public let tangents: [Double]
        public init(_ points: [[Double]]) {
            self.points = points
            tangents = points.count >= 2 ? GradeCurve.tangents(points) : []
        }

        /// The curve at `x`; outside the points it holds the first / last value (the segment parameter is clamped).
        public func value(at x: Double) -> Double {
            guard points.count >= 2 else { return points.first?[1] ?? x }
            var seg = 0
            while seg < points.count - 2 && x > points[seg + 1][0] { seg += 1 }
            let s = points[seg], e = points[seg + 1], span = e[0] - s[0]
            let u = Swift.min(1, Swift.max(0, (x - s[0]) / span)), u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * s[1] + (u3 - 2 * u2 + u) * span * tangents[seg] + (-2 * u3 + 3 * u2) * e[1]
                + (u3 - u2) * span * tangents[seg + 1]
        }
    }

    static func sign(_ x: Double) -> Double { x > 0 ? 1 : x < 0 ? -1 : 0 }

    static func endpointSlope(_ firstSpan: Double, _ secondSpan: Double, _ firstSlope: Double, _ secondSlope: Double) -> Double {
        let slope = ((2 * firstSpan + secondSpan) * firstSlope - firstSpan * secondSlope) / (firstSpan + secondSpan)
        if sign(slope) != sign(firstSlope) { return 0 }
        if sign(firstSlope) != sign(secondSlope) && abs(slope) > 3 * abs(firstSlope) { return 3 * firstSlope }
        return slope
    }

    /// Fritsch–Butland tangents at every point (strictly increasing inputs, at least two points).
    public static func tangents(_ points: [[Double]]) -> [Double] {
        var spans: [Double] = [], slopes: [Double] = []
        for i in 1..<points.count {
            let span = points[i][0] - points[i - 1][0]
            spans.append(span); slopes.append((points[i][1] - points[i - 1][1]) / span)
        }
        if points.count == 2 { return [slopes[0], slopes[0]] }
        var r = [Double](repeating: 0, count: points.count)
        r[0] = endpointSlope(spans[0], spans[1], slopes[0], slopes[1])
        r[r.count - 1] = endpointSlope(spans[spans.count - 1], spans[spans.count - 2], slopes[slopes.count - 1], slopes[slopes.count - 2])
        for i in 1..<(points.count - 1) {
            let before = slopes[i - 1], after = slopes[i]
            if before == 0 || after == 0 || sign(before) != sign(after) { r[i] = 0; continue }
            let bw = 2 * spans[i] + spans[i - 1], aw = spans[i] + 2 * spans[i - 1]
            r[i] = (bw + aw) / (bw / before + aw / after)
        }
        return r
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, v)) }
}
