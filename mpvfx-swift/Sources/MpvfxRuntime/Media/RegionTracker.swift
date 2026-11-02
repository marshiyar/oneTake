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
// Region tracker: follows a box through decoded frames by normalized cross-correlation of the luma patch,
// coarse to fine on a small pyramid, with a sub-pixel peak fit and an optional scale search. No model, no
// third-party code. Pure computation over `TrackLumaFrame`s, so it runs off the main thread and is cancellable.
import Foundation
import OneTakeMedia

/// One decoded frame reduced to luma (0...1), row-major.
public struct TrackLumaFrame: Sendable {
    public let width: Int, height: Int
    public let pixels: [Float]
    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }
    /// From straight-alpha RGBA8 (the engine's frame format), Rec. 709 weights.
    public init(rgba: [UInt8], width: Int, height: Int) {
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            out[i] = (0.2126 * Float(rgba[i * 4]) + 0.7152 * Float(rgba[i * 4 + 1]) + 0.0722 * Float(rgba[i * 4 + 2])) / 255
        }
        self.init(width: width, height: height, pixels: out)
    }
}

/// A box in frame pixels (top-left origin).
public struct TrackBox: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// The box's centre and scale (relative to the starting box) on one frame.
public struct TrackPoint: Equatable, Sendable {
    public var frame: Int
    public var x: Double, y: Double
    public var scale: Double
    /// Peak normalized cross-correlation, 0...1.
    public var confidence: Double
}

public struct RegionTrackerOptions: Equatable, Sendable {
    /// A frame whose confidence falls below this stops the track.
    public var confidenceThreshold = 0.6
    /// Search radius around the predicted centre, frame pixels, per step.
    public var searchRadius = 16
    /// Search a small set of scales around the last one (off: scale stays 1).
    public var scaleSearch = false
    /// Scale step per frame tried in each direction.
    public var scaleStep = 0.01
    public var pyramidLevels = 3
    public init() {}
}

public struct RegionTrackResult: Equatable, Sendable {
    /// Good samples in tracking order, starting with the start frame (confidence 1).
    public var samples: [TrackPoint]
    /// Set when the track stopped on a low-confidence frame (that frame is not in `samples`).
    public var stoppedAt: Int?
    public var stoppedConfidence: Double?
}

public enum RegionTrackerError: Error, Equatable {
    case invalidBox, textureTooLow, missingStartFrame
}

