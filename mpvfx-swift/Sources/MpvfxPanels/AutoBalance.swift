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
import MpvfxShared

/// Automatic colour balance: reads a frame's statistics and moves Exposure, Warmth and Tint so the frame's middle
/// brightness sits at a mid level and its average colour turns neutral. The result is a starting point written into
/// the same grade parameters the sliders edit; nothing else in the grade changes.
///
/// The frame is the one the preview shows (already graded), so the estimate is a correction on top of the current
/// values: pressing the button on a balanced frame changes (almost) nothing. The same frame and grade always give the
/// same values.
public enum AutoBalance {
    /// The brightness (display-referred luma, 0…1) the median pixel is moved to.
    public static let targetMedian = 0.45
    /// Exposure moves by at most this many stops in one run.
    public static let maxStops = 1.0
    /// Pixels outside this luma range are clipped or crushed and say nothing about the colour cast.
    static let colorRange = 0.03...0.97
    /// Below this many usable pixels the frame is too small or too empty to measure.
    static let minimumPixels = 16

    public struct Statistics: Equatable, Sendable {
        /// Median luma over every visible pixel, 0…1.
        public var medianLuma: Double
        /// Mean red, green and blue over the pixels inside `colorRange`; nil when none are.
        public var meanColor: SIMD3<Double>?
        public var pixels: Int
    }

    /// Statistics of the visible pixels of `frame` (alpha 0 is skipped); nil for an empty frame.
    public static func statistics(of frame: CanvasImage) -> Statistics? {
        var histogram = [Int](repeating: 0, count: 256)
        var sum = SIMD3<Double>(repeating: 0), counted = 0, visible = 0
        frame.rgba.withUnsafeBufferPointer { px in
            var o = 0
            while o + 3 < px.count {
                defer { o += 4 }
                guard px[o + 3] > 0 else { continue }
                let c = SIMD3(Double(px[o]), Double(px[o + 1]), Double(px[o + 2])) / 255
                let l = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
                histogram[Int((l * 255).rounded())] += 1
                visible += 1
                if colorRange.contains(l) { sum += c; counted += 1 }
            }
        }
        guard visible >= minimumPixels else { return nil }
        var seen = 0, bin = 0
        while bin < 255, seen + histogram[bin] < (visible + 1) / 2 { seen += histogram[bin]; bin += 1 }
        return Statistics(medianLuma: Double(bin) / 255, meanColor: counted >= minimumPixels ? sum / Double(counted) : nil, pixels: visible)
    }

    /// `grade` with Exposure, Warmth and Tint set from `frame`; nil when the frame has nothing to measure.
    public static func balanced(_ grade: ColorGrading, frame: CanvasImage) -> ColorGrading? {
        guard let stats = statistics(of: frame) else { return nil }
        var next = grade
        let median = max(stats.medianLuma, 1.0 / 255)
        let stops = min(maxStops, max(-maxStops, log2(targetMedian / median)))
        next.adjust["exposure"] = limited("exposure", grade.adjustValue("exposure") + stops)
        if let mean = stats.meanColor, mean.min() > 0.002 {
            let (t, n) = whiteBalance(mean, gains: grade.version >= 3)
            next.adjust["temperature"] = limited("temperature", grade.adjustValue("temperature") + t)
            next.adjust["tint"] = limited("tint", grade.adjustValue("tint") + n)
        }
        return next
    }

    /// The Warmth and Tint change that turns `mean` grey, solved exactly for the shader's two forms: channel gains
    /// (contract 3, `whiteBalanceGain`) or additive offsets (contract 2).
    static func whiteBalance(_ mean: SIMD3<Double>, gains: Bool) -> (temperature: Double, tint: Double) {
        if gains {
            let a = mean.y / mean.x, b = mean.y / mean.z
            let tint = (a + b - 2) / (0.16 * (1 + a + b))
            return ((a - b) * (1 - 0.16 * tint) / 0.32, tint)
        }
        let tint = (2 * mean.y - mean.x - mean.z) / 0.24
        return (((mean.y - mean.x) - 0.12 * tint) / 0.08, tint)
    }

    /// `v` clamped to the key's limit and rounded as the sliders round (3 places).
    static func limited(_ key: String, _ v: Double) -> Double {
        let range = GradeValues.adjustLimit(key)
        return (min(range.upperBound, max(range.lowerBound, v)) * 1000).rounded() / 1000
    }
}
