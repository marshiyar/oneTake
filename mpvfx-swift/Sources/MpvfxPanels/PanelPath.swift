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

/// SVG path data (`d`) → `CanvasPath`, so panel icons draw recorded vector geometry: inline `<path d>` data
/// and the Phosphor outlines. Supports every command (M L H V C S Q T A Z,
/// absolute and relative); quadratics are raised to cubics and arcs split into ≤90° cubic segments.
public struct PanelSVGPath: Sendable {
    public private(set) var path = CanvasPath()
    /// End points of every segment, in view-box units mapped to the destination: where a round line cap/join sits.
    public private(set) var vertices: [CanvasPoint] = []

    public init(_ d: String, viewBox: Double, into box: CanvasRect) {
        let s = min(box.width, box.height) / viewBox
        let ox = box.x + (box.width - viewBox * s) / 2, oy = box.y + (box.height - viewBox * s) / 2
        func map(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(ox + x * s, oy + y * s) }
        var tokens = Self.tokenize(d)
        var i = 0, cmd: Character = "M"
        var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
        var lastCubic: (Double, Double)?, lastQuad: (Double, Double)?
        func isNum(_ t: String) -> Bool { Double(t) != nil }
        func num() -> Double { defer { i += 1 }; return i < tokens.count ? Double(tokens[i]) ?? 0 : 0 }
        func flag() -> Bool {   // arc flags may be packed: "a2 2 0 01-2 2" → large 0, sweep 1, x -2
            guard i < tokens.count else { return false }
            let t = tokens[i]
            if t.count > 1, let f = t.first, f == "0" || f == "1" { tokens[i] = String(t.dropFirst()); return f == "1" }
            i += 1; return (Double(t) ?? 0) != 0
        }
        func cubic(_ c1: (Double, Double), _ c2: (Double, Double), _ e: (Double, Double)) {
            path.curve(to: map(e.0, e.1), c1: map(c1.0, c1.1), c2: map(c2.0, c2.1)); vertices.append(map(e.0, e.1))
        }
        while i < tokens.count {
            if let ch = tokens[i].first, !isNum(tokens[i]) { cmd = ch; i += 1 }
            let rel = cmd.isLowercase
            let bx = rel ? x : 0, by = rel ? y : 0
            var nextCubic: (Double, Double)?, nextQuad: (Double, Double)?
            switch cmd.uppercased().first! {
            case "M":
                x = bx + num(); y = by + num(); sx = x; sy = y
                path.move(to: map(x, y)); vertices.append(map(x, y))
                cmd = rel ? "l" : "L"
            case "L": x = bx + num(); y = by + num(); path.line(to: map(x, y)); vertices.append(map(x, y))
            case "H": x = bx + num(); path.line(to: map(x, y)); vertices.append(map(x, y))
            case "V": y = by + num(); path.line(to: map(x, y)); vertices.append(map(x, y))
            case "C":
                let c1 = (bx + num(), by + num()), c2 = (bx + num(), by + num()), e = (bx + num(), by + num())
                cubic(c1, c2, e); x = e.0; y = e.1; nextCubic = c2
            case "S":
                let c1 = lastCubic.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y)
                let c2 = (bx + num(), by + num()), e = (bx + num(), by + num())
                cubic(c1, c2, e); x = e.0; y = e.1; nextCubic = c2
            case "Q", "T":
                let q: (Double, Double)
                if cmd.uppercased() == "Q" { q = (bx + num(), by + num()) } else { q = lastQuad.map { (2 * x - $0.0, 2 * y - $0.1) } ?? (x, y) }
                let e = (bx + num(), by + num())
                cubic((x + 2 / 3 * (q.0 - x), y + 2 / 3 * (q.1 - y)), (e.0 + 2 / 3 * (q.0 - e.0), e.1 + 2 / 3 * (q.1 - e.1)), e)
                x = e.0; y = e.1; nextQuad = q
            case "A":
                let rx = num(), ry = num(), rot = num(), large = flag(), sweep = flag()
                let e = (bx + num(), by + num())
                for seg in Self.arcToCubics(x, y, rx, ry, rot, large, sweep, e.0, e.1) { cubic(seg.0, seg.1, seg.2) }
                if rx == 0 || ry == 0 { path.line(to: map(e.0, e.1)); vertices.append(map(e.0, e.1)) }
                x = e.0; y = e.1
            case "Z":
                path.close(); x = sx; y = sy
            default: i += 1
            }
            lastCubic = nextCubic; lastQuad = nextQuad
        }
    }

    static func tokenize(_ d: String) -> [String] {
        var out: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        var prev: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); out.append(String(ch)) }
            else if ch == "," || ch.isWhitespace { flush() }
            else if ch == "-" && prev != "e" && prev != "E" { flush(); cur = "-" }
            else if ch == "." && cur.contains(".") { flush(); cur = "." }
            else { cur.append(ch) }
            prev = ch
        }
        flush()
        return out
    }

    /// SVG endpoint arc → cubic segments (each ≤ 90°), per the SVG implementation notes (F.6.5).
    static func arcToCubics(_ x1: Double, _ y1: Double, _ rxIn: Double, _ ryIn: Double, _ rotDeg: Double, _ large: Bool, _ sweep: Bool,
                            _ x2: Double, _ y2: Double) -> [((Double, Double), (Double, Double), (Double, Double))] {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, x1 != x2 || y1 != y2 else { return [] }
        let phi = rotDeg * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy
        let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lam > 1 { rx *= lam.squareRoot(); ry *= lam.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var k = (max(0, num) / den).squareRoot()
        if large == sweep { k = -k }
        let cxp = k * rx * y1p / ry, cyp = -k * ry * x1p / rx
        let cx = cp * cxp - sp * cyp + (x1 + x2) / 2, cy = sp * cxp + cp * cyp + (y1 + y2) / 2
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
        }
        let t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let n = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up)))
        let step = dt / Double(n), alpha = 4 / 3 * tan(step / 4)
        func pt(_ t: Double) -> (Double, Double) { (cx + rx * cos(t) * cp - ry * sin(t) * sp, cy + rx * cos(t) * sp + ry * sin(t) * cp) }
        func der(_ t: Double) -> (Double, Double) { (-rx * sin(t) * cp - ry * cos(t) * sp, -rx * sin(t) * sp + ry * cos(t) * cp) }
        var out: [((Double, Double), (Double, Double), (Double, Double))] = []
        var t = t1
        for _ in 0..<n {
            let p0 = pt(t), d0 = der(t), t2 = t + step, p3 = pt(t2), d3 = der(t2)
            out.append(((p0.0 + alpha * d0.0, p0.1 + alpha * d0.1), (p3.0 - alpha * d3.0, p3.1 - alpha * d3.1), p3))
            t = t2
        }
        return out
    }
}

