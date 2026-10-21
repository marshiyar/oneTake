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

/// The pixel half of a text look: from the coverage of the letters (alpha, 0...255) it builds the drop shadow, the
/// outlines and the fill as one straight-alpha RGBA8 image. It only reads the coverage, so every canvas backend
/// gets the same outline and shadow for the same letters, in preview and in export.
///
/// Outline edges come from the distance to the nearest covered pixel (exact Euclidean distance), so corners are
/// round and a band of `w` px is `w` px wide in any direction.
enum TextLookCompositor {
    /// One outline band in device pixels: it covers every pixel whose distance from the letter edge is at most `reach`.
    struct Band { var reach: Double; var color: CanvasColor }
    struct Shadow { var dx: Int; var dy: Int; var blur: Double; var color: CanvasColor }

    /// Composites shadow, outer outline, inner outline and fill (in that order) from `coverage` (`width` x `height`).
    /// `bands` are nearest-first with growing reach.
    static func compose(coverage: [UInt8], width: Int, height: Int, fill: CanvasColor, bands: [Band], shadow: Shadow?) -> [UInt8] {
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
        if let shadow, shadow.color.a > 0 {
            let silhouette = bandCovs.last.map { zip($0, cov).map { max($0, $1) } } ?? cov
            let moved = shifted(silhouette, width: width, height: height, dx: shadow.dx, dy: shadow.dy)
            let soft = blurred(moved, width: width, height: height, sigma: shadow.blur / 2)
            over(&acc, soft, shadow.color)
        }
        for (band, bc) in zip(bands, bandCovs).reversed() { over(&acc, bc, band.color) }
        over(&acc, cov, fill)
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
