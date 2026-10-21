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
// Layer moves: the kinds, their formulas, and the one pure function that turns (clip, clip frame) into the
// offsets preview and export apply over the clip's own (static or keyframed) values.
//
// Combining: position adds (dx, dy in canvas px), scale multiplies, rotation adds (degrees, clockwise), opacity
// multiplies. In, Out and Loop combine with each other the same way.
//
// Timing, for a clip of D frames, at clip frame f (0 … D-1):
//   In of F frames:   t = min(f, F) / F,              e = ease(t), away weight w = 1 - e   (f ≥ F: w = 0)
//   Out of F frames:  t = min(f - (D-1-F), F) / F,    e = ease(t), away weight w = e       (f < D-1-F: w = 0)
//   So an In is fully away at the first frame and at rest F frames later; an Out leaves rest F frames before the
//   last frame and is fully away on it.
//   Loop of period P (even), half h = P/2:  k = f / h (whole halves), s = (f - k·h) / h, e = ease(s),
//   phase u = e on even halves and 1 - e on odd ones: 0 → 1 → 0 … with the ease on every half, so one key per
//   half period with the same ease reproduces it exactly.
//   `ease(x)` is the keyframe engine's interpolation: the value at frame x·span of a two-key track 0 → 1 whose first
//   key's outgoing interpolation is the move's ease (`nativeMoveEasedProgress`).
//
// In and Out kinds, W × H the canvas, a the amount, w the away weight:
//   slide  (a % of the frame, default 100, 0 < a ≤ 200; direction left|right|up|down, default left)
//          left: dx = -a/100·W·w   right: dx = +a/100·W·w   up: dy = -a/100·H·w   down: dy = +a/100·H·w
//          In comes from that edge, Out goes to it. No fade.
//   rise   (a % of the frame height, default 10, 0 < a ≤ 100) moves up while it plays, with a fade:
//          In: dy = +a/100·H·w (from below)    Out: dy = -a/100·H·w (up and away)    opacity = 1 - w
//   drop   (as rise) moves down while it plays: In: dy = -a/100·H·w    Out: dy = +a/100·H·w    opacity = 1 - w
//   grow   (a % of scale, default 40, 0 < a ≤ 100) grows while it plays, with a fade:
//          In: scale = 1 - a/100·w (from smaller)    Out: scale = 1 + a/100·w (to larger)    opacity = 1 - w
//   shrink (as grow) shrinks while it plays: In: scale = 1 + a/100·w    Out: scale = 1 - a/100·w    opacity = 1 - w
//   spin   (a degrees, default 90, a ≠ 0, |a| ≤ 3600; positive turns clockwise while it plays), with a fade:
//          In: rotation = -a·w    Out: rotation = +a·w    opacity = 1 - w
//
// Loop kinds, u the loop phase:
//   float  (a % of the frame height, default 2, 0 < a ≤ 100)   dy = -a/100·H·u                  (bobs up)
//   pulse  (a % of scale, default 5, 0 < a ≤ 100)              scale = 1 + a/100·u              (breathes)
//   sway   (a degrees, default 3, 0 < a ≤ 180)                 rotation = a·(2u - 1)            (-a … +a)
//   drift  (a %, default 5, 0 < a ≤ 100)                       dx = a/100·W·u, scale = 1 + a/100·u (pan and zoom)
import Foundation

/// The In and Out kinds.
public enum NativeEdgeMoveKind: String, CaseIterable, Sendable {
    case slide, rise, drop, grow, shrink, spin

    public var defaultAmount: Double {
        switch self { case .slide: 100; case .rise, .drop: 10; case .grow, .shrink: 40; case .spin: 90 }
    }
    /// Accepted amounts: slide 0 < a ≤ 200, rise/drop/grow/shrink 0 < a ≤ 100, spin a ≠ 0 and |a| ≤ 3600.
    public func accepts(amount a: Double) -> Bool {
        guard a.isFinite else { return false }
        switch self {
        case .slide: return a > 0 && a <= 200
        case .rise, .drop, .grow, .shrink: return a > 0 && a <= 100
        case .spin: return a != 0 && abs(a) <= 3600
        }
    }
    /// A direction picks the edge a Slide enters from or leaves by; the other kinds move on a fixed axis.
    public var takesDirection: Bool { self == .slide }
    /// Every kind but Slide fades in or out with its motion.
    public var fades: Bool { self != .slide }
}

