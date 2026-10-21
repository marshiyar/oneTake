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

/// A bounded statistical starting point, written into ordinary editable grade values. The frames are already
/// graded preview frames: the correction is relative to the current grade, not a replacement of its other effects.
public enum LookMatch {
    public struct Statistics: Equatable, Sendable {
        public var mean: SIMD3<Double>
        public var lumaDeviation: Double
        public var pixels: Int
    }

    /// Transparent pixels are excluded. A partial-alpha pixel is weighted by its coverage, so transparent borders
    /// and the RGB bytes of invisible pixels cannot bias the reference.
    public static func statistics(_ frame: CanvasImage) -> Statistics? {
        guard frame.width > 0, frame.height > 0, frame.width <= Int.max / frame.height,
              frame.width * frame.height <= Int.max / 4, frame.rgba.count == frame.width * frame.height * 4 else { return nil }
        var sum = SIMD3<Double>(repeating: 0), weight = 0.0, lumaSum = 0.0, squared = 0.0, count = 0
        for i in stride(from: 0, to: frame.rgba.count, by: 4) {
            let a = Double(frame.rgba[i + 3]) / 255
            guard a > 0 else { continue }
            let c = SIMD3(Double(frame.rgba[i]), Double(frame.rgba[i + 1]), Double(frame.rgba[i + 2])) / 255
            let y = luma(c)
            sum += c * a; weight += a; lumaSum += y * a; squared += y * y * a; count += 1
        }
        guard count >= 16, weight >= 8 else { return nil }
        let average = lumaSum / weight
        return Statistics(mean: sum / weight, lumaDeviation: sqrt(max(0, squared / weight - average * average)), pixels: count)
    }

    /// Fits brightness and contrast, then a bounded RGB residual with the Offset wheel. No palette, curves, LUT,
    /// other wheels or effects are discarded. Identical frames are an exact no-op.
    public static func matched(_ grade: ColorGrading, source: CanvasImage, reference: CanvasImage) -> ColorGrading? {
        guard grade.enabled, grade.intensity > 0, let a = statistics(source), let b = statistics(reference) else { return nil }
        if a.mean == b.mean && abs(a.lumaDeviation - b.lumaDeviation) < 1e-12 { return grade }
        var next = grade
        let exposure = grade.adjustValue("exposure")
        let stops = min(1, max(-1, log2(max(luma(b.mean), 1.0 / 255) / max(luma(a.mean), 1.0 / 255))))
        next.adjust["exposure"] = AutoBalance.limited("exposure", exposure + stops)
        let gain = pow(2, next.adjustValue("exposure") - exposure)
        let oldContrast = max(0.05, 1 + grade.adjustValue("contrast"))
        let correction = a.lumaDeviation > 0.005 && b.lumaDeviation > 0.005
            ? min(2, max(0.5, b.lumaDeviation / (a.lumaDeviation * gain))) : 1
        next.adjust["contrast"] = AutoBalance.limited("contrast", oldContrast * correction - 1)
        let contrastGain = max(0, 1 + next.adjustValue("contrast")) / oldContrast
        let pivot = SIMD3<Double>(repeating: grade.pivotValue)
        let predicted = (a.mean * gain - pivot) * contrastGain + pivot
        let residual = b.mean - predicted
        let old = grade.balanceWheel("offset")
        next.balance["offset"] = wheel(vector(old) + residual)
        return next
    }

    static func luma(_ c: SIMD3<Double>) -> Double { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }

    /// The same normalized hue direction and scales as the shared colour-grade Offset wheel shader.
    static func vector(_ w: ColorGrading.Wheel) -> SIMD3<Double> {
        let h = (w.hue / 60).truncatingRemainder(dividingBy: 6)
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let rgb: SIMD3<Double>
        switch h {
        case ..<1: rgb = SIMD3(1, x, 0)
        case ..<2: rgb = SIMD3(x, 1, 0)
        case ..<3: rgb = SIMD3(0, 1, x)
        case ..<4: rgb = SIMD3(0, x, 1)
        case ..<5: rgb = SIMD3(x, 0, 1)
        default: rgb = SIMD3(1, 0, x)
        }
        let chroma = rgb - SIMD3(repeating: luma(rgb))
        return chroma / max(0.0001, max(abs(chroma.x), max(abs(chroma.y), abs(chroma.z)))) * (w.amount * 0.2)
            + SIMD3(repeating: w.level * 0.25)
    }

    static func wheel(_ rgb: SIMD3<Double>) -> ColorGrading.Wheel {
        let level = luma(rgb), chroma = rgb - SIMD3(repeating: level)
        let low = min(chroma.x, min(chroma.y, chroma.z)), high = max(chroma.x, max(chroma.y, chroma.z)), d = high - low
        var hue = 0.0
        if d > 1e-9 {
            if high == chroma.x { hue = 60 * ((chroma.y - chroma.z) / d).truncatingRemainder(dividingBy: 6) }
            else if high == chroma.y { hue = 60 * ((chroma.z - chroma.x) / d + 2) }
            else { hue = 60 * ((chroma.x - chroma.y) / d + 4) }
        }
        if hue < 0 { hue += 360 }
        func rounded(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return .init(hue: rounded(hue), amount: rounded(min(1, max(abs(chroma.x), max(abs(chroma.y), abs(chroma.z))) / 0.2)),
                     level: rounded(min(1, max(-1, level / 0.25))))
    }
}
