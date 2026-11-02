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
// Global camera motion between two luma pictures (steady shot, issue #304): block matching on a luma pyramid, coarse
// to fine, then a robust similarity fit (translation, rotation, scale) over the block vectors. Pure CPU code on
// plain arrays, so it runs the same on every platform and is tested with synthetic pictures.
import Foundation

/// One luma picture as Float (0...255).
public struct LumaImage: Sendable {
    public let width: Int, height: Int
    public var pixels: [Float]
    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Rec. 601 luma of straight RGBA8.
    public init(rgba: [UInt8], width: Int, height: Int) {
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            out[i] = 0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])
        }
        self.init(width: width, height: height, pixels: out)
    }

    func halved() -> LumaImage {
        let w = width / 2, h = height / 2
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * width + 2 * x
                out[y * w + x] = (pixels[i] + pixels[i + 1] + pixels[i + width] + pixels[i + width + 1]) * 0.25
            }
        }
        return LumaImage(width: w, height: h, pixels: out)
    }

    @inline(__always) func sample(_ x: Float, _ y: Float) -> Float {
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let i = y0 * width + x0
        let top = pixels[i] * (1 - fx) + pixels[i + 1] * fx
        let bottom = pixels[i + width] * (1 - fx) + pixels[i + width + 1] * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// Motion of the picture content from the previous frame to this one, about the frame centre: a point `p` (pixels
/// from the centre, y down) moves to `scale * R(rotation) * p + (tx, ty)`. Translation is in pixels of the picture
/// that was analysed (the analysis converts to source pixels); `confidence` is 0...1, the share of the picture's
/// blocks that agree with the fit.
public struct GlobalMotion: Equatable, Sendable {
    public var tx: Double, ty: Double
    /// Radians, positive turns x towards y (clockwise on screen).
    public var rotation: Double
    public var scale: Double
    public var confidence: Double
    public init(tx: Double = 0, ty: Double = 0, rotation: Double = 0, scale: Double = 1, confidence: Double = 0) {
        self.tx = tx; self.ty = ty; self.rotation = rotation; self.scale = scale; self.confidence = confidence
    }
    public var rotationDegrees: Double { rotation * 180 / .pi }
    /// The first frame of a range: nothing to compare with, so no motion, fully trusted.
    public static let reference = GlobalMotion(confidence: 1)
}

public struct GlobalMotionEstimator: Sendable {
    public var levels = 3
    public var blockSize = 16
    /// Integer search radius around the prediction at the coarsest level and at the finer ones.
    public var coarseRadius = 6, fineRadius = 1
    /// Blocks with less texture than this (mean absolute horizontal plus vertical gradient) are ignored.
    public var minTexture: Float = 2
    public init() {}

    public func pyramid(_ image: LumaImage) -> [LumaImage] {
        var out = [image]
        while out.count < levels, let last = out.last, last.width >= 64, last.height >= 64 { out.append(last.halved()) }
        return out
    }

    private struct Model {
        var a = 1.0, b = 0.0, tx = 0.0, ty = 0.0
        func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x - b * y + tx, b * x + a * y + ty) }
    }

    /// A block centre (from the picture centre) and the displacement found for it.
    private struct Vector { var x: Double, y: Double, dx: Double, dy: Double }

    public func estimate(from previous: [LumaImage], to current: [LumaImage]) -> GlobalMotion {
        precondition(!previous.isEmpty && previous.count == current.count)
        var model = Model()
        var confidence = 0.0
        let coarsest = previous.count - 1
        for level in stride(from: coarsest, through: 0, by: -1) {
            let prev = previous[level], cur = current[level]
            let vectors = matchBlocks(prev, cur, model: model, radius: level == coarsest ? coarseRadius : fineRadius,
                                      refine: level == 0)
            guard let (fit, share) = robustFit(vectors, total: blockCount(prev)) else {
                if level == 0 { return GlobalMotion(confidence: 0) }
                model.tx *= 2; model.ty *= 2
                continue
            }
            model = fit; confidence = share
            if level > 0 { model.tx *= 2; model.ty *= 2 }
        }
        return GlobalMotion(tx: model.tx, ty: model.ty, rotation: atan2(model.b, model.a),
                            scale: (model.a * model.a + model.b * model.b).squareRoot(), confidence: min(1, confidence))
    }

    public func estimate(from previous: LumaImage, to current: LumaImage) -> GlobalMotion {
        estimate(from: pyramid(previous), to: pyramid(current))
    }

    private func blockCount(_ image: LumaImage) -> Int { max(1, (image.width / blockSize - 1) * (image.height / blockSize - 1)) }

    private func matchBlocks(_ prev: LumaImage, _ cur: LumaImage, model: Model, radius: Int, refine: Bool) -> [Vector] {
        let b = blockSize, w = prev.width, h = prev.height
        let cx = Double(w) / 2, cy = Double(h) / 2
        var out: [Vector] = []
        prev.pixels.withUnsafeBufferPointer { p in
            cur.pixels.withUnsafeBufferPointer { c in
                // Blocks are inset by one block so the search window stays inside the picture.
                for by in 1..<max(2, h / b) {
                    for bx in 1..<max(2, w / b) {
                        let x0 = bx * b, y0 = by * b
                        if x0 + b + 1 >= w || y0 + b + 1 >= h { continue }
                        // Flat blocks are skipped: matching them is a coin toss.
                        var tex: Float = 0
                        for y in 0..<(b - 1) {
                            for x in 0..<(b - 1) {
                                let i = (y0 + y) * w + x0 + x
                                tex += abs(p[i + 1] - p[i]) + abs(p[i + w] - p[i])
                            }
                        }
                        if tex / Float(b * b) < minTexture { continue }
                        let px = Double(x0) + Double(b) / 2 - cx, py = Double(y0) + Double(b) / 2 - cy
                        let (qx, qy) = model.apply(px, py)
                        let predX = Int((qx - px).rounded()), predY = Int((qy - py).rounded())
                        var best = Float.greatestFiniteMagnitude, bestX = 0, bestY = 0
                        for oy in -radius...radius {
                            for ox in -radius...radius {
                                let dx = predX + ox, dy = predY + oy
                                let sx = x0 + dx, sy = y0 + dy
                                if sx < 1 || sy < 1 || sx + b + 1 >= w || sy + b + 1 >= h { continue }
                                var sad: Float = 0
                                for y in 0..<b {
                                    let pi = (y0 + y) * w + x0, ci = (sy + y) * w + sx
                                    for x in 0..<b { sad += abs(p[pi + x] - c[ci + x]) }
                                    if sad >= best { break }
                                }
                                if sad < best { best = sad; bestX = dx; bestY = dy }
                            }
                        }
                        if best == Float.greatestFiniteMagnitude { continue }
                        var dx = Double(bestX), dy = Double(bestY)
                        if refine, let sub = refineBlock(p, cur, w: w, h: h, x0: x0, y0: y0, dx: dx, dy: dy) { dx = sub.0; dy = sub.1 }
                        out.append(Vector(x: px, y: py, dx: dx, dy: dy))
                    }
                }
            }
        }
        return out
    }

    /// Sub-pixel translation of one block: inverse-compositional Lucas-Kanade, up to three iterations from the
    /// integer match. nil when the block has no usable gradient or the refinement runs away.
    private func refineBlock(_ p: UnsafeBufferPointer<Float>, _ cur: LumaImage, w: Int, h: Int, x0: Int, y0: Int,
                             dx: Double, dy: Double) -> (Double, Double)? {
        let b = blockSize
        var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0
        for y in 0..<b {
            for x in 0..<b {
                let i = (y0 + y) * w + x0 + x
                let gx = (p[i + 1] - p[i - 1]) * 0.5, gy = (p[i + w] - p[i - w]) * 0.5
                gxx += gx * gx; gxy += gx * gy; gyy += gy * gy
            }
        }
        let det = gxx * gyy - gxy * gxy
        if det < 1 || det < 1e-3 * gxx * gyy { return nil }
        var ux = Float(dx), uy = Float(dy)
        for _ in 0..<3 {
            var bx: Float = 0, by: Float = 0
            for y in 0..<b {
                for x in 0..<b {
                    let i = (y0 + y) * w + x0 + x
                    let sx = Float(x0 + x) + ux, sy = Float(y0 + y) + uy
                    if sx < 1 || sy < 1 || sx >= Float(w - 2) || sy >= Float(h - 2) { return nil }
                    let gx = (p[i + 1] - p[i - 1]) * 0.5, gy = (p[i + w] - p[i - w]) * 0.5
                    let e = p[i] - cur.sample(sx, sy)
                    bx += gx * e; by += gy * e
                }
            }
            let stepX = (gyy * bx - gxy * by) / det, stepY = (gxx * by - gxy * bx) / det
            ux += stepX; uy += stepY
            if abs(stepX) < 0.002 && abs(stepY) < 0.002 { break }
        }
        if abs(Double(ux) - dx) > 1.5 || abs(Double(uy) - dy) > 1.5 { return nil }
        return (Double(ux), Double(uy))
    }

    private func residual(_ model: Model, _ v: Vector) -> Double {
        let (qx, qy) = model.apply(v.x, v.y)
        let ex = qx - v.x - v.dx, ey = qy - v.y - v.dy
        return (ex * ex + ey * ey).squareRoot()
    }

    /// Iteratively reweighted least squares for `q = M p + t` (M a rotation times a scale) with Tukey weights.
    private func robustFit(_ vectors: [Vector], total: Int) -> (Model, Double)? {
        guard vectors.count >= 4 else { return nil }
        var model = Model()
        var weights = [Double](repeating: 1, count: vectors.count)
        for iteration in 0..<6 {
            guard let fit = weightedFit(vectors, weights) else { return nil }
            model = fit
            if iteration == 5 { break }
            let residuals = vectors.map { residual(model, $0) }
            let sorted = residuals.sorted()
            let sigma = max(1.4826 * sorted[sorted.count / 2], 0.05)
            let cutoff = max(4.685 * sigma, 0.3)
            for i in 0..<vectors.count {
                let u = residuals[i] / cutoff
                weights[i] = u < 1 ? (1 - u * u) * (1 - u * u) : 0
            }
        }
        let inliers = vectors.filter { residual(model, $0) < 0.75 }.count
        return (model, Double(inliers) / Double(total))
    }

    private func weightedFit(_ v: [Vector], _ w: [Double]) -> Model? {
        var sw = 0.0, mx = 0.0, my = 0.0, qx = 0.0, qy = 0.0
        for i in 0..<v.count {
            sw += w[i]; mx += w[i] * v[i].x; my += w[i] * v[i].y
            qx += w[i] * (v[i].x + v[i].dx); qy += w[i] * (v[i].y + v[i].dy)
        }
        guard sw > 3 else { return nil }
        mx /= sw; my /= sw; qx /= sw; qy /= sw
        var num1 = 0.0, num2 = 0.0, den = 0.0
        for i in 0..<v.count {
            let x = v[i].x - mx, y = v[i].y - my, u = v[i].x + v[i].dx - qx, t = v[i].y + v[i].dy - qy
            num1 += w[i] * (x * u + y * t); num2 += w[i] * (x * t - y * u); den += w[i] * (x * x + y * y)
        }
        guard den > 1e-9 else { return nil }
        var m = Model()
        m.a = num1 / den; m.b = num2 / den
        m.tx = qx - (m.a * mx - m.b * my); m.ty = qy - (m.b * mx + m.a * my)
        return m
    }
}
