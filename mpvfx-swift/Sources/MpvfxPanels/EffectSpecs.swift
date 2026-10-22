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

/// The Effects section's catalog: families, each effect's master slider and
/// settings, and the values an effect is added with (HF_COLOR_GRADING_EFFECT_APPLY_DEFAULTS).
public enum EffectSpecs {
    public enum Control {
        /// A slider over `value * scale` in `min…max`, shown with `format` or the value and `unit` (default %).
        case slider(key: String, label: String, min: Double, max: Double, scale: Double, unit: String, format: ((Double) -> String)?)
        case toggle(key: String, label: String)
        case select(key: String, label: String, options: [String])
        public var key: String {
            switch self { case .slider(let k, _, _, _, _, _, _), .toggle(let k, _), .select(let k, _, _): k }
        }
    }
    public struct Spec {
        public let key: String, label: String
        public var showMaster = true
        public var masterLabel = "Mix"
        public var masterFormat: ((Double) -> String)?
        /// Master slider maximum (percent), 100 unless the effect's limit is wider (Bloom 0…3).
        public var max = 100.0
        public var settings: [Control] = []
        /// The effect draws with an ink palette (Ordered Dither, Mono Screen, ASCII: mono; Engraving, Crosshatch: art).
        public var palette: String?
    }
    public struct Family { public let label: String; public let presets: [String]; public let effects: [Spec] }

    static func percent(_ k: String, _ l: String, format: ((Double) -> String)? = nil) -> Control {
        .slider(key: k, label: l, min: 0, max: 100, scale: 100, unit: "%", format: format)
    }
    static func degrees(_ k: String, _ l: String, _ max: Double) -> Control {
        .slider(key: k, label: l, min: 0, max: max, scale: max, unit: "deg", format: nil)
    }

