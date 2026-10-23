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
    /// The balance wheels (`balance` in the grade JSON, issue #176), each a colour plus a level like a tonal wheel.
    public static let balanceKeys = ["lift", "gamma", "gain", "offset"]
    /// Where contrast pivots (`pivot`, 0…1 luma): 0.5 when absent, which is how every older grade was drawn.
    public static let defaultPivot = 0.5
    public static let detailKeys = ["vignette", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "grain", "grainSize", "grainRoughness"]
    public static let detailDefaults: [String: Double] = ["vignette": 0, "vignetteMidpoint": 0.5, "vignetteRoundness": 0, "vignetteFeather": 0.65,
                                                          "grain": 0, "grainSize": 0.25, "grainRoughness": 0.5]

    /// The stylize effect amounts and their settings (`effects`), their defaults and limits (0…1 unless listed).
    public static let effectKeys = [
        "blur", "pixelate", "chromaBleed", "tapeDamage", "tapeTracking", "tapeNoise", "tapeSpeed", "filmArtifacts",
        "halftone", "halftoneSize", "twoInkPrint", "twoInkPrintSize", "ascii", "asciiSize", "asciiInvert", "asciiStyle",
        "asciiColor", "asciiRotation", "dither", "ditherSize", "bloom", "bloomRadius", "monoScreen", "monoScreenSize",
        "monoScreenAngle", "monoScreenSpread", "monoScreenShape", "monoScreenInvert", "scanlines", "scanlineCount",
        "scanlineSoftness", "chromaticAberration", "chromaticAngle", "crtCurvature", "digitalGlitch", "digitalGlitchColorSplit",
        "digitalGlitchLineTear", "digitalGlitchPixelate", "digitalGlitchBlockAmount", "digitalGlitchBlockDisplacement",
        "digitalGlitchBlockOpacity", "digitalGlitchSpeed", "engraving", "engravingSpacing", "engravingMinThickness",
        "engravingMaxThickness", "engravingAngle", "engravingContrast", "engravingSharpness", "engravingWave",
        "engravingWaveFrequency", "crosshatch", "crosshatchSpacing", "crosshatchThickness", "crosshatchAngle",
        "crosshatchContrast", "crosshatchEdges", "crosshatchLineWeight", "crosshatchWave", "crosshatchWaveFrequency",
        "kuwahara", "kuwaharaRadius", "kuwaharaSharpness", "kuwaharaSaturation",
    ]
    public static let effectDefaults: [String: Double] = [
        "blur": 0, "pixelate": 0, "chromaBleed": 0, "tapeDamage": 0, "tapeTracking": 0, "tapeNoise": 1, "tapeSpeed": 0.5, "filmArtifacts": 0,
        "halftone": 0, "halftoneSize": 0, "twoInkPrint": 0, "twoInkPrintSize": 0,
        "ascii": 0, "asciiSize": 5.0 / 76, "asciiInvert": 0, "asciiStyle": 0, "asciiColor": 1, "asciiRotation": 0,
        "dither": 0, "ditherSize": 0, "bloom": 0, "bloomRadius": 8,
        "monoScreen": 0, "monoScreenSize": 0, "monoScreenAngle": 0, "monoScreenSpread": 0, "monoScreenShape": 0, "monoScreenInvert": 0,
        "scanlines": 0, "scanlineCount": 0, "scanlineSoftness": 0, "chromaticAberration": 0, "chromaticAngle": 0, "crtCurvature": 0,
        "digitalGlitch": 0, "digitalGlitchColorSplit": 0, "digitalGlitchLineTear": 0, "digitalGlitchPixelate": 0, "digitalGlitchBlockAmount": 0,
        "digitalGlitchBlockDisplacement": 0, "digitalGlitchBlockOpacity": 0, "digitalGlitchSpeed": 0,
        "engraving": 0, "engravingSpacing": 7.0 / 17, "engravingMinThickness": 0.2, "engravingMaxThickness": 3.2 / 7, "engravingAngle": 0.25,
        "engravingContrast": 7.0 / 15, "engravingSharpness": 0.59, "engravingWave": 0.2, "engravingWaveFrequency": 2.0 / 9,
        "crosshatch": 0, "crosshatchSpacing": 7.0 / 25, "crosshatchThickness": 0.25, "crosshatchAngle": 0.25, "crosshatchContrast": 1.0 / 3,
        "crosshatchEdges": 0.5, "crosshatchLineWeight": 0, "crosshatchWave": 0.33, "crosshatchWaveFrequency": 2.0 / 9,
        "kuwahara": 0, "kuwaharaRadius": 1.0 / 7, "kuwaharaSharpness": 5.0 / 16, "kuwaharaSaturation": 0.5,
    ]
    public static let effectLimitOverrides: [String: ClosedRange<Double>] = ["asciiStyle": 0...7, "bloom": 0...3, "bloomRadius": 1...100, "monoScreenShape": 0...4]
    public static func effectLimit(_ k: String) -> ClosedRange<Double> { effectLimitOverrides[k] ?? 0...1 }

    /// Exposure is ±2 stops; every other adjust value is -1…1.
    public static func adjustLimit(_ key: String) -> ClosedRange<Double> { key == "exposure" ? -2...2 : -1...1 }
    /// Vignette roundness is -1…1; every other detail value is 0…1.
    public static func detailLimit(_ key: String) -> ClosedRange<Double> { key == "vignetteRoundness" ? -1...1 : 0...1 }
    public static let wheelAmountLimit: ClosedRange<Double> = 0...1
    public static let wheelLevelLimit: ClosedRange<Double> = -1...1
    /// Default ink/paper palettes the stylize effects draw with when the grade names none
    /// (the renderer accepts 2…6 colours). Kept here, outside the UI modules, so the
    /// no-raw-colours ratchet keeps a single source both the panels and the renderer read.
    public static let defaultPalette = ["#000000", "#ffffff"]
    public static let printPalette = ["#1a1a1a", "#f5f5dc"]

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