private struct Plane {
    var w: Int, h: Int, d: [Float]
    @inline(__always) func at(_ x: Int, _ y: Int) -> Float { d[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
    @inline(__always) func bilinear(_ x: Double, _ y: Double) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int(fx), iy = Int(fy)
        let ax = Float(x - fx), ay = Float(y - fy)
        let top = at(ix, iy) * (1 - ax) + at(ix + 1, iy) * ax
        let bot = at(ix, iy + 1) * (1 - ax) + at(ix + 1, iy + 1) * ax
        return top * (1 - ay) + bot * ay
    }
    func halved() -> Plane {
        let nw = max(1, w / 2), nh = max(1, h / 2)
        var o = [Float](repeating: 0, count: nw * nh)
        for y in 0..<nh { for x in 0..<nw {
            o[y * nw + x] = (at(2 * x, 2 * y) + at(2 * x + 1, 2 * y) + at(2 * x, 2 * y + 1) + at(2 * x + 1, 2 * y + 1)) / 4
        } }
        return Plane(w: nw, h: nh, d: o)
    }
}

/// A zero-mean template at one pyramid level.
private struct Template {
    var w: Int, h: Int, d: [Float], norm: Float
    init(_ p: Plane) {
        w = p.w; h = p.h
        let mean = p.d.reduce(0, +) / Float(p.d.count)
        d = p.d.map { $0 - mean }
        norm = d.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}

public enum RegionTracker {
    /// Tracks `box` from `startFrame` through `frames` (`nil` = no more frames), forward or backward.
    /// `maxFrames` bounds the number of steps. Throws `MediaAbortError` once `cancellation` is cancelled.
    public static func track(box: TrackBox, startFrame: Int, forward: Bool = true, maxFrames: Int = .max,
                             options: RegionTrackerOptions = .init(), cancellation: MediaCancellation = MediaCancellation(),
                             progress: ((Int) -> Void)? = nil,
                             frames: (Int) throws -> TrackLumaFrame?) throws -> RegionTrackResult {
        guard box.width >= 8, box.height >= 8, box.width.isFinite, box.height.isFinite, box.x.isFinite, box.y.isFinite else {
            throw RegionTrackerError.invalidBox
        }
        try cancellation.throwIfCancelled()
        guard let first = try frames(startFrame) else { throw RegionTrackerError.missingStartFrame }
        let levels = max(1, min(options.pyramidLevels, 4))
        let tw = Int(box.width.rounded()), th = Int(box.height.rounded())
        // Template: the box resampled to tw x th on the start frame.
        let src = Plane(w: first.width, h: first.height, d: first.pixels)
        var base = Plane(w: tw, h: th, d: [Float](repeating: 0, count: tw * th))
        for j in 0..<th { for i in 0..<tw {
            base.d[j * tw + i] = src.bilinear(box.x + (Double(i) + 0.5) * box.width / Double(tw) - 0.5,
                                              box.y + (Double(j) + 0.5) * box.height / Double(th) - 0.5)
        } }
        var templates: [Template] = []
        var plane = base
        for _ in 0..<levels { templates.append(Template(plane)); plane = plane.halved() }
        guard templates[0].norm / Float(tw * th).squareRoot() > 1e-3 else { throw RegionTrackerError.textureTooLow }

        var samples = [TrackPoint(frame: startFrame, x: box.centerX, y: box.centerY, scale: 1, confidence: 1)]
        // Matching works in pixel-index coordinates (pixel centres at integers): half a pixel left of the continuous centre.
        var cx = box.centerX - 0.5, cy = box.centerY - 0.5, scale = 1.0
        var vx = 0.0, vy = 0.0
        var frame = startFrame
        var steps = 0
        while steps < maxFrames {
            try cancellation.throwIfCancelled()
            frame += forward ? 1 : -1
            guard frame >= 0, let f = try frames(frame) else { break }
            steps += 1
            let m = match(templates: templates, frame: f, boxW: box.width, boxH: box.height,
                          px: cx + vx, py: cy + vy, scale: scale, options: options)
            if m.confidence < options.confidenceThreshold {
                return RegionTrackResult(samples: samples, stoppedAt: frame, stoppedConfidence: m.confidence)
            }
            vx = m.x - cx; vy = m.y - cy
            cx = m.x; cy = m.y; scale = m.scale
            samples.append(TrackPoint(frame: frame, x: cx + 0.5, y: cy + 0.5, scale: scale, confidence: m.confidence))
            progress?(steps)
        }
        return RegionTrackResult(samples: samples, stoppedAt: nil, stoppedConfidence: nil)
    }