public extension CanvasContext {
    /// Fills SVG path data mapped from a square `viewBox` into `box` (Phosphor glyphs, filled markup paths).
    func fillSVG(_ d: [String], viewBox: Double, in box: CanvasRect, _ color: CanvasColor) {
        for p in d { fill(PanelSVGPath(p, viewBox: viewBox, into: box).path, color) }
    }

    /// Strokes SVG path data like `stroke-linecap/linejoin: round` markup: the stroke, plus a round dot at every
    /// segment end (the canvas strokes with butt caps and miter joins). `width` is in view-box units.
    func strokeSVG(_ d: [String], viewBox: Double, in box: CanvasRect, _ color: CanvasColor, width: Double, round: Bool = true) {
        let s = min(box.width, box.height) / viewBox
        for p in d {
            let sp = PanelSVGPath(p, viewBox: viewBox, into: box)
            stroke(sp.path, color, StrokeStyle(width: width * s))
            if round {
                let r = width * s / 2
                for v in sp.vertices { fill(PanelSVGPath.dot(v, r), color) }
            }
        }
    }
}

extension PanelSVGPath {
    static func dot(_ c: CanvasPoint, _ r: Double) -> CanvasPath {
        var p = CanvasPath(); let k = 0.5522847498 * r
        p.move(to: CanvasPoint(c.x + r, c.y))
        p.curve(to: CanvasPoint(c.x, c.y + r), c1: CanvasPoint(c.x + r, c.y + k), c2: CanvasPoint(c.x + k, c.y + r))
        p.curve(to: CanvasPoint(c.x - r, c.y), c1: CanvasPoint(c.x - k, c.y + r), c2: CanvasPoint(c.x - r, c.y + k))
        p.curve(to: CanvasPoint(c.x, c.y - r), c1: CanvasPoint(c.x - r, c.y - k), c2: CanvasPoint(c.x - k, c.y - r))
        p.curve(to: CanvasPoint(c.x + r, c.y), c1: CanvasPoint(c.x + k, c.y - r), c2: CanvasPoint(c.x + r, c.y - k))
        p.close(); return p
    }
}
