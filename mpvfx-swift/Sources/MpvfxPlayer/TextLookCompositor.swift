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

/// The pixel half of a text look: from the coverage of the letters (alpha, 0...255) it builds the plate, the drop
/// shadow, the glow, the outlines and the fill as one straight-alpha RGBA8 image. It only reads the coverage, so every canvas backend
/// gets the same outline and shadow for the same letters, in preview and in export.
///
/// Outline edges come from the distance to the nearest covered pixel (exact Euclidean distance), so corners are
/// round and a band of `w` px is `w` px wide in any direction.
enum TextLookCompositor {
    /// One outline band in device pixels: it covers every pixel whose distance from the letter edge is at most `reach`.
    struct Band { var reach: Double; var color: CanvasColor }
    struct Shadow { var dx: Int; var dy: Int; var blur: Double; var color: CanvasColor }
    /// A halo `radius` device px wide that reaches `strength` (0...1) of `color` at the letter edge.
    struct Glow { var radius: Double; var strength: Float; var color: CanvasColor }
    /// A rounded rectangle in image pixels; `radius` is clamped to half its shorter side.
    struct PlateRect { var rect: CanvasRect; var radius: Double }
    struct Plate { var rects: [PlateRect]; var color: CanvasColor }
    /// `from` to `to` along `angle` degrees (0: left to right, 90: top to bottom) across `bounds`, in image pixels.
    struct Gradient { var from: CanvasColor; var to: CanvasColor; var angle: Double; var bounds: CanvasRect }