/// The Loop kinds.
public enum NativeLoopMoveKind: String, CaseIterable, Sendable {
    case float, pulse, sway, drift

    public var defaultAmount: Double {
        switch self { case .float: 2; case .pulse: 5; case .sway: 3; case .drift: 5 }
    }
    /// Accepted amounts: sway 0 < a ≤ 180 degrees, the others 0 < a ≤ 100 percent.
    public func accepts(amount a: Double) -> Bool {
        a.isFinite && a > 0 && a <= (self == .sway ? 180 : 100)
    }
}

/// The edge a Slide comes from (In) or goes to (Out).
public enum NativeMoveDirection: String, CaseIterable, Sendable { case left, right, up, down }

/// What a clip's moves add to it at one frame: position adds, scale and opacity multiply, rotation adds.
public struct NativeMoveOffsets: Equatable, Sendable {
    public var dx = 0.0, dy = 0.0
    public var scale = 1.0
    /// Degrees, clockwise.
    public var rotation = 0.0
    public var opacity = 1.0
    public static let identity = NativeMoveOffsets()
    public var isIdentity: Bool { self == .identity }
    /// What undoes these offsets (a scale of 0 cannot be undone and stays 1).
    public var inverted: NativeMoveOffsets {
        NativeMoveOffsets(dx: -dx, dy: -dy, scale: scale != 0 ? 1 / scale : 1, rotation: -rotation)
    }

    /// Both offsets applied: position and rotation add, scale and opacity multiply.
    public func combined(with o: NativeMoveOffsets) -> NativeMoveOffsets {
        NativeMoveOffsets(dx: dx + o.dx, dy: dy + o.dy, scale: scale * o.scale, rotation: rotation + o.rotation, opacity: opacity * o.opacity)
    }
}

// MARK: Formulas

extension NativeEdgeMove {
    /// The move's offset at away weight `w` (0 at rest, 1 fully away) on `edge`, for the canvas's width × height.
    public func offsets(edge: NativeMoveEdge, weight w: Double, canvas: NativeCanvas) -> NativeMoveOffsets {
        var o = motion(edge: edge, weight: w, canvas: canvas)
        if kind.fades { o.opacity = 1 - w }
        return o
    }

    private func motion(edge: NativeMoveEdge, weight w: Double, canvas: NativeCanvas) -> NativeMoveOffsets {
        let towardIn: Double = edge == .in ? 1 : -1   // the In's away side is the opposite of the Out's
        let a = resolvedAmount
        switch kind {
        case .slide: return Self.slide(resolvedDirection, a / 100 * w, canvas)
        case .rise: return NativeMoveOffsets(dy: towardIn * a / 100 * canvas.height * w)
        case .drop: return NativeMoveOffsets(dy: -towardIn * a / 100 * canvas.height * w)
        case .grow: return NativeMoveOffsets(scale: 1 - towardIn * a / 100 * w)
        case .shrink: return NativeMoveOffsets(scale: 1 + towardIn * a / 100 * w)
        case .spin: return NativeMoveOffsets(rotation: -towardIn * a * w)
        }
    }

    private static func slide(_ d: NativeMoveDirection, _ fraction: Double, _ canvas: NativeCanvas) -> NativeMoveOffsets {
        switch d {
        case .left: NativeMoveOffsets(dx: -fraction * canvas.width)
        case .right: NativeMoveOffsets(dx: fraction * canvas.width)
        case .up: NativeMoveOffsets(dy: -fraction * canvas.height)
        case .down: NativeMoveOffsets(dy: fraction * canvas.height)
        }
    }
}

