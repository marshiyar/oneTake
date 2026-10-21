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

/// A versioned clip-local time map. Unknown versions and kinds deliberately decode and re-encode unchanged; callers
/// only evaluate `isSupported` ramps. `t` is a clip frame and `speed` is source frames per timeline frame.
public struct NativeSpeedRamp: Codable, Equatable, Hashable, Sendable {
    public static let version = 1
    public static let supportedKind = "speed-ramp"

    public struct Point: Codable, Equatable, Hashable, Sendable {
        public var t: Double
        public var speed: Double
        public var ease: NativeInterpolation
        public var spread = NativeSpreadKeys()
        static let known = ["t", "speed", "ease"]
        public func hash(into hasher: inout Hasher) {
            hasher.combine(t); hasher.combine(speed); hasher.combine(String(describing: ease))
        }

        public init(t: Double, speed: Double, ease: NativeInterpolation = .linear) {
            self.t = t; self.speed = speed; self.ease = ease
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
            t = try c.req(Double.self, "t"); speed = try c.req(Double.self, "speed")
            ease = try c.opt(NativeInterpolation.self, "ease") ?? .linear
            spread = try decodeSpread(decoder, known: Self.known)
        }
        public func encode(to encoder: Encoder) throws {
            try encodeSpread(encoder, spread, known: Self.known) { key, c in
                switch key { case "t": try c.put(t, key); case "speed": try c.put(speed, key); default: try c.put(ease, key) }
            }
        }
    }

    public var v: Int
    public var kind: String
    public var points: [Point]
    public var spread = NativeSpreadKeys()
    static let known = ["v", "kind", "points"]
    public func hash(into hasher: inout Hasher) {
        hasher.combine(v); hasher.combine(kind); hasher.combine(points)
    }

    public init(v: Int = version, kind: String = supportedKind, points: [Point]) {
        self.v = v; self.kind = kind; self.points = points
    }
    public var isSupported: Bool { v == Self.version && kind == Self.supportedKind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Int.self, "v"); kind = try c.req(String.self, "kind")
        // An object of another version or kind is kept verbatim in `spread` and never interpreted, whatever its shape.
        let supported = v == Self.version && kind == Self.supportedKind
        points = supported ? try c.opt([Point].self, "points") ?? [] : []
        spread = try decodeSpread(decoder, known: supported ? Self.known : ["v", "kind"])
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: isSupported ? Self.known : ["v", "kind"]) { key, c in
            switch key { case "v": try c.put(v, key); case "kind": try c.put(kind, key); default: try c.put(points, key) }
        }
    }

    /// Source-frame displacement from the clip's source-in at a clip-local timeline frame.
    public func sourcePosition(atClipFrame frame: Double) -> Double {
        guard isSupported, !points.isEmpty, frame > 0 else { return 0 }
        let end = max(0, frame)
        var position = 0.0
        var cursor = 0.0
        var speed = points[0].speed
        for i in points.indices {
            let point = points[i]
            if point.t > cursor {
                let stop = min(end, point.t)
                if stop > cursor { position += (stop - cursor) * speed }
                if end <= point.t { return position }
                cursor = point.t
            }
            speed = point.speed
            guard i + 1 < points.count else { continue }
            let next = points[i + 1]
            let stop = min(end, next.t)
            if stop > cursor {
                position += integrate(from: cursor, to: stop, segmentStart: point.t, segmentEnd: next.t,
                                      fromSpeed: point.speed, toSpeed: next.speed, ease: point.ease)
                cursor = stop
            }
            if end <= next.t { return position }
            speed = next.speed
        }
        if end > cursor { position += (end - cursor) * speed }
        return position
    }

    /// The clip-local frame whose mapped source displacement is `position`.
    public func clipFrame(atSourcePosition position: Double, durationFrames: Double) -> Double {
        guard position > 0 else { return 0 }
        var lo = 0.0, hi = max(0, durationFrames)
        if sourcePosition(atClipFrame: hi) <= position { return hi }
        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            if sourcePosition(atClipFrame: mid) < position { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    public func speed(atClipFrame frame: Double) -> Double {
        guard isSupported, let first = points.first else { return 1 }
        if frame <= first.t { return first.speed }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if frame <= b.t {
                let x = (frame - a.t) / (b.t - a.t)
                return a.speed + (b.speed - a.speed) * eased(x, a.ease)
            }
        }
        guard let last = points.last else { return 1 }
        return last.speed
    }
}

private func eased(_ x: Double, _ ease: NativeInterpolation) -> Double {
    let x = min(1, max(0, x))
    switch ease {
    case .hold: return 0
    case .linear: return x
    case .cubicBezier(let p):
        func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let m = (lo + hi) / 2; if curve(m, p.x1, p.x2) < x { lo = m } else { hi = m } }
        return curve((lo + hi) / 2, p.y1, p.y2)
    }
}

