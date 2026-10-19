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
import MpvfxTheme

public extension CanvasColor {
    init(_ t: ThemeColor) { self.init(r: t.r, g: t.g, b: t.b, a: t.a) }
}

/// Icon path data in the original markup's `d` syntax (M/L/H/V/C/Z, absolute and relative), mapped from its
/// viewBox into a destination box, so toolbar glyphs are the TSX's own geometry rather than redrawn guesses.
public enum TimelineIconPath {
    public static func parse(_ d: String, viewBox: Double, into box: CanvasRect) -> CanvasPath {
        let s = box.width / viewBox
        func map(_ x: Double, _ y: Double) -> CanvasPoint { .init(box.x + x * s, box.y + y * s) }
        var tokens: [String] = []; var cur = ""
        func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }
        for ch in d {
            if ch.isLetter && ch != "e" { flush(); tokens.append(String(ch)) }
            else if ch == "," || ch == " " || ch == "\n" { flush() }
            else if ch == "-" && !cur.isEmpty && !cur.hasSuffix("e") { flush(); cur = "-" }
            else if ch == "." && cur.contains(".") { flush(); cur = "." }
            else { cur.append(ch) }
        }
        flush()
        var p = CanvasPath(); var i = 0; var cmd = "M"
        var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
        func num() -> Double { defer { i += 1 }; return Double(tokens[i]) ?? 0 }
        func hasNum() -> Bool { i < tokens.count && Double(tokens[i]) != nil }
        while i < tokens.count {
            if !hasNum() { cmd = tokens[i]; i += 1; if cmd == "Z" || cmd == "z" { p.close(); x = sx; y = sy; continue } }
            let rel = cmd == cmd.lowercased()
            switch cmd.uppercased() {
            case "M":
                let a = num(), b = num(); x = rel ? x + a : a; y = rel ? y + b : b; sx = x; sy = y
                p.move(to: map(x, y)); cmd = rel ? "l" : "L"
            case "L": let a = num(), b = num(); x = rel ? x + a : a; y = rel ? y + b : b; p.line(to: map(x, y))
            case "H": let a = num(); x = rel ? x + a : a; p.line(to: map(x, y))
            case "V": let b = num(); y = rel ? y + b : b; p.line(to: map(x, y))
            case "C":
                var v = (0..<6).map { _ in num() }
                if rel { v = [v[0] + x, v[1] + y, v[2] + x, v[3] + y, v[4] + x, v[5] + y] }
                p.curve(to: map(v[4], v[5]), c1: map(v[0], v[1]), c2: map(v[2], v[3])); x = v[4]; y = v[5]
            default: i += 1
            }
        }
        return p
    }

    /// Circle as four cubic arcs.
    public static func circle(_ c: CanvasPoint, r: Double) -> CanvasPath {
        TimelineView.ellipse(CanvasRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}
