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

/// The curve editor's point rules, shared by the graph's pointer, its keys and its fields. Every edit starts from
/// the points the renderer reads (`displayed`, `GradeCurve`'s normalization) and returns points the renderer accepts
/// as they are: sorted, at least `minGap` apart, inside the tab's range, never more than `GradeCurve.maxPoints`. A
/// stored curve the renderer would reject (two points on one input, too many points) therefore shows as the curve
/// it renders, and no edit can produce one.
///
/// RGB curves keep their two end points on the edges (input 0 and 1, output free), so the line always starts and
/// ends at a handle. Hue curves are periodic and need three points to render, so the first point added to an empty
/// hue curve brings two flat anchors `seedSpread` degrees either side: the change stays local to the hue clicked.
public struct CurveEditing: Equatable, Sendable {
    public let hue: Bool
    public let limit: ClosedRange<Double>
    /// Degrees between a hue curve's first point and each of the two anchors added with it.
    public static let seedSpread = 60.0

    public init(hue: Bool, limit: ClosedRange<Double>) { self.hue = hue; self.limit = limit }

    /// The smallest input distance between two neighbouring points: 0.01 (RGB) or 1 degree (hue).
    public var minGap: Double { hue ? 1 : 0.01 }
    /// The largest input a point may take: 1 (RGB), or just under 360 degrees, which wraps onto 0 (hue).
    public var inputMax: Double { hue ? 359.9 : 1 }

    // MARK: Reading and writing

    /// The points as the renderer reads them: what the graph draws and every edit starts from.
    public func displayed(_ stored: [[Double]]) -> [[Double]] {
        hue ? GradeCurve.normalizedHue(stored, limit: limit) : GradeCurve.normalizedRGB(stored)
    }

    /// What the grade stores for edited points; nil is the default curve (identity, or a flat hue curve).
    public func stored(_ points: [[Double]]) -> [[Double]]? {
        if hue { return points.count >= 3 ? points : nil }
        return points == GradeCurve.identity ? nil : points
    }

    /// The curve's output at `x`, as rendered.
    public func value(_ points: [[Double]], at x: Double) -> Double {
        hue ? ColorCurveMath.sampleHue(points, at: x, limit: limit) : ColorCurveMath.sample(points, at: x)
    }

    /// An RGB end point: its input stays on the edge and it cannot be removed.
    public func isPinned(_ i: Int, in points: [[Double]]) -> Bool { !hue && (i == 0 || i == points.count - 1) }

    public func canRemove(_ i: Int, in points: [[Double]]) -> Bool { points.indices.contains(i) && !isPinned(i, in: points) }

    // MARK: Edits

    /// Point `i` moved to `p`: an end point keeps its input; any other point stays `minGap` inside its neighbours;
    /// the output is clamped to the tab's range. Both are kept at 1/1000.
    public func moving(_ i: Int, to p: [Double], in points: [[Double]]) -> [[Double]] {
        guard points.indices.contains(i), p.count == 2 else { return points }
        var out = points
        let x = isPinned(i, in: points) ? points[i][0] : constrainedInput(i, p[0], in: points)
        out[i] = [x, output(p[1])]
        return out
    }

    /// The input `x` for point `i` kept `minGap` inside its neighbours (and inside 0…`inputMax`). A point whose
    /// neighbours are already closer than two gaps (a stored curve) keeps its input.
    public func constrainedInput(_ i: Int, _ x: Double, in points: [[Double]]) -> Double {
        let lo = i > 0 ? points[i - 1][0] + minGap : 0
        let hi = i < points.count - 1 ? points[i + 1][0] - minGap : inputMax
        guard lo <= hi, x.isFinite else { return points[i][0] }
        return input(Swift.min(hi, Swift.max(lo, x)))
    }

    /// `p` added to the curve: the new points and the added point's index, or nil when the curve is full or no
    /// input `minGap` away from both neighbours is left there. RGB points go between the two end points.
    public func inserting(_ p: [Double], into points: [[Double]]) -> (points: [[Double]], index: Int)? {
        guard p.count == 2, p[0].isFinite, p[1].isFinite else { return nil }
        if hue && points.count < 3 { return seeded(p) }
        guard points.count < GradeCurve.maxPoints else { return nil }
        let after = points.firstIndex { $0[0] > p[0] } ?? points.count
        let at = hue ? after : Swift.min(Swift.max(after, 1), points.count - 1)
        let lo = at > 0 ? points[at - 1][0] + minGap : 0
        let hi = at < points.count ? points[at][0] - minGap : inputMax
        guard lo <= hi else { return nil }
        var out = points
        out.insert([input(Swift.min(hi, Swift.max(lo, p[0]))), output(p[1])], at: at)
        return (out, at)
    }

    /// The first point of a hue curve, with a flat anchor `seedSpread` degrees either side of it.
    func seeded(_ p: [Double]) -> (points: [[Double]], index: Int) {
        let h = wrapped(p[0])
        let point = [h, output(p[1])]
        let pts = ([point, [wrapped(h - Self.seedSpread), 0], [wrapped(h + Self.seedSpread), 0]]).sorted { $0[0] < $1[0] }
        return (pts, pts.firstIndex { $0 == point } ?? 0)
    }

    /// Point `i` removed, or nil when it cannot be (an RGB end point). A hue curve left with fewer than three
    /// points renders nothing, so it becomes the empty (flat) curve.
    public func removing(_ i: Int, from points: [[Double]]) -> [[Double]]? {
        guard canRemove(i, in: points) else { return nil }
        var out = points
        out.remove(at: i)
        return hue && out.count < 3 ? [] : out
    }

    /// Where Enter adds a point: the middle of the widest gap between neighbouring inputs (across 360 degrees too
    /// on a hue curve), on the curve. An empty hue curve gets its first point at 180 degrees.
    public func insertionPoint(_ points: [[Double]]) -> [Double] {
        guard points.count >= 2 else { return hue ? [180, 0] : [0.5, value(points, at: 0.5)] }
        var pairs = Array(zip(points.map { $0[0] }, points.dropFirst().map { $0[0] }))
        if hue, let first = points.first, let last = points.last { pairs.append((last[0], first[0] + 360)) }
        let widest = pairs.max { $0.1 - $0.0 < $1.1 - $1.0 } ?? (0, 1)
        let x = hue ? wrapped((widest.0 + widest.1) / 2) : Self.rounded((widest.0 + widest.1) / 2)
        return [x, output(value(points, at: x))]
    }

    // MARK: Units

    func output(_ y: Double) -> Double { Self.rounded(Swift.min(limit.upperBound, Swift.max(limit.lowerBound, y))) }

    /// An input at 1/1000, a hue also in the wrapped form the renderer reads (`GradeCurve.wrapHue`).
    func input(_ x: Double) -> Double { hue ? wrapped(x) : Self.rounded(x) }

    /// A hue in [0, 360) at 1/1000 degree (rounded first, so 359.9999 becomes 0, not a second point on 360), wrapped
    /// twice: the first wrap brings any hue into [0, 360), the second gives the value the renderer's wrap keeps.
    func wrapped(_ h: Double) -> Double { GradeCurve.wrapHue(GradeCurve.wrapHue(Self.rounded(h))) }

    static func rounded(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