private func integrate(from: Double, to: Double, segmentStart: Double, segmentEnd: Double,
                       fromSpeed: Double, toSpeed: Double, ease: NativeInterpolation) -> Double {
    guard to > from, segmentEnd > segmentStart else { return 0 }
    // Composite Simpson integration is deterministic and comfortably below half-frame drift over long projects.
    let span = to - from
    let n = 32
    let h = span / Double(n)
    func value(_ t: Double) -> Double {
        let x = (t - segmentStart) / (segmentEnd - segmentStart)
        return fromSpeed + (toSpeed - fromSpeed) * eased(x, ease)
    }
    var sum = value(from) + value(to)
    for i in 1..<n { sum += (i.isMultiple(of: 2) ? 2 : 4) * value(from + Double(i) * h) }
    return sum * h / 3
}

public extension NativeSpeedRamp {
    /// The same time map restricted to `[from, until)`, rebased so the new clip begins at zero. The speed curve is
    /// preserved exactly: a cut inside an eased segment keeps the matching part of that segment's ease (a hold or
    /// linear ease as is, a cubic Bezier as the sub-curve of the same Bezier), and a point is added at the new end so
    /// the speed keeps ramping up to the cut instead of freezing at the last point inside it.
    func sliced(from: Double, until: Double) -> NativeSpeedRamp {
        guard isSupported, until > from else { return self }
        func segment(containing t: Double) -> Int? {
            for i in 0..<max(0, points.count - 1) where points[i].t <= t && t < points[i + 1].t { return i }
            return nil
        }
        /// The ease of segment `i` between its normalised positions `x0` and `x1`.
        func piece(_ i: Int, _ x0: Double, _ x1: Double) -> NativeInterpolation {
            switch points[i].ease {
            case .hold: return .hold
            case .linear: return .linear
            case .cubicBezier(let c): return subBezier(c, x0, x1).map { .cubicBezier($0) } ?? .linear
            }
        }
        func normalised(_ i: Int, _ t: Double) -> Double { (t - points[i].t) / (points[i + 1].t - points[i].t) }
        func outgoing(at t: Double, upTo end: Double) -> NativeInterpolation {
            guard let i = segment(containing: t) else { return .linear }
            return piece(i, normalised(i, t), min(1, normalised(i, end)))
        }
        var result = [Point(t: 0, speed: speed(atClipFrame: from), ease: outgoing(at: from, upTo: until))]
        for p in points where p.t > from && p.t < until {
            result.append(Point(t: p.t - from, speed: p.speed, ease: outgoing(at: p.t, upTo: until)))
        }
        if let last = result.last, last.t < until - from {
            result.append(Point(t: until - from, speed: speed(atClipFrame: until)))
        }
        return NativeSpeedRamp(points: result)
    }
}

/// The part of the Bezier ease `c` between normalised x positions `x0` and `x1`, rescaled to a full 0...1 ease
/// (de Casteljau subdivision at the parameters where the curve reaches those x values). Nil when the part is flat.
private func subBezier(_ c: CubicBezierControlPoints, _ x0: Double, _ x1: Double) -> CubicBezierControlPoints? {
    typealias P = (x: Double, y: Double)
    func lerp(_ a: P, _ b: P, _ t: Double) -> P { (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) }
    func parameter(_ x: Double) -> Double {
        func bx(_ t: Double) -> Double { let u = 1 - t; return 3 * u * u * t * c.x1 + 3 * u * t * t * c.x2 + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 { let m = (lo + hi) / 2; if bx(m) < x { lo = m } else { hi = m } }
        return (lo + hi) / 2
    }
    /// The curve's right part from parameter `t` on.
    func right(_ q: [P], _ t: Double) -> [P] {
        let a = lerp(q[0], q[1], t), b = lerp(q[1], q[2], t), d = lerp(q[2], q[3], t)
        let e = lerp(a, b, t), f = lerp(b, d, t)
        return [lerp(e, f, t), f, d, q[3]]
    }
    func left(_ q: [P], _ t: Double) -> [P] {
        let a = lerp(q[0], q[1], t), b = lerp(q[1], q[2], t), d = lerp(q[2], q[3], t)
        let e = lerp(a, b, t), f = lerp(b, d, t)
        return [q[0], a, e, lerp(e, f, t)]
    }
    let u0 = parameter(x0), u1 = parameter(x1)
    guard u1 > u0 else { return nil }
    let whole: [P] = [(0, 0), (c.x1, c.y1), (c.x2, c.y2), (1, 1)]
    var q = u1 < 1 ? left(whole, u1) : whole
    if u0 > 0 { q = right(q, u0 / max(u1, 1e-12)) }
    let dx = q[3].x - q[0].x, dy = q[3].y - q[0].y
    guard dx > 1e-9, abs(dy) > 1e-9 else { return nil }
    func n(_ p: P) -> P { ((p.x - q[0].x) / dx, (p.y - q[0].y) / dy) }
    let a = n(q[1]), b = n(q[2])
    return CubicBezierControlPoints(x1: a.x, y1: a.y, x2: b.x, y2: b.y)
}
