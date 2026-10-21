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

/// How a stored grade value is read: the one rule set the renderer (MpvfxColor `ColorGradeParams`) and the inspector
/// (MpvfxPanels `ColorGrading`) both apply, so a slider shows the value the preview and export render.
///
/// The two readers once disagreed: the inspector took only JSON numbers, did not clamp and ignored the named preset,
/// while the renderer read strings and booleans as JavaScript `Number()` does, clamped to the contract limits and
/// filled a missing key from the preset. A reset slider then showed 0 while the frame still carried the preset's value,
/// and a value stored as a string rendered but vanished from the inspector and from the next save.
public enum GradeValues {
    /// The primary adjust keys of the colour-grading contract, in panel order.
    public static let adjustKeys = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature", "tint", "vibrance", "saturation"]
    public static let wheelKeys = ["shadows", "midtones", "highlights"]
    public static let detailKeys = ["vignette", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "grain", "grainSize", "grainRoughness"]
    public static let detailDefaults: [String: Double] = ["vignette": 0, "vignetteMidpoint": 0.5, "vignetteRoundness": 0, "vignetteFeather": 0.65,
                                                          "grain": 0, "grainSize": 0.25, "grainRoughness": 0.5]

    /// Exposure is ±2 stops; every other adjust value is -1…1.
    public static func adjustLimit(_ key: String) -> ClosedRange<Double> { key == "exposure" ? -2...2 : -1...1 }
    /// Vignette roundness is -1…1; every other detail value is 0…1.
    public static func detailLimit(_ key: String) -> ClosedRange<Double> { key == "vignetteRoundness" ? -1...1 : 0...1 }
    public static let wheelAmountLimit: ClosedRange<Double> = 0...1
    public static let wheelLevelLimit: ClosedRange<Double> = -1...1

    /// JavaScript `Number(value)` for the JSON values a grade holds; nil for objects and arrays.
    public static func number(_ v: NativeJSONValue?) -> Double? {
        switch v {
        case .number(let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?: let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? 0 : (Double(t) ?? .nan)
        case .null?: return 0
        default: return nil
        }
    }

    /// `readLimitedValue(raw ?? fallback, limit)`: an absent or null value takes `fallback`; a value that is not a
    /// finite number reads as 0; the result is clamped to `limit`.
    public static func limited(_ v: NativeJSONValue?, fallback: Double?, _ limit: ClosedRange<Double>) -> Double {
        let raw: Double?
        if v == nil || v == .null { raw = fallback } else { raw = number(v) ?? .nan }
        guard let x = raw, x.isFinite else { return 0 }
        return Swift.min(limit.upperBound, Swift.max(limit.lowerBound, x))
    }

    /// Degrees wrapped into [0, 360); `fallback` when the value is not a finite number.
    public static func wrapDegrees(_ v: NativeJSONValue?, fallback: Double = 0) -> Double {
        guard let x = number(v), x.isFinite else { return fallback }
        return (x.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The grade's intensity clamped to 0…1. Absent, an object, an array or a non-finite value takes `fallback`;
    /// null reads as 0, as `Number(null)` does.
    public static func intensity(_ v: NativeJSONValue?, fallback: Double) -> Double {
        number(v).map { $0.isFinite ? Swift.min(1, Swift.max(0, $0)) : fallback } ?? fallback
    }
}
