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

public extension CanvasPath {
    /// Current point (end of the last segment), or nil on an empty path.
    var currentPoint: CanvasPoint? {
        var start: CanvasPoint?, cur: CanvasPoint?
        for e in elements {
            switch e {
            case .move(let p): start = p; cur = p
            case .line(let p): cur = p
            case .curve(_, _, let p): cur = p
            case .close: cur = start
            }
        }
        return cur
    }

    /// Elliptical arc to `end` with SVG endpoint semantics (radii rx/ry, x-axis rotation 0), as cubic segments.
    mutating func arc(to end: CanvasPoint, rx: Double, ry: Double, largeArc: Bool, sweep: Bool) {
        guard let start = currentPoint else { move(to: end); return }
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 || (start.x == end.x && start.y == end.y) { line(to: end); return }
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let lambda = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = max(0, rx * rx * ry * ry - rx * rx * dy * dy - ry * ry * dx * dx)
        let den = rx * rx * dy * dy + ry * ry * dx * dx
        var k = den == 0 ? 0 : (num / den).squareRoot()
        if largeArc == sweep { k = -k }
        let cxp = k * rx * dy / ry, cyp = -k * ry * dx / rx
        let cx = cxp + (start.x + end.x) / 2, cy = cyp + (start.y + end.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
        }
        let theta1 = angle(1, 0, (dx - cxp) / rx, (dy - cyp) / ry)
        var delta = angle((dx - cxp) / rx, (dy - cyp) / ry, (-dx - cxp) / rx, (-dy - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var a = theta1
        for _ in 0..<segments {
            let b = a + step
            let p1 = CanvasPoint(cx + rx * (cos(a) - t * sin(a)), cy + ry * (sin(a) + t * cos(a)))
            let p2 = CanvasPoint(cx + rx * (cos(b) + t * sin(b)), cy + ry * (sin(b) - t * cos(b)))
            let p = CanvasPoint(cx + rx * cos(b), cy + ry * sin(b))
            curve(to: p, c1: p1, c2: p2)
            a = b
        }
    }
}

/// Transport, toolbar and menu glyphs, drawn in their source viewBox units (24 for the player icons,
/// 256 for the toolbar icons, 16 for the z-order menu glyphs).
public enum PlayerIcons {
    static func poly(_ pts: [(Double, Double)], close: Bool = false) -> CanvasPath {
        var p = CanvasPath(); p.move(to: .init(pts[0].0, pts[0].1)); for q in pts.dropFirst() { p.line(to: .init(q.0, q.1)) }
        if close { p.close() }; return p
    }

    /// Loop: M17 2l4 4-4 4 · M3 11V9a4 4 0 0 1 4-4h14 · M7 22l-4-4 4-4 · M21 13v2a4 4 0 0 1-4 4H3.
    public static var loop: [CanvasPath] {
        var top = CanvasPath(); top.move(to: .init(3, 11)); top.line(to: .init(3, 9))
        top.arc(to: .init(7, 5), rx: 4, ry: 4, largeArc: false, sweep: true); top.line(to: .init(21, 5))
        var bottom = CanvasPath(); bottom.move(to: .init(21, 13)); bottom.line(to: .init(21, 15))
        bottom.arc(to: .init(17, 19), rx: 4, ry: 4, largeArc: false, sweep: true); bottom.line(to: .init(3, 19))
        return [poly([(17, 2), (21, 6), (17, 10)]), top, poly([(7, 22), (3, 18), (7, 14)]), bottom]
    }

    /// Enter fullscreen corners (M8 3H5a2 2 0 0 0-2 2v3 …) or the inward exit corners (M8 3v3a2 2 0 0 1-2 2H3 …).
    public static func fullscreen(exit: Bool) -> [CanvasPath] {
        func corner(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double), sweep: Bool) -> CanvasPath {
            var p = CanvasPath(); p.move(to: .init(a.0, a.1)); p.line(to: .init(b.0, b.1))
            p.arc(to: .init(c.0, c.1), rx: 2, ry: 2, largeArc: false, sweep: sweep); p.line(to: .init(d.0, d.1)); return p
        }
        if exit {
            return [corner((8, 3), (8, 6), (6, 8), (3, 8), sweep: true), corner((21, 8), (18, 8), (16, 6), (16, 3), sweep: true),
                    corner((3, 16), (6, 16), (8, 18), (8, 21), sweep: true), corner((16, 21), (16, 18), (18, 16), (21, 16), sweep: true)]
        }
        return [corner((8, 3), (5, 3), (3, 5), (3, 8), sweep: false), corner((21, 8), (21, 5), (19, 3), (16, 3), sweep: false),
                corner((3, 16), (3, 19), (5, 21), (8, 21), sweep: false), corner((16, 21), (19, 21), (21, 19), (21, 16), sweep: false)]
    }

    /// Speaker M11 5 6 9H3v6h3l5 4V5Z with an X when silent, else the near wave (and the far one at ≥ 50 %).
    public static func volume(silent: Bool, level: Double) -> [CanvasPath] {
        var out = [poly([(11, 5), (6, 9), (3, 9), (3, 15), (6, 15), (11, 19), (11, 5)], close: true)]
        if silent { return out + [poly([(19, 9), (13, 15)]), poly([(13, 9), (19, 15)])] }
        var near = CanvasPath(); near.move(to: .init(15.5, 8.5)); near.arc(to: .init(15.5, 15.5), rx: 5, ry: 5, largeArc: false, sweep: true)
        out.append(near)
        if level >= 0.5 {
            var far = CanvasPath(); far.move(to: .init(18.5, 5.5)); far.arc(to: .init(18.5, 18.5), rx: 9, ry: 9, largeArc: false, sweep: true)
            out.append(far)
        }
        return out
    }

    /// Keyboard: rect x2 y4 w20 h16 rx2 and the space bar (stroke 1.75); `keyboardDots` are the round-capped keys.
    public static var keyboard: [CanvasPath] {
        [CanvasPath.roundedRect(CanvasRect(x: 2, y: 4, width: 20, height: 16), radius: 2), poly([(8, 16), (16, 16)])]
    }
    public static let keyboardDots: [CanvasPoint] = [8.0, 12.0].flatMap { y in [6.0, 10.0, 14.0, 18.0].map { CanvasPoint($0, y) } }

    /// Play triangle M56 28L88 49.5L56 71Z and pause bars M56 28H67V71H56Z M73 28H84V71H73Z share a coordinate
    /// space (viewBox 46 21 54 56); `t` (0 = play, 1 = pause) morphs one into the other as two quads.
    public static func playPause(_ t: Double) -> CanvasPath {
        let k = max(0, min(1, t))
        func mix(_ a: (Double, Double), _ b: (Double, Double)) -> CanvasPoint { CanvasPoint(a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k) }
        // The triangle split at x = 72 into a left quad and a right (degenerate) quad.
        let playL = [(56.0, 28.0), (72.0, 38.75), (72.0, 60.25), (56.0, 71.0)]
        let playR = [(72.0, 38.75), (88.0, 49.5), (88.0, 49.5), (72.0, 60.25)]
        let pauseL = [(56.0, 28.0), (67.0, 28.0), (67.0, 71.0), (56.0, 71.0)]
        let pauseR = [(73.0, 28.0), (84.0, 28.0), (84.0, 71.0), (73.0, 71.0)]
        var p = CanvasPath()
        for (a, b) in [(playL, pauseL), (playR, pauseR)] {
            p.move(to: mix(a[0], b[0])); for i in 1..<4 { p.line(to: mix(a[i], b[i])) }; p.close()
        }
        return p
    }

    /// Phosphor GridFour (256 box): rounded square with a centre cross; `fill` shades the four cells.
    public static func gridFour(fill: Bool) -> (stroke: [CanvasPath], fill: [CanvasPath]) {
        let outer = CanvasPath.roundedRect(CanvasRect(x: 40, y: 40, width: 176, height: 176), radius: 16)
        if fill {
            let cells = [CanvasRect(x: 40, y: 40, width: 80, height: 80), CanvasRect(x: 136, y: 40, width: 80, height: 80),
                         CanvasRect(x: 40, y: 136, width: 80, height: 80), CanvasRect(x: 136, y: 136, width: 80, height: 80)]
            return ([], cells.map { CanvasPath.roundedRect($0, radius: 12) })
        }
        return ([outer, poly([(128, 40), (128, 216)]), poly([(40, 128), (216, 128)])], [])
    }

    /// Phosphor MagnetStraight (256 box): a U magnet with its two pole caps.
    public static func magnet(fill: Bool) -> (stroke: [CanvasPath], fill: [CanvasPath]) {
        var u = CanvasPath()
        u.move(to: .init(48, 40)); u.line(to: .init(48, 136))
        u.arc(to: .init(208, 136), rx: 80, ry: 80, largeArc: false, sweep: false)
        u.line(to: .init(208, 40)); u.line(to: .init(160, 40)); u.line(to: .init(160, 136))
        u.arc(to: .init(96, 136), rx: 32, ry: 32, largeArc: false, sweep: true)
        u.line(to: .init(96, 40)); u.close()
        let caps = [poly([(48, 88), (96, 88)]), poly([(160, 88), (208, 88)])]
        return fill ? ([], [u]) : ([u] + caps, [])
    }

    /// CanvasContextMenu z-order glyphs (16 box, stroke 1.2).
    public static func zOrder(_ action: StageZOrderAction) -> [CanvasPath] {
        func diamond(_ y: Double) -> CanvasPath { poly([(3, y), (8, y - 2.5), (13, y), (8, y + 2.5)], close: true) }
        switch action {
        case .bringForward: return [diamond(11), poly([(8, 8.5), (8, 2)]), poly([(5.5, 4.5), (8, 2), (10.5, 4.5)])]
        case .sendBackward: return [diamond(5), poly([(8, 7.5), (8, 14)]), poly([(5.5, 11.5), (8, 14), (10.5, 11.5)])]
        case .bringToFront: return [diamond(9.5), diamond(12.5), poly([(8, 12.5), (8, 2)]), poly([(5.5, 4.5), (8, 2), (10.5, 4.5)])]
        case .sendToBack: return [diamond(4), diamond(7), poly([(8, 3.5), (8, 14)]), poly([(5.5, 11.5), (8, 14), (10.5, 11.5)])]
        }
    }

    /// Fit-reset corners: M6 2H2v4 M10 2h4v4 M2 10v4h4 M14 10v4h-4 (16 box, stroke 1.5).
    public static var fitCorners: [CanvasPath] {
        [poly([(6, 2), (2, 2), (2, 6)]), poly([(10, 2), (14, 2), (14, 6)]), poly([(2, 10), (2, 14), (6, 14)]), poly([(14, 10), (14, 14), (10, 14)])]
    }

    /// Draws `paths` from a `box`-unit viewBox into `rect` (stroked at `width` box units).
    public static func stroke(_ c: CanvasContext, _ paths: [CanvasPath], in rect: CanvasRect, box: Double, color: CanvasColor, width: Double) {
        c.withState {
            c.translate(rect.x, rect.y); c.scale(rect.width / box, rect.height / box)
            for p in paths { c.stroke(p, color, StrokeStyle(width: width)) }
        }
    }
    public static func fill(_ c: CanvasContext, _ paths: [CanvasPath], in rect: CanvasRect, box: Double, color: CanvasColor) {
        c.withState {
            c.translate(rect.x, rect.y); c.scale(rect.width / box, rect.height / box)
            for p in paths { c.fill(p, color) }
        }
    }
}

/// CanvasContextMenu z actions.
public enum StageZOrderAction: CaseIterable, Equatable, Sendable {
    case bringToFront, bringForward, sendBackward, sendToBack
    public var label: String {
        switch self {
        case .bringToFront: "Bring to front"; case .bringForward: "Bring forward"
        case .sendBackward: "Send backward"; case .sendToBack: "Send to back"
        }
    }
}
