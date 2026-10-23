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
import MpvfxShared

/// The curve compiler: a shape-preserving (Fritsch–Butland style)
/// cubic through the points, sampled into a 1024-entry table the shader reads with linear interpolation.
/// The cubic itself is `GradeCurve` (MpvfxShared), the evaluator the inspector's curve graph draws with too.
public enum ColorCurves {
    public static let lutSize = 1024

    /// RGB curve over input 0…1 (points must start at 0 and end at 1; `ColorGradeParams` guarantees it).
    /// Returns nil for invalid points.
    public static func compile(_ points: [[Double]], size: Int = lutSize) -> [Double]? {
        guard points.count >= 2, points.count <= ColorGradeParams.maxCurvePoints, valid(points),
              points.allSatisfy({ $0[0] >= 0 && $0[0] <= 1 }), points.first?[0] == 0, points.last?[0] == 1 else { return nil }
        return samples(points, size: size, inputAt: { Double($0) / Double(size - 1) }, outputMin: 0, outputMax: 1)
    }

    /// Periodic hue curve over 0…360 degrees (index i is hue i/size*360), outputs clamped to `outputMin…outputMax`.
    public static func compileHue(_ points: [[Double]], outputMin: Double, outputMax: Double, size: Int = lutSize) -> [Double]? {
        guard points.count >= 3, points.count <= ColorGradeParams.maxCurvePoints else { return nil }
        let sorted = points.sorted { $0[0] < $1[0] }
        for (i, p) in sorted.enumerated() {
            guard p[0] >= 0, p[0] < 360 else { return nil }
            if i > 0 && p[0] == sorted[i - 1][0] { return nil }
        }
        let periodic = GradeCurve.periodic(sorted)
        guard valid(periodic) else { return nil }
        return samples(periodic, size: size, inputAt: { Double($0) / Double(size) * 360 }, outputMin: outputMin, outputMax: outputMax)
    }

    public static func compileDelta(_ points: [[Double]], size: Int = lutSize) -> [Double]? {
        samples(GradeCurve.normalizedDelta(points), size: size, inputAt: { Double($0) / Double(size - 1) }, outputMin: -1, outputMax: 1)
    }

    static func valid(_ points: [[Double]]) -> Bool {
        var previous = -Double.infinity
        for p in points {
            guard p.count == 2, p[0].isFinite, p[1].isFinite, p[0] > previous else { return false }
            previous = p[0]
        }
        return true
    }

    static func samples(_ points: [[Double]], size: Int, inputAt: (Int) -> Double, outputMin: Double, outputMax: Double) -> [Double]? {
        guard outputMin < outputMax, !points.contains(where: { $0[1] < outputMin || $0[1] > outputMax }) else { return nil }
        let spline = GradeCurve.Spline(points)
        var out = [Double](repeating: 0, count: size)
        for i in 0..<size {
            let y = spline.value(at: inputAt(i))
            // Float32 storage, as the shader samples it.
            out[i] = Double(Float(Swift.min(outputMax, Swift.max(outputMin, y))))
        }
        return out
    }
}
