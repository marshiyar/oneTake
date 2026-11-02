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
import OneTakeMedia

/// Frame mixing for slow motion (`speedRamp.blend` "mix", `clip.frameBlend` "mix"): where a clip plays slower than 1x
/// each output frame is the two source frames around its mapped source position, blended by the position's fraction
/// in linear light (decode, convert to linear, mix, encode), so a mix of black and white is the linear-light midpoint
/// (sRGB 188) and not a darker 128. Preview's decode streams and export's frame decoder both read through `frame`, so
/// they show the same picture; the grade is applied to the mixed frame afterwards.
public enum FrameMix {
    /// Fractions below this show the source frame itself.
    static let epsilon = 1e-3

    /// The last two source frames one reader decoded, kept for the next output frame. Slow motion shows each pair of
    /// neighbouring source frames for several output frames and then moves on by one frame, so a mixed frame costs
    /// one new decode at most and the reader only ever reads forward (reading frame A again would seek back to a
    /// keyframe and decode the whole group of pictures again).
    public final class SourceFrames {
        private var frames: [Int: CanvasImage] = [:]
        private var size = (width: 0, height: 0)
        public init() {}

        /// Source frame `index` of `reader` at width × height, read at the frame's centre so the engine picks the intended
        /// frame whatever the rounding of the timestamps.
        func frame(_ reader: VideoFrameReader, index: Int, width: Int, height: Int) throws -> CanvasImage {
            if size.width != width || size.height != height { frames = [:]; size = (width, height) }
            if let cached = frames[index] { return cached }
            let fps = reader.info.frameRate
            let picture = try reader.frame(at: (Double(index) + 0.5) / fps, width: width, height: height)
            let image = CanvasImage(width: width, height: height, rgba: picture.rgba)
            frames[index] = image
            if frames.count > 2, let oldest = frames.keys.min(), oldest != index { frames[oldest] = nil }
            return image
        }
    }

    /// The picture of `reader` at `time`, at width × height. With `mix`, the two source frames around `time` blended
    /// by its fraction; at a frame, or when the next frame lies past the end of the media, the frame itself.
    /// `sources` keeps the frames a mix decoded for the next call (pass the same one for every call on a reader).
    public static func frame(_ reader: VideoFrameReader, at time: Double, mix: Bool, width: Int, height: Int,
                             sources: SourceFrames? = nil) throws -> CanvasImage {
        let fps = reader.info.frameRate
        guard mix, fps > 0, time.isFinite, time >= 0, Double(Int((time * fps + 1e-6).rounded(.down))) / fps < reader.info.duration - 1e-6 else {
            return CanvasImage(width: width, height: height, rgba: try reader.frame(at: time, width: width, height: height).rgba)
        }
        let sources = sources ?? SourceFrames()
        let index = Int((time * fps + 1e-6).rounded(.down))
        let fraction = time * fps - Double(index)
        // On a frame (or no next frame): the frame itself, read through the cache like the frames of a mix.
        guard fraction > epsilon, Double(index + 1) / fps < reader.info.duration - 1e-6 else {
            return try sources.frame(reader, index: index, width: width, height: height)
        }
        let a = try sources.frame(reader, index: index, width: width, height: height)
        let b = try sources.frame(reader, index: index + 1, width: width, height: height)
        return mixed(a, b, fraction: min(fraction, 1))
    }

    /// `a` at (1 − fraction) and `b` at fraction, in linear light, with straight alpha (colours weighted by their
    /// alpha, so a transparent letterbox edge does not darken the mix). Exactly `a` at 0 and `b` at 1.
    public static func mixed(_ a: CanvasImage, _ b: CanvasImage, fraction: Double) -> CanvasImage {
        guard a.width == b.width, a.height == b.height, a.rgba.count == b.rgba.count, a.rgba.count == a.width * a.height * 4 else { return a }
        if fraction <= 0 { return a }
        if fraction >= 1 { return b }
        let f = Float(fraction)
        var out = [UInt8](repeating: 0, count: a.rgba.count)
        let rows = a.height, rowBytes = a.width * 4
        a.rgba.withUnsafeBufferPointer { pa in
            b.rgba.withUnsafeBufferPointer { pb in
                out.withUnsafeMutableBufferPointer { po in
                    let (toLinear, fromLinear) = (Tables.toLinear, Tables.fromLinear)
                    let (src, dst) = (pa, po)
                    DispatchQueue.concurrentPerform(iterations: rows) { y in
                        var i = y * rowBytes
                        let end = i + rowBytes
                        while i < end {
                            let wa = (1 - f) * Float(src[i + 3]) / 255, wb = f * Float(pb[i + 3]) / 255
                            let alpha = wa + wb
                            if alpha > 0 {
                                for c in 0..<3 {
                                    let linear = (toLinear[Int(src[i + c])] * wa + toLinear[Int(pb[i + c])] * wb) / alpha
                                    dst[i + c] = fromLinear[Tables.index(linear)]
                                }
                                dst[i + 3] = UInt8(min(255, (alpha * 255).rounded()))
                            }
                            i += 4
                        }
                    }
                }
            }
        }
        return CanvasImage(width: a.width, height: a.height, rgba: out)
    }

    /// sRGB transfer tables: byte to linear light, and linear light (in 1/steps) back to the nearest byte.
    enum Tables {
        static let steps = 16384
        static let toLinear: [Float] = (0..<256).map { v in
            let c = Double(v) / 255
            return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        static let fromLinear: [UInt8] = (0...steps).map { i in
            let l = Double(i) / Double(steps)
            let c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, (c * 255).rounded())))
        }
        @inline(__always) static func index(_ linear: Float) -> Int { max(0, min(steps, Int(linear * Float(steps) + 0.5))) }
    }
}