    public static let families: [Family] = [
        Family(label: "Essentials", presets: [], effects: [
            Spec(key: "blur", label: "Blur", masterLabel: "Radius", masterFormat: { String(format: "%.1fpx", 0.75 + pow($0, 1.35) * 32) }),
            Spec(key: "pixelate", label: "Pixelate", masterLabel: "Cell size", masterFormat: { "\(Int((1 + $0 * 47).rounded()))px" }),
            Spec(key: "bloom", label: "Bloom", masterLabel: "Intensity", max: 300,
                 settings: [.slider(key: "bloomRadius", label: "Radius", min: 1, max: 100, scale: 1, unit: "px", format: nil)]),
        ]),
        Family(label: "Retro & glitch", presets: ["creator-camcorder", "vhs-playback", "home-movie-8mm"], effects: [
            Spec(key: "chromaBleed", label: "Chroma softening", masterLabel: "Smear"),
            Spec(key: "tapeDamage", label: "Tape damage", showMaster: false,
                 settings: [percent("tapeTracking", "Tracking"), percent("tapeNoise", "Noise"), percent("tapeSpeed", "Speed")]),
            Spec(key: "filmArtifacts", label: "Film artifacts", masterLabel: "Density"),
            Spec(key: "scanlines", label: "Scanlines", masterLabel: "Opacity",
                 settings: [percent("scanlineCount", "Line count", format: { "\(Int((50 + $0 * 450).rounded()))" }), percent("scanlineSoftness", "Softness")]),
            Spec(key: "crtCurvature", label: "CRT curvature", masterLabel: "Curvature"),
            Spec(key: "chromaticAberration", label: "Channel separation", masterLabel: "Separation", settings: [degrees("chromaticAngle", "Angle", 360)]),
            Spec(key: "digitalGlitch", label: "Digital glitch", showMaster: false, settings: [
                percent("digitalGlitchColorSplit", "Color split"), percent("digitalGlitchLineTear", "Line tear"),
                percent("digitalGlitchPixelate", "Pixelation"), percent("digitalGlitchBlockAmount", "Block amount"),
                percent("digitalGlitchBlockDisplacement", "Displacement"), percent("digitalGlitchBlockOpacity", "Block opacity"),
                percent("digitalGlitchSpeed", "Speed"),
            ]),
        ]),
        Family(label: "Print", presets: ["editorial-halftone", "two-ink-print"], effects: [
            Spec(key: "halftone", label: "Halftone", showMaster: false, settings: [percent("halftoneSize", "Dot size")]),
            Spec(key: "twoInkPrint", label: "Two-ink print", showMaster: false, settings: [percent("twoInkPrintSize", "Dot size")]),
            Spec(key: "dither", label: "Ordered dither", showMaster: false,
                 settings: [percent("ditherSize", "Point size", format: { String(format: "%.1fpx", 1 + $0 * 4) })], palette: "mono"),
            Spec(key: "monoScreen", label: "Mono screen", showMaster: false, settings: [
                percent("monoScreenSize", "Cell size", format: { "\(Int((4 + $0 * 14).rounded()))px" }),
                degrees("monoScreenAngle", "Angle", 90), percent("monoScreenSpread", "Spread"),
                .select(key: "monoScreenShape", label: "Shape", options: ["Circle", "Square", "Diamond", "Triangle", "Line"]),
                .toggle(key: "monoScreenInvert", label: "Invert"),
            ], palette: "mono"),
        ]),
        Family(label: "Art", presets: [], effects: [
            Spec(key: "ascii", label: "ASCII", showMaster: false, settings: [
                percent("asciiSize", "Character size", format: { "\(Int((4 + $0 * 76).rounded()))px" }),
                .select(key: "asciiStyle", label: "Style", options: ["Standard", "Dense", "Minimal", "Blocks", "Braille", "Technical", "Matrix", "Hatching"]),
                .toggle(key: "asciiInvert", label: "Invert"), .toggle(key: "asciiColor", label: "Use source color"),
                percent("asciiRotation", "Edge rotation"),
            ], palette: "mono"),
            Spec(key: "engraving", label: "Engraving", showMaster: false, settings: [
                percent("engravingSpacing", "Spacing"), percent("engravingMinThickness", "Min thickness"),
                percent("engravingMaxThickness", "Max thickness"), degrees("engravingAngle", "Angle", 180),
                percent("engravingContrast", "Contrast"), percent("engravingSharpness", "Sharpness"),
                percent("engravingWave", "Wave"), percent("engravingWaveFrequency", "Wave frequency"),
            ], palette: "art"),
            Spec(key: "crosshatch", label: "Crosshatch", showMaster: false, settings: [
                percent("crosshatchSpacing", "Spacing"), percent("crosshatchThickness", "Thickness"),
                degrees("crosshatchAngle", "Angle", 180), percent("crosshatchContrast", "Contrast"),
                percent("crosshatchEdges", "Edge detail"), percent("crosshatchLineWeight", "Line variation"),
                percent("crosshatchWave", "Wave"), percent("crosshatchWaveFrequency", "Wave frequency"),
            ], palette: "art"),
            Spec(key: "kuwahara", label: "Kuwahara paint", showMaster: false, settings: [
                percent("kuwaharaRadius", "Radius", format: { "\(Int((2 + $0 * 14).rounded()))px" }),
                percent("kuwaharaSharpness", "Sharpness"),
                percent("kuwaharaSaturation", "Saturation", format: { "\(Int(($0 * 200).rounded()))%" }),
            ]),
        ]),
    ]
    public static var all: [Spec] { families.flatMap(\.effects) }
    public static func spec(_ key: String) -> Spec? { all.first { $0.key == key } }

