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

/// Grade scopes: a graded frame analysed into a luma
/// histogram, a luma waveform, an RGB parade and a vectorscope, drawn into the 320x144 scope bitmap.
public enum ColorScopes {
    public enum Mode: String, CaseIterable, Sendable { case histogram, waveform, parade, vectorscope
        public var label: String {
            switch self { case .histogram: "Histogram"; case .waveform: "Waveform"; case .parade: "RGB Parade"; case .vectorscope: "Vectorscope" }
        }
    }

    /// The scope `<canvas width=320 height=144>`.
    public static let bitmapWidth = 320, bitmapHeight = 144

    public struct Analysis: Sendable {
        public var width: Int
        public var histogram: [UInt32]
        public var waveform: [UInt32]
        public var parade: [UInt32]
        public var vectorscope: [UInt32]
    }

    /// analyzeColorGradingFrame: alpha-weighted counts per column / byte value (top row = 255).
    public static func analyze(_ img: CanvasImage) -> Analysis {
        let w = img.width, h = img.height, n = 256
        var histogram = [UInt32](repeating: 0, count: n)
        var waveform = [UInt32](repeating: 0, count: w * n)
        var parade = [UInt32](repeating: 0, count: w * n * 3)
        var vector = [UInt32](repeating: 0, count: n * n)
        func idx(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        img.rgba.withUnsafeBufferPointer { px in
            for y in 0..<h { for x in 0..<w {
                let o = (y * w + x) * 4
                let a = UInt32(px[o + 3])
                if a == 0 { continue }
                let r = Double(px[o]) / 255, g = Double(px[o + 1]) / 255, b = Double(px[o + 2]) / 255
                let l = r * 0.2126 + g * 0.7152 + b * 0.0722
                let li = idx(l)
                histogram[li] &+= a
                waveform[x * n + (255 - li)] &+= a
                parade[x * n + (255 - idx(r))] &+= a
                parade[w * n + x * n + (255 - idx(g))] &+= a
                parade[w * n * 2 + x * n + (255 - idx(b))] &+= a
                let vx = idx((b - l) / 1.8556 + 0.5), vy = 255 - idx((r - l) / 1.5748 + 0.5)
                vector[vy * n + vx] &+= a
            } }
        }
        return Analysis(width: w, histogram: histogram, waveform: waveform, parade: parade, vectorscope: vector)
    }

    static func densityAlpha(_ v: UInt32, _ maximum: UInt32) -> Double {
        guard v > 0, maximum > 0 else { return 0 }
        return min(1, log2(Double(v) + 1) / log2(Double(maximum) + 1))
    }

    /// A straight-alpha RGBA bitmap the scope is painted into (source-over, like the 2D context).
    struct Bitmap {
        let w: Int, h: Int
        var px: [Double]
        init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [Double](repeating: 0, count: w * h * 3) }
        mutating func blend(_ x: Int, _ y: Int, _ c: (Double, Double, Double), _ a: Double) {
            guard x >= 0, y >= 0, x < w, y < h, a > 0 else { return }
            let i = (y * w + x) * 3
            px[i] += (c.0 - px[i]) * a; px[i + 1] += (c.1 - px[i + 1]) * a; px[i + 2] += (c.2 - px[i + 2]) * a
        }
        /// fillRect with fractional edges covered by area.
        mutating func fill(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double, _ c: (Double, Double, Double), _ a: Double) {
            let x0 = max(0, Int(x.rounded(.down))), x1 = min(w, Int((x + rw).rounded(.up)))
            let y0 = max(0, Int(y.rounded(.down))), y1 = min(h, Int((y + rh).rounded(.up)))
            guard x0 < x1, y0 < y1 else { return }
            for py in y0..<y1 {
                let cy = min(Double(py + 1), y + rh) - max(Double(py), y)
                for pxl in x0..<x1 {
                    let cx = min(Double(pxl + 1), x + rw) - max(Double(pxl), x)
                    blend(pxl, py, c, a * max(0, cx) * max(0, cy))
                }
            }
        }
        /// A 1px line (Wu-style coverage along the major axis).
        mutating func line(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ c: (Double, Double, Double), _ a: Double) {
            let steps = Int(max(abs(bx - ax), abs(by - ay)).rounded(.up)) + 1
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let x = ax + (bx - ax) * t - 0.5, y = ay + (by - ay) * t - 0.5
                let fx = x.rounded(.down), fy = y.rounded(.down), dx = x - fx, dy = y - fy
                blend(Int(fx), Int(fy), c, a * (1 - dx) * (1 - dy)); blend(Int(fx) + 1, Int(fy), c, a * dx * (1 - dy))
                blend(Int(fx), Int(fy) + 1, c, a * (1 - dx) * dy); blend(Int(fx) + 1, Int(fy) + 1, c, a * dx * dy)
            }
        }
        var image: CanvasImage {
            var out = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) {
                out[i * 4] = UInt8(min(255, max(0, (px[i * 3] * 255).rounded())))
                out[i * 4 + 1] = UInt8(min(255, max(0, (px[i * 3 + 1] * 255).rounded())))
                out[i * 4 + 2] = UInt8(min(255, max(0, (px[i * 3 + 2] * 255).rounded())))
            }
            return CanvasImage(width: w, height: h, rgba: out)
        }
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) { (r / 255, g / 255, b / 255) }

    /// drawGrid: #090b0e with white/8% lines at a quarter, half and three quarters of the height.
    static func grid(_ w: Int, _ h: Int) -> Bitmap {
        var bm = Bitmap(w, h)
        let bg = rgb(9, 11, 14)
        for i in 0..<(w * h) { bm.px[i * 3] = bg.0; bm.px[i * 3 + 1] = bg.1; bm.px[i * 3 + 2] = bg.2 }
        for f in [0.25, 0.5, 0.75] {
            let y = Int((Double(h) * f).rounded())
            for x in 0..<w { bm.blend(x, y, (1, 1, 1), 0.08) }
        }
        return bm
    }

    /// The scope bitmap for `mode` (nil analysis: the empty grid, as before a frame is captured).
    public static func render(_ mode: Mode, _ a: Analysis?, width w: Int = bitmapWidth, height h: Int = bitmapHeight) -> CanvasImage {
        var bm = grid(w, h)
        guard let a else { return bm.image }
        let W = Double(w), H = Double(h)
        func density(_ d: [UInt32], offset: Int, count: Int, _ color: (Double, Double, Double), x0: Double, outW: Double) {
            guard count > 0 else { return }
            let start = offset * 256, end = (offset + count) * 256
            var m: UInt32 = 0
            for i in start..<min(end, d.count) { m = max(m, d[i]) }
            for x in 0..<count { for y in 0..<256 {
                let v = d[(offset + x) * 256 + y]
                if v == 0 { continue }
                bm.fill(x0 + Double(x) / Double(count) * outW, Double(y) / 255 * H, max(1, outW / Double(count)), max(1, H / 256), color, densityAlpha(v, m))
            } }
        }
        switch mode {
        case .histogram:
            let m = a.histogram.max() ?? 0
            let ys = a.histogram.map { H - densityAlpha($0, m) * H }
            // Fill under the curve (white-ish at 20%), then the curve at 90%.
            for px in 0..<w {
                let t = (Double(px) + 0.5) / W * 255
                let i = min(254, Int(t)), f = t - Double(i)
                let top = ys[i] + (ys[i + 1] - ys[i]) * f
                bm.fill(Double(px), top, 1, H - top, rgb(226, 232, 240), 0.2)
            }
            for i in 0..<255 { bm.line(Double(i) / 255 * W, ys[i], Double(i + 1) / 255 * W, ys[i + 1], rgb(226, 232, 240), 0.9) }
        case .waveform:
            density(a.waveform, offset: 0, count: a.width, rgb(226, 232, 240), x0: 0, outW: W)
        case .parade:
            let lane = W / 3
            for (ch, c) in [(0, rgb(248, 113, 113)), (1, rgb(74, 222, 128)), (2, rgb(96, 165, 250))] {
                density(a.parade, offset: ch * a.width, count: a.width, c, x0: Double(ch) * lane, outW: lane)
            }
        case .vectorscope:
            let cx = W / 2, cy = H / 2, r = min(W, H) * 0.42
            let segs = 96
            for s in 0..<segs {
                let t0 = Double(s) / Double(segs) * 2 * .pi, t1 = Double(s + 1) / Double(segs) * 2 * .pi
                bm.line(cx + cos(t0) * r, cy + sin(t0) * r, cx + cos(t1) * r, cy + sin(t1) * r, (1, 1, 1), 0.12)
            }
            bm.line(cx, 0, cx, H, (1, 1, 1), 0.12); bm.line(0, cy, W, cy, (1, 1, 1), 0.12)
            let skin = -123 * Double.pi / 180, sr = min(W, H) * 0.45
            bm.line(cx, cy, cx + cos(skin) * sr, cy + sin(skin) * sr, rgb(251, 191, 36), 0.3)
            let m = a.vectorscope.max() ?? 0
            for y in 0..<256 { for x in 0..<256 {
                let v = a.vectorscope[y * 256 + x]
                if v == 0 { continue }
                bm.fill(Double(x) / 255 * W, Double(y) / 255 * H, max(1, W / 256), max(1, H / 256), rgb(110, 231, 183), densityAlpha(v, m))
            } }
        }
        return bm.image
    }
}