    /// Composites plate, shadow, glow, outer outline, inner outline and fill (in that order) from `coverage`
    /// (`width` x `height`). `bands` are nearest-first with growing reach. A `gradient` replaces the solid `fill`.
    static func compose(coverage: [UInt8], width: Int, height: Int, fill: CanvasColor, bands: [Band], shadow: Shadow?,
                        glow: Glow? = nil, plate: Plate? = nil, gradient: Gradient? = nil) -> [UInt8] {
        let n = width * height
        guard coverage.count == n, n > 0 else { return [UInt8](repeating: 0, count: n * 4) }
        let cov = coverage.map { Float($0) / 255 }
        var acc = [Float](repeating: 0, count: n * 4)   // premultiplied RGBA
        let distance = bands.isEmpty ? [] : distances(coverage: coverage, width: width, height: height)
        func bandCoverage(_ reach: Double) -> [Float] {
            let r = Float(reach)
            return (0..<n).map { i in
                coverage[i] >= 128 ? 1 : max(0, min(1, r - distance[i] + 1))
            }
        }
        let bandCovs = bands.map { bandCoverage($0.reach) }
        let silhouette = bandCovs.last.map { zip($0, cov).map { max($0, $1) } } ?? cov
        if let plate, plate.color.a > 0 { over(&acc, plateCoverage(plate.rects, width: width, height: height), plate.color) }
        if let shadow, shadow.color.a > 0 {
            let moved = shifted(silhouette, width: width, height: height, dx: shadow.dx, dy: shadow.dy)
            let soft = blurred(moved, width: width, height: height, sigma: shadow.blur / 2)
            over(&acc, soft, shadow.color)
        }
        if let glow, glow.strength > 0, glow.color.a > 0 {
            let soft = blurred(silhouette, width: width, height: height, sigma: glow.radius / 2)
            over(&acc, soft.map { min(1, 2 * $0) * glow.strength }, glow.color)
        }
        for (band, bc) in zip(bands, bandCovs).reversed() { over(&acc, bc, band.color) }
        if let gradient { overGradient(&acc, cov, gradient, width: width) } else { over(&acc, cov, fill) }
        var out = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            let a = acc[i * 4 + 3]
            guard a > 0.000_5 else { continue }
            for k in 0..<3 { out[i * 4 + k] = UInt8(max(0, min(255, (acc[i * 4 + k] / a * 255).rounded()))) }
            out[i * 4 + 3] = UInt8(max(0, min(255, (a * 255).rounded())))
        }
        return out
    }

    /// Source-over of `color` scaled by `coverage` onto the premultiplied accumulator.
    static func over(_ acc: inout [Float], _ coverage: [Float], _ color: CanvasColor) {
        let ca = Float(color.a), r = Float(color.r), g = Float(color.g), b = Float(color.b)
        for i in 0..<coverage.count {
            let a = coverage[i] * ca
            guard a > 0 else { continue }
            let k = 1 - a
            acc[i * 4] = r * a + acc[i * 4] * k
            acc[i * 4 + 1] = g * a + acc[i * 4 + 1] * k
            acc[i * 4 + 2] = b * a + acc[i * 4 + 2] * k
            acc[i * 4 + 3] = a + acc[i * 4 + 3] * k
        }
    }

    /// The share of each pixel the plate covers: the union of its rounded rectangles.
    static func plateCoverage(_ rects: [PlateRect], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for plate in rects {
            let r = plate.rect
            guard r.width > 0, r.height > 0 else { continue }
            let radius = max(0, min(plate.radius, min(r.width, r.height) / 2))
            let halfW = r.width / 2, halfH = r.height / 2, cx = r.x + halfW, cy = r.y + halfH
            // A rectangle past the picture's edge (text that overflows its box) simply has fewer rows or none.
            let y0 = max(0, Int(r.y.rounded(.down)) - 1), y1 = min(height, Int(r.maxY.rounded(.up)) + 1)
            let x0 = max(0, Int(r.x.rounded(.down)) - 1), x1 = min(width, Int(r.maxX.rounded(.up)) + 1)
            guard y0 < y1, x0 < x1 else { continue }
            let columns = x0..<x1
            for y in y0..<y1 {
                let qy = abs(Double(y) + 0.5 - cy) - (halfH - radius)
                for x in columns {
                    let qx = abs(Double(x) + 0.5 - cx) - (halfW - radius)
                    let distance = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - radius
                    let c = Float(max(0, min(1, 0.5 - distance)))
                    if c > out[y * width + x] { out[y * width + x] = c }
                }
            }
        }
        return out
    }

    /// Source-over of the gradient, scaled by `coverage`, onto the premultiplied accumulator.
    static func overGradient(_ acc: inout [Float], _ coverage: [Float], _ g: Gradient, width: Int) {
        let theta = g.angle * Double.pi / 180
        let dx = cos(theta), dy = sin(theta)
        let half = (g.bounds.width * abs(dx) + g.bounds.height * abs(dy)) / 2
        let cx = g.bounds.x + g.bounds.width / 2, cy = g.bounds.y + g.bounds.height / 2
        for i in 0..<coverage.count where coverage[i] > 0 {
            let px = Double(i % width) + 0.5, py = Double(i / width) + 0.5
            let t = half > 0 ? Float(max(0, min(1, ((px - cx) * dx + (py - cy) * dy) / (2 * half) + 0.5))) : 0.5
            let r = Float(g.from.r) + (Float(g.to.r) - Float(g.from.r)) * t
            let gr = Float(g.from.g) + (Float(g.to.g) - Float(g.from.g)) * t
            let b = Float(g.from.b) + (Float(g.to.b) - Float(g.from.b)) * t
            let a = coverage[i] * (Float(g.from.a) + (Float(g.to.a) - Float(g.from.a)) * t)
            guard a > 0 else { continue }
            let k = 1 - a
            acc[i * 4] = r * a + acc[i * 4] * k
            acc[i * 4 + 1] = gr * a + acc[i * 4 + 1] * k
            acc[i * 4 + 2] = b * a + acc[i * 4 + 2] * k
            acc[i * 4 + 3] = a + acc[i * 4 + 3] * k
        }
    }

    /// Distance in px from each pixel centre to the nearest covered pixel centre (0 on covered pixels), by the
    /// two-pass squared-distance transform. A pixel with no covered pixel anywhere is far (1e9).
    static func distances(coverage: [UInt8], width: Int, height: Int) -> [Float] {
        let inf: Float = 1e18
        var d = coverage.map { $0 >= 128 ? Float(0) : inf }
        var line = [Float](repeating: 0, count: max(width, height))
        var out = [Float](repeating: 0, count: max(width, height))
        for x in 0..<width {
            for y in 0..<height { line[y] = d[y * width + x] }
            transform1D(line, &out, count: height)
            for y in 0..<height { d[y * width + x] = out[y] }
        }
        for y in 0..<height {
            for x in 0..<width { line[x] = d[y * width + x] }
            transform1D(line, &out, count: width)
            for x in 0..<width { d[y * width + x] = out[x] }
        }
        return d.map { $0 >= inf / 2 ? 1e9 : $0.squareRoot() }
    }

    /// Lower envelope of parabolas (squared-distance transform in one dimension).
    private static func transform1D(_ f: [Float], _ out: inout [Float], count n: Int) {
        guard n > 0 else { return }
        guard n > 1 else { out[0] = f[0]; return }
        let inf: Float = 1e18
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        var k = 0
        z[0] = -inf; z[1] = inf
        func cross(_ q: Int, _ p: Int) -> Float { ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p) }
        for q in 1..<n {
            var s = cross(q, v[k])
            while s <= z[k] { k -= 1; s = cross(q, v[k]) }
            k += 1; v[k] = q; z[k] = s; z[k + 1] = inf
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            out[q] = Float((q - p) * (q - p)) + f[p]
        }
    }

    static func shifted(_ a: [Float], width: Int, height: Int, dx: Int, dy: Int) -> [Float] {
        guard dx != 0 || dy != 0 else { return a }
        var out = [Float](repeating: 0, count: a.count)
        for y in 0..<height {
            let sy = y - dy
            guard sy >= 0, sy < height else { continue }
            for x in 0..<width {
                let sx = x - dx
                if sx >= 0, sx < width { out[y * width + x] = a[sy * width + sx] }
            }
        }
        return out
    }

    /// Gaussian blur as three box blurs (the usual approximation); no blur below a quarter pixel of sigma.
    static func blurred(_ a: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
        guard sigma >= 0.25 else { return a }
        var cur = a
        for size in boxSizes(sigma: sigma) {
            cur = boxBlur(cur, width: width, height: height, radius: (size - 1) / 2, horizontal: true)
            cur = boxBlur(cur, width: width, height: height, radius: (size - 1) / 2, horizontal: false)
        }
        return cur
    }

    /// Three odd box widths whose combined variance is `sigma^2`.
    static func boxSizes(sigma: Double) -> [Int] {
        let ideal = (12 * sigma * sigma / 3 + 1).squareRoot()
        var lo = Int(ideal.rounded(.down)); if lo % 2 == 0 { lo -= 1 }
        lo = max(1, lo)
        let hi = lo + 2
        let m = ((12 * sigma * sigma - 3 * Double(lo * lo) - 12 * Double(lo) - 9) / (-4 * Double(lo) - 4)).rounded()
        return (0..<3).map { Double($0) < m ? lo : hi }
    }

    private static func boxBlur(_ a: [Float], width: Int, height: Int, radius r: Int, horizontal: Bool) -> [Float] {
        guard r > 0 else { return a }
        var out = [Float](repeating: 0, count: a.count)
        let lines = horizontal ? height : width, length = horizontal ? width : height
        let norm = 1 / Float(2 * r + 1)
        for l in 0..<lines {
            func at(_ i: Int) -> Float {
                guard i >= 0, i < length else { return 0 }
                return horizontal ? a[l * width + i] : a[i * width + l]
            }
            var sum: Float = 0
            for i in -r...r { sum += at(i) }
            for i in 0..<length {
                if horizontal { out[l * width + i] = sum * norm } else { out[i * width + l] = sum * norm }
                sum += at(i + r + 1) - at(i - r)
            }
        }
        return out
    }
}