    /// `track` on a utility thread: the caller's task cancellation cancels the track.
    public static func trackOffMain(box: TrackBox, startFrame: Int, forward: Bool = true, maxFrames: Int = .max,
                                    options: RegionTrackerOptions = .init(), cancellation: MediaCancellation = MediaCancellation(),
                                    frames: @escaping @Sendable (Int) throws -> TrackLumaFrame?) async throws -> RegionTrackResult {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try track(box: box, startFrame: startFrame, forward: forward, maxFrames: maxFrames, options: options,
                          cancellation: cancellation, frames: frames)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    /// Frames decoded by the media engine, as luma at the source's display size. Frame `n` is at `n / frameRate`.
    public static func engineFrames(path: String) throws -> (info: VideoFrameReader.Info, frame: (Int) throws -> TrackLumaFrame?) {
        let reader = try VideoFrameReader(path: path)
        let info = reader.info
        let rate = info.frameRate > 0 ? info.frameRate : 30
        let count = Int((info.duration * rate).rounded(.down))
        return (info, { n in
            guard n >= 0, n < count else { return nil }
            let f = try reader.frame(at: Double(n) / rate, width: info.width, height: info.height, fit: .stretch)
            return TrackLumaFrame(rgba: f.rgba, width: info.width, height: info.height)
        })
    }

    // MARK: matching

    private struct Match { var x: Double, y: Double, scale: Double, confidence: Double }

    /// Coordinates inside `match` are level-0 pixels of a crop around the prediction; `ncc` takes the level's decimation.
    private static func match(templates: [Template], frame: TrackLumaFrame, boxW: Double, boxH: Double,
                              px: Double, py: Double, scale: Double, options: RegionTrackerOptions) -> Match {
        let levels = templates.count
        let half = max(boxW, boxH) * scale * (1 + options.scaleStep * 2) / 2 + Double(options.searchRadius) + 4
        let x0 = Int((px - half).rounded(.down)), y0 = Int((py - half).rounded(.down))
        let cw = Int(half * 2) + 2, ch = Int(half * 2) + 2
        var crop = Plane(w: cw, h: ch, d: [Float](repeating: 0, count: cw * ch))
        let full = Plane(w: frame.width, h: frame.height, d: frame.pixels)
        for j in 0..<ch { for i in 0..<cw { crop.d[j * cw + i] = full.at(x0 + i, y0 + j) } }
        var pyr = [crop]
        for _ in 1..<levels { pyr.append(pyr.last!.halved()) }

        var cxl = px - Double(x0), cyl = py - Double(y0)
        var scales = options.scaleSearch ? [scale / (1 + options.scaleStep), scale, scale * (1 + options.scaleStep)] : [scale]
        var best = (x: cxl, y: cyl, s: scale, c: -2.0)
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let f = Double(1 << level)
            let radius = level == levels - 1 ? max(1, Int((Double(options.searchRadius) / f).rounded(.up))) : 1
            best.c = -2
            for s in scales {
                for dy in -radius...radius { for dx in -radius...radius {
                    let x = cxl + Double(dx) * f, y = cyl + Double(dy) * f
                    let c = ncc(templates[level], pyr[level], (x - (f - 1) / 2) / f, (y - (f - 1) / 2) / f, s, boxW, boxH, f)
                    if c > best.c { best = (x, y, s, c) }
                } }
            }
            cxl = best.x; cyl = best.y
            scales = [best.s]
        }
        // Sub-pixel (and scale) refinement at level 0 around the best integer position.
        var cs = [best.s]
        if options.scaleSearch {
            let d = options.scaleStep / 2
            cs = [best.s / (1 + d), best.s, best.s * (1 + d)]
        }
        var scores: [Double] = []
        var peaks: [(x: Double, y: Double, c: Double)] = []
        for s in cs {
            var g = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            var bc = -2.0, bi = (1, 1)
            for j in 0..<3 { for i in 0..<3 {
                let c = ncc(templates[0], pyr[0], best.x + Double(i - 1), best.y + Double(j - 1), s, boxW, boxH, 1)
                g[j][i] = c
                if c > bc { bc = c; bi = (i, j) }
            } }
            var ox = 0.0, oy = 0.0
            if bi.0 == 1 { ox = parabola(g[bi.1][0], g[bi.1][1], g[bi.1][2]) }
            if bi.1 == 1 { oy = parabola(g[0][bi.0], g[1][bi.0], g[2][bi.0]) }
            scores.append(bc)
            peaks.append((best.x + Double(bi.0 - 1) + ox, best.y + Double(bi.1 - 1) + oy, bc))
        }
        var k = 0
        for i in 1..<max(1, scores.count) where scores[i] > scores[k] { k = i }
        var finalScale = cs[k]
        if options.scaleSearch, k == 1 {
            finalScale = cs[1] * pow(1 + options.scaleStep / 2, parabola(scores[0], scores[1], scores[2]))
        }
        return Match(x: peaks[k].x + Double(x0), y: peaks[k].y + Double(y0), scale: finalScale,
                     confidence: max(0, min(1, peaks[k].c)))
    }

    /// Offset (-0.5...0.5) of the vertex of the parabola through (-1,a) (0,b) (1,c).
    private static func parabola(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let den = a - 2 * b + c
        guard den < -1e-12 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (a - c) / den))
    }

    /// NCC of the template against `p` with its centre at (cx, cy) in `p`'s pixels; `f` is the level's decimation.
    private static func ncc(_ t: Template, _ p: Plane, _ cx: Double, _ cy: Double, _ s: Double,
                            _ boxW: Double, _ boxH: Double, _ f: Double) -> Double {
        // Sample spacing in this level's pixels: the box (boxW * s px) spread over t.w samples.
        let sx = boxW * s / Double(t.w) / f, sy = boxH * s / Double(t.h) / f
        var sum: Float = 0, sumSq: Float = 0, cross: Float = 0
        let n = t.w * t.h
        let ox = cx - (Double(t.w) - 1) / 2 * sx, oy = cy - (Double(t.h) - 1) / 2 * sy
        var k = 0
        for j in 0..<t.h {
            let yy = oy + Double(j) * sy
            for i in 0..<t.w {
                let v = p.bilinear(ox + Double(i) * sx, yy)
                sum += v; sumSq += v * v; cross += v * t.d[k]
                k += 1
            }
        }
        let varSum = sumSq - sum * sum / Float(n)
        guard varSum > 1e-9, t.norm > 0 else { return 0 }
        return Double(cross / (varSum.squareRoot() * t.norm))
    }
}
