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
import MpvfxCanvas
import MpvfxShared
import MpvfxTheme

/// The shape of a keyframe mark. Each kind of property has its own, so a key is never read as another property's,
/// with or without colour.
public enum TimelineKeyframeShape: String, CaseIterable, Sendable { case diamond, hexagon, circle, triangle, star, square }

/// How a key leaves for the next one (its outgoing interpolation), drawn as a variant of the mark:
/// linear filled, ease half filled (left half solid, the outline whole), hold square-ended (the right half a flat bar).
public enum TimelineKeyframeEase: String, CaseIterable, Sendable {
    case linear, ease, hold
    public init(_ i: NativeInterpolation?) {
        switch i { case .hold?: self = .hold; case .cubicBezier?: self = .ease; default: self = .linear }
    }
}

public extension TimelineKeyframeKind {
    var shape: TimelineKeyframeShape {
        switch self {
        case .transform: .diamond
        case .threeD: .hexagon
        case .opacity: .circle
        case .color: .triangle
        case .effect: .star
        case .audio: .square
        }
    }

    /// The kind's colour token (read at draw time, so a live appearance switch reaches it).
    var colorPair: ThemePair {
        switch self {
        case .transform: ThemeTokens.keyframeTransformPair
        case .threeD: ThemeTokens.keyframe3DPair
        case .opacity: ThemeTokens.keyframeOpacityPair
        case .color: ThemeTokens.keyframeColorPair
        case .effect: ThemeTokens.keyframeEffectPair
        case .audio: ThemeTokens.keyframeAudioPair
        }
    }

    var color: CanvasColor { CanvasColor(colorPair.now) }
}

/// Paths and drawing of keyframe marks, shared by the timeline lanes, the inspector rows and the shortcuts legend.
public enum TimelineKeyframeGlyph {
    /// The outline of `shape` centred on (cx, cy) inside a square of half-size `r`.
    public static func path(_ shape: TimelineKeyframeShape, cx: Double, cy: Double, r: Double) -> CanvasPath {
        switch shape {
        case .diamond: return polygon(cx, cy, [(0, -r), (r, 0), (0, r), (-r, 0)])
        case .square: let s = r * 0.8; return polygon(cx, cy, [(-s, -s), (s, -s), (s, s), (-s, s)])
        case .circle: let s = r * 0.85; return .roundedRect(CanvasRect(x: cx - s, y: cy - s, width: 2 * s, height: 2 * s), radius: s)
        case .triangle: return polygon(cx, cy, [(0, -r), (r, r * 0.8), (-r, r * 0.8)])
        case .hexagon: return polygon(cx, cy, (0..<6).map { k in let a = Double(k) * .pi / 3; return (r * cos(a), r * sin(a)) })
        case .star:
            return polygon(cx, cy, (0..<10).map { k in
                let a = -Double.pi / 2 + Double(k) * .pi / 5, rr = k % 2 == 0 ? r : r * 0.45
                return (rr * cos(a), rr * sin(a))
            })
        }
    }

    static func polygon(_ cx: Double, _ cy: Double, _ pts: [(Double, Double)]) -> CanvasPath {
        var p = CanvasPath()
        for (i, q) in pts.enumerated() {
            let pt = CanvasPoint(cx + q.0, cy + q.1)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        return p
    }

    /// How one mark looks: its shape and colour, its interpolation variant, and a ring when it is selected.
    public struct Style: Equatable, Sendable {
        public var shape: TimelineKeyframeShape, ease: TimelineKeyframeEase, color: CanvasColor, ring: CanvasColor?
        public init(shape: TimelineKeyframeShape, ease: TimelineKeyframeEase = .linear, color: CanvasColor, ring: CanvasColor? = nil) {
            self.shape = shape; self.ease = ease; self.color = color; self.ring = ring
        }
        /// A kind's mark in the kind's colour.
        public init(_ kind: TimelineKeyframeKind, ease: TimelineKeyframeEase = .linear, ring: CanvasColor? = nil) {
            self.init(shape: kind.shape, ease: ease, color: kind.color, ring: ring)
        }
    }

    /// One mark centred on `p` with fill half-size `r`; a selected mark gets its ring 2.5 px outside.
    public static func draw(_ c: CanvasContext, _ style: Style, at p: CanvasPoint, r: Double) {
        let cx = p.x, cy = p.y, color = style.color
        let outline = path(style.shape, cx: cx, cy: cy, r: r)
        if let ring = style.ring { c.stroke(path(style.shape, cx: cx, cy: cy, r: r + 2.5), ring, StrokeStyle(width: 1.5)) }
        switch style.ease {
        case .linear:
            c.fill(outline, color)
        case .ease:
            c.withState { c.clip(CanvasRect(x: cx - r - 1, y: cy - r - 1, width: r + 1, height: 2 * r + 2)); c.fill(outline, color) }
            c.stroke(outline, color, StrokeStyle(width: max(1, r * 0.18)))
        case .hold:
            c.withState { c.clip(CanvasRect(x: cx - r - 1, y: cy - r - 1, width: r + 1, height: 2 * r + 2)); c.fill(outline, color) }
            c.fillRect(CanvasRect(x: cx, y: cy - r * 0.35, width: r, height: r * 0.7), color)
        }
    }

    /// The outline only (the inspector's ◇ and a lane row's ◇ away from a key), in the style's shape and colour.
    public static func drawOutline(_ c: CanvasContext, _ style: Style, at p: CanvasPoint, r: Double) {
        c.stroke(path(style.shape, cx: p.x, cy: p.y, r: r), style.color, StrokeStyle(width: max(1, r * 0.22)))
    }
}
