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

/// The pixel half of a text reveal: from the picture of the whole text (straight-alpha RGBA8, drawn once by the
/// platform's text stack) it builds one frame, taking each atom's pixels at the opacity, offset and size the plan gives
/// them. It only moves pixels, so every canvas backend gets the same frame, in preview and in export.
///
/// An atom owns the pixels whose centre lies in one of its regions. Regions of neighbouring letters tile the line
/// without overlap or gap, so every pixel of the text belongs to exactly one atom.
enum TextRevealCompositor {
    /// One atom: where its pixels are in the source picture, and what happens to them.
    struct Atom {
        var regions: [CanvasRect]
        var opacity: Double
        var moves: [TextRevealPlan.Move]
        var isIdentity: Bool { opacity == 1 && moves.isEmpty }
    }

    /// The frame for `atoms`, the size of `source`. `cursor` (pixels) is added in `cursorColor` (straight RGBA8) when set.
    /// `showsAll` skips the atoms and starts from a copy of `source`: nothing is hidden or moving.
    static func compose(source: [UInt8], width: Int, height: Int, atoms: [Atom], showsAll: Bool,
                        cursor: CanvasRect?, cursorColor: [UInt8]) -> [UInt8] {
        guard source.count == width * height * 4, width > 0, height > 0 else { return source }
        var out = showsAll ? source : [UInt8](repeating: 0, count: source.count)
        if !showsAll {
            for atom in atoms where atom.opacity > 0 {
                if atom.moves.isEmpty {
                    copy(atom, from: source, to: &out, width: width, height: height)
                } else {
                    moved(atom, from: source, to: &out, width: width, height: height)
                }
            }
        }
        if let cursor { fill(cursor, color: cursorColor, in: &out, width: width, height: height) }
        return out
    }

    /// The pixel columns [lower, upper) whose centres lie in [a, b).
    private static func span(_ a: Double, _ b: Double, limit: Int) -> Range<Int> {
        let lower = max(0, Int((a - 0.5).rounded(.up))), upper = min(limit, Int((b - 0.5).rounded(.up)))
        return lower < upper ? lower..<upper : 0..<0
    }

    /// An unmoved atom: its pixels, with the alpha scaled by its opacity.
    private static func copy(_ atom: Atom, from source: [UInt8], to out: inout [UInt8], width: Int, height: Int) {
        for r in atom.regions {
            let columns = span(r.x, r.maxX, limit: width), rows = span(r.y, r.maxY, limit: height)
            for y in rows {
                for x in columns {
                    let i = (y * width + x) * 4
                    guard source[i + 3] > 0 else { continue }
                    out[i] = source[i]; out[i + 1] = source[i + 1]; out[i + 2] = source[i + 2]
                    out[i + 3] = atom.opacity == 1 ? source[i + 3] : UInt8((Double(source[i + 3]) * atom.opacity).rounded())
                }
            }
        }
    }