extension NativeLoopMoveKind {
    /// The kind's offset at loop phase `u` (0 … 1) for a `width` × `height` canvas.
    public func offsets(phase u: Double, amount a: Double, canvas: NativeCanvas) -> NativeMoveOffsets {
        switch self {
        case .float: NativeMoveOffsets(dy: -a / 100 * canvas.height * u)
        case .pulse: NativeMoveOffsets(scale: 1 + a / 100 * u)
        case .sway: NativeMoveOffsets(rotation: a * (2 * u - 1))
        case .drift: NativeMoveOffsets(dx: a / 100 * canvas.width * u, scale: 1 + a / 100 * u)
        }
    }
}

// MARK: Evaluation

/// The keyframe engine's eased progress for a segment of `span` frames at segment frame `frame` (0 … span): the
/// value of a two-key number track, 0 at frame 0 with `ease` as its outgoing interpolation, 1 at frame `span`.
public func nativeMoveEasedProgress(_ ease: NativeInterpolation, frame: Int, span: Int, engine: KeyframeEngine) throws -> Double {
    guard span > 0 else { return 1 }
    let k = max(0, min(span, frame))
    if k == 0 { return 0 }
    if k == span { return 1 }
    let track = KeyframeTrack(valueType: .number, keyframes: [
        .init(frame: 0, value: .number(0), outgoing: ease), .init(frame: Double(span), value: .number(1), outgoing: .linear),
    ])
    guard case .number(let v) = try engine.evaluate(track, frame: Double(k)) else {
        throw KeyframeEngineError(code: KeyframeTrackErrorCode.invalidValue.rawValue, message: "The keyframe engine eased a number track to a non-number")
    }
    return v
}

/// What the clip's moves add to it at clip frame `clipFrame` (0 = its first frame): identity when it has none or
/// when they are from a newer version (kept, not drawn). Throws only when the keyframe engine fails or is missing.
public func nativeClipMoveOffsets(_ clip: NativeProjectClip, clipFrame: Int, canvas: NativeCanvas,
                                  engine: KeyframeEngine? = nil) throws -> NativeMoveOffsets {
    guard let moves = clip.moves, moves.isCurrentVersion, !moves.isEmpty else { return .identity }
    let duration = Int(clip.durationFrames)
    let eng = try engine ?? keyframeEngine()
    var out = NativeMoveOffsets.identity
    for edge in NativeMoveEdge.allCases {
        guard let move = moves.edgeMove(edge),
              let w = try move.weight(edge: edge, clipFrame: clipFrame, duration: duration, engine: eng) else { continue }
        out = out.combined(with: move.offsets(edge: edge, weight: w, canvas: canvas))
    }
    if let loop = moves.loop {
        let u = try nativeLoopMovePhase(loop, clipFrame: clipFrame, engine: eng)
        out = out.combined(with: loop.kind.offsets(phase: u, amount: loop.resolvedAmount, canvas: canvas))
    }
    return out
}

extension NativeEdgeMove {
    /// The away weight of this In or Out at `clipFrame` of a `duration`-frame clip, nil outside the move (at rest).
    public func weight(edge: NativeMoveEdge, clipFrame f: Int, duration: Int, engine: KeyframeEngine) throws -> Double? {
        let span = max(1, frames)
        let k = edge == .in ? f : f - (duration - 1 - span)
        if edge == .in ? k >= span : k <= 0 { return nil }
        let e = try nativeMoveEasedProgress(resolvedEase(edge), frame: k, span: span, engine: engine)
        return edge == .in ? 1 - e : e
    }
}

/// The loop phase u (0 … 1) at `clipFrame`: eased 0 → 1 on even half periods, 1 → 0 on odd ones.
public func nativeLoopMovePhase(_ loop: NativeLoopMove, clipFrame f: Int, engine: KeyframeEngine) throws -> Double {
    let half = max(1, loop.periodFrames / 2)
    let k = max(0, f) / half, s = max(0, f) - k * half
    let e = try nativeMoveEasedProgress(loop.resolvedEase, frame: s, span: half, engine: engine)
    return k % 2 == 0 ? e : 1 - e
}