    /// Values an effect is added with (and its settings reset to).
    public static let applyDefaults: [String: [String: Double]] = [
        "blur": ["blur": 0.45], "pixelate": ["pixelate": 0.55], "bloom": ["bloom": 0.55, "bloomRadius": 8],
        "chromaBleed": ["chromaBleed": 0.55],
        "tapeDamage": ["tapeDamage": 0.65, "tapeTracking": 0.55, "tapeNoise": 0.25, "tapeSpeed": 0.5],
        "filmArtifacts": ["filmArtifacts": 0.55],
        "scanlines": ["scanlines": 0.35, "scanlineCount": 0.17, "scanlineSoftness": 1],
        "chromaticAberration": ["chromaticAberration": 0.15, "chromaticAngle": 0], "crtCurvature": ["crtCurvature": 0.2],
        "digitalGlitch": ["digitalGlitch": 0.55, "digitalGlitchColorSplit": 0.25, "digitalGlitchLineTear": 0.25, "digitalGlitchPixelate": 0.15,
                          "digitalGlitchBlockAmount": 0.5, "digitalGlitchBlockDisplacement": 0.25, "digitalGlitchBlockOpacity": 0, "digitalGlitchSpeed": 0.5],
        "halftone": ["halftone": 0.94, "halftoneSize": 0.36], "twoInkPrint": ["twoInkPrint": 1, "twoInkPrintSize": 0.42],
        "ascii": ["ascii": 1, "asciiSize": 5.0 / 76, "asciiInvert": 0, "asciiStyle": 0, "asciiColor": 1, "asciiRotation": 0],
        "dither": ["dither": 1, "ditherSize": 0.5],
        "monoScreen": ["monoScreen": 1, "monoScreenSize": 0.35, "monoScreenAngle": 0.25, "monoScreenSpread": 0.3, "monoScreenShape": 0, "monoScreenInvert": 0],
        "engraving": ["engraving": 1, "engravingSpacing": 7.0 / 17, "engravingMinThickness": 0.2, "engravingMaxThickness": 3.2 / 7, "engravingAngle": 0.25,
                      "engravingContrast": 7.0 / 15, "engravingSharpness": 0.59, "engravingWave": 0.2, "engravingWaveFrequency": 2.0 / 9],
        "crosshatch": ["crosshatch": 1, "crosshatchSpacing": 7.0 / 25, "crosshatchThickness": 0.25, "crosshatchAngle": 0.25, "crosshatchContrast": 1.0 / 3,
                       "crosshatchEdges": 0.5, "crosshatchLineWeight": 0, "crosshatchWave": 0.33, "crosshatchWaveFrequency": 2.0 / 9],
        "kuwahara": ["kuwahara": 1, "kuwaharaRadius": 1.0 / 7, "kuwaharaSharpness": 5.0 / 16, "kuwaharaSaturation": 0.5],
    ]

    /// The contract value of a setting the grade does not store (the non-zero entries of the colour engine's
    /// effect defaults; every other key defaults to 0).
    static let contractDefaults: [String: Double] = [
        "tapeNoise": 1, "tapeSpeed": 0.5, "asciiSize": 5.0 / 76, "asciiColor": 1, "bloomRadius": 8,
        "engravingSpacing": 7.0 / 17, "engravingMinThickness": 0.2, "engravingMaxThickness": 3.2 / 7, "engravingAngle": 0.25,
        "engravingContrast": 7.0 / 15, "engravingSharpness": 0.59, "engravingWave": 0.2, "engravingWaveFrequency": 2.0 / 9,
        "crosshatchSpacing": 7.0 / 25, "crosshatchThickness": 0.25, "crosshatchAngle": 0.25, "crosshatchContrast": 1.0 / 3,
        "crosshatchEdges": 0.5, "crosshatchWave": 0.33, "crosshatchWaveFrequency": 2.0 / 9,
        "kuwaharaRadius": 1.0 / 7, "kuwaharaSharpness": 5.0 / 16, "kuwaharaSaturation": 0.5,
    ]
    /// The value the renderer draws (`ColorGrading.effect`: stored, else the named preset's, else the default).
    public static func value(_ g: ColorGrading, _ key: String) -> Double { g.effect(key) }
    /// A setting's reset value: the effect's add value, else the contract default.
    public static func resetValue(effect: String, _ key: String) -> Double { applyDefaults[effect]?[key] ?? contractDefaults[key] ?? 0 }
    public static func isActive(_ g: ColorGrading, _ key: String) -> Bool { g.effect(key) > 0.0001 }
}