    /// A moved atom: its pixels cut out of the source, then sampled bilinearly through the moves.
    private static func moved(_ atom: Atom, from source: [UInt8], to out: inout [UInt8], width: Int, height: Int) {
        guard let first = atom.regions.first else { return }
        var box = first
        for r in atom.regions.dropFirst() {
            let minX = min(box.x, r.x), minY = min(box.y, r.y)
            box = CanvasRect(x: minX, y: minY, width: max(box.maxX, r.maxX) - minX, height: max(box.maxY, r.maxY) - minY)
        }
        let bx = max(0, Int(box.x.rounded(.down))), by = max(0, Int(box.y.rounded(.down)))
        let bw = min(width, Int(box.maxX.rounded(.up))) - bx, bh = min(height, Int(box.maxY.rounded(.up))) - by
        guard bw > 0, bh > 0 else { return }
        // The atom's own pixels, premultiplied.
        var cut = [Float](repeating: 0, count: bw * bh * 4)
        for r in atom.regions {
            for y in span(r.y, r.maxY, limit: height) where y >= by && y < by + bh {
                for x in span(r.x, r.maxX, limit: width) where x >= bx && x < bx + bw {
                    let i = (y * width + x) * 4, o = ((y - by) * bw + (x - bx)) * 4
                    let a = Float(source[i + 3]) / 255
                    cut[o] = Float(source[i]) / 255 * a; cut[o + 1] = Float(source[i + 1]) / 255 * a
                    cut[o + 2] = Float(source[i + 2]) / 255 * a; cut[o + 3] = a
                }
            }
        }
        // Where the box lands: the corners through the moves, one pixel wider for the sampling.
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for corner in [(Double(bx), Double(by)), (Double(bx + bw), Double(by)), (Double(bx), Double(by + bh)), (Double(bx + bw), Double(by + bh))] {
            let p = forward(atom.moves, corner.0, corner.1)
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let opacity = Float(atom.opacity)
        let y0 = max(0, Int(minY.rounded(.down)) - 1), y1 = min(height, Int(maxY.rounded(.up)) + 1)
        let x0 = max(0, Int(minX.rounded(.down)) - 1), x1 = min(width, Int(maxX.rounded(.up)) + 1)
        guard y0 < y1, x0 < x1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let s = inverse(atom.moves, Double(x) + 0.5, Double(y) + 0.5)
                let p = sample(cut, width: bw, height: bh, x: s.x - Double(bx) - 0.5, y: s.y - Double(by) - 0.5)
                let a = p.3 * opacity
                guard a > 0.000_5 else { continue }
                let i = (y * width + x) * 4
                let k = 1 - a
                let da = Float(out[i + 3]) / 255
                let ra = a + da * k
                // Source-over of the premultiplied sample onto the straight pixel already there.
                let rgb = [p.0, p.1, p.2]
                for c in 0..<3 {
                    let premultiplied = rgb[c] * opacity + Float(out[i + c]) / 255 * da * k
                    out[i + c] = UInt8(max(0, min(255, (premultiplied / ra * 255).rounded())))
                }
                out[i + 3] = UInt8(max(0, min(255, (ra * 255).rounded())))
            }
        }
    }

    /// A point through the moves, first to last: a rise moves it down, a scale grows it about its centre.
    static func forward(_ moves: [TextRevealPlan.Move], _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        var p = (x: x, y: y)
        for m in moves {
            p = (m.cx + (p.x - m.cx) * m.scale, m.cy + (p.y - m.cy) * m.scale + m.dy)
        }
        return p
    }

    /// The source point that lands on (x, y).
    static func inverse(_ moves: [TextRevealPlan.Move], _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        var p = (x: x, y: y)
        for m in moves.reversed() {
            let scale = max(m.scale, 1e-6)
            p = (m.cx + (p.x - m.cx) / scale, m.cy + (p.y - m.dy - m.cy) / scale)
        }
        return p
    }

    /// Bilinear sample of premultiplied pixels at the pixel-centre coordinates (x, y); outside the cut-out is clear.
    private static func sample(_ cut: [Float], width: Int, height: Int, x: Double, y: Double) -> (Float, Float, Float, Float) {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
        for (dx, dy, w) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] where w > 0 {
            let px = x0 + dx, py = y0 + dy
            guard px >= 0, px < width, py >= 0, py < height else { continue }
            let o = (py * width + px) * 4
            r += cut[o] * w; g += cut[o + 1] * w; b += cut[o + 2] * w; a += cut[o + 3] * w
        }
        return (r, g, b, a)
    }

    /// `rect` (pixels) in `color`, each pixel by the share of it the rectangle covers, over what is there.
    private static func fill(_ rect: CanvasRect, color: [UInt8], in out: inout [UInt8], width: Int, height: Int) {
        guard color.count == 4, color[3] > 0 else { return }
        let ca = Float(color[3]) / 255
        let y0 = max(0, Int(rect.y.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
        let x0 = max(0, Int(rect.x.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
        guard y0 < y1, x0 < x1 else { return }
        let columns = x0..<x1
        for y in y0..<y1 {
            let vy = Float(min(rect.maxY, Double(y + 1)) - max(rect.y, Double(y)))
            for x in columns {
                let a = vy * Float(min(rect.maxX, Double(x + 1)) - max(rect.x, Double(x))) * ca
                guard a > 0 else { continue }
                let i = (y * width + x) * 4
                let da = Float(out[i + 3]) / 255
                let ra = a + da * (1 - a)
                for c in 0..<3 {
                    let premultiplied = Float(color[c]) / 255 * a + Float(out[i + c]) / 255 * da * (1 - a)
                    out[i + c] = UInt8(max(0, min(255, (premultiplied / ra * 255).rounded())))
                }
                out[i + 3] = UInt8(max(0, min(255, (ra * 255).rounded())))
            }
        }
    }
}
