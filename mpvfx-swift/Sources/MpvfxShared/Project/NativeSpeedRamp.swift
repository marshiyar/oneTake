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
public struct NativeSpeedRamp: Codable, Equatable, Sendable {
    public static let version = 1
    public static let supportedKind = "speed-ramp"

    public struct Point: Codable, Equatable, Sendable {
        public var t: Double
        public var speed: Double
        public var ease: NativeInterpolation
        public var spread = NativeSpreadKeys()
        static let known = ["t", "speed", "ease"]

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

    public init(v: Int = version, kind: String = supportedKind, points: [Point]) {
        self.v = v; self.kind = kind; self.points = points
    }
    public var isSupported: Bool { v == Self.version && kind == Self.supportedKind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Int.self, "v"); kind = try c.req(String.self, "kind")
        points = try c.opt([Point].self, "points") ?? []
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { key, c in
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
        return points.last!.speed
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
    /// The same time map restricted to `[from, until)`, rebased so the new clip begins at zero.
    func sliced(from: Double, until: Double) -> NativeSpeedRamp {
        guard isSupported else { return self }
        var result = [Point(t: 0, speed: speed(atClipFrame: from))]
        result += points.filter { $0.t > from && $0.t < until }.map { Point(t: $0.t - from, speed: $0.speed, ease: $0.ease) }
        return NativeSpeedRamp(points: result)
    }
}
