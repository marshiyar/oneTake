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

/// A clip's color grade and stylize effects, normalized the way the grading engine reads them
/// (`normalizeHfColorGrading`, grading engine 0.8.20 colorGrading.js): every key present, clamped to its contract
/// limit, missing values taken from the named preset (or the contract defaults when there is no preset).
///
/// The clip stores the grade as an effect `{ effectId: "color-grading", parameters: <grade JSON> }`; `init(json:)` reads
/// those parameters, `ColorGradeParams.clipGrade(_:)` finds it on a clip.
public struct ColorGradeParams: Equatable, Sendable {
    public static let effectId = "color-grading"

    public struct Wheel: Equatable, Sendable {
        /// Degrees in [0, 360); amount in [0, 1]; level in [-1, 1].
        public var hue = 0.0, amount = 0.0, level = 0.0
        public init(hue: Double = 0, amount: Double = 0, level: Double = 0) { self.hue = hue; self.amount = amount; self.level = level }
    }
    public struct SoftRange: Equatable, Sendable {
        public var min = 0.0, max = 1.0, softness = 0.05
        public init(min: Double = 0, max: Double = 1, softness: Double = 0.05) { self.min = min; self.max = max; self.softness = softness }
    }
    public struct Secondary: Equatable, Sendable {
        public var enabled = true
        /// Hue qualifier in degrees: centre, half-width, feather.
        public var hueCenter = 0.0, hueRange = 180.0, hueSoftness = 0.0
        public var saturation = SoftRange(), luma = SoftRange()
        /// Correction: hue shift in degrees [-180, 180]; the rest in [-1, 1].
        public var hueShift = 0.0, saturationShift = 0.0, lumaShift = 0.0, temperature = 0.0, tint = 0.0
        public init() {}
        public var hasCorrection: Bool {
            [hueShift, saturationShift, lumaShift, temperature, tint].contains { abs($0) > 0.0001 }
        }
    }
    public struct Lut: Equatable, Sendable {
        public var src: String, intensity: Double
        public init(src: String, intensity: Double = 1) { self.src = src; self.intensity = intensity }
    }

    public var preset: String?
    /// The grade contract the grade was written under (`version`; absent = 2). Contract 3 applies Warmth and Tint as
    /// channel gains, so black stays black; a contract 2 grade keeps the additive offsets it was graded with.
    public var version = 2
    public var intensity = 1.0
    public var adjust: [String: Double] = Self.adjustZero
    public var wheels: [String: Wheel] = ["shadows": Wheel(), "midtones": Wheel(), "highlights": Wheel()]
    public var curves: [String: [[Double]]] = ["master": Self.curveIdentity, "red": Self.curveIdentity, "green": Self.curveIdentity, "blue": Self.curveIdentity]
    public var hueCurves: [String: [[Double]]] = ["hueVsHue": [], "hueVsSaturation": [], "hueVsLuma": []]
    public var secondaries: [Secondary] = []
    public var details: [String: Double] = Self.detailDefaults
    public var effects: [String: Double] = Self.effectDefaults
    public var palette: [String]?
    public var lut: Lut?

    public init() {}

    public func adjust(_ k: String) -> Double { adjust[k] ?? 0 }
    public func detail(_ k: String) -> Double { details[k] ?? Self.detailDefaults[k] ?? 0 }
    public func effect(_ k: String) -> Double { effects[k] ?? Self.effectDefaults[k] ?? 0 }

    // MARK: Contract

    /// The contract new grades are written under (`ColorGrading.contractVersion` in MpvfxPanels).
    public static let currentVersion = 3
    /// Whether Warmth and Tint scale the channels (contract 3) rather than offset them.
    public var whiteBalanceGains: Bool { version >= 3 }

    public static let adjustKeys = GradeValues.adjustKeys
    public static let wheelKeys = GradeValues.wheelKeys
    public static let curveKeys = ["master", "red", "green", "blue"]
    public static let hueCurveKeys = ["hueVsHue", "hueVsSaturation", "hueVsLuma"]
    public static let detailKeys = GradeValues.detailKeys
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
    /// The 18 stylize effects (HF_COLOR_GRADING_ACTIVE_EFFECT_KEYS); the other effect keys are their settings.
    public static let activeEffectKeys = ["blur", "pixelate", "chromaBleed", "tapeDamage", "filmArtifacts", "halftone", "twoInkPrint", "ascii", "dither",
                                          "bloom", "monoScreen", "scanlines", "chromaticAberration", "crtCurvature", "digitalGlitch", "engraving", "crosshatch", "kuwahara"]

    public static let adjustZero: [String: Double] = Dictionary(uniqueKeysWithValues: adjustKeys.map { ($0, 0.0) })
    public static let adjustLimits: [String: ClosedRange<Double>] = Dictionary(uniqueKeysWithValues: adjustKeys.map { ($0, GradeValues.adjustLimit($0)) })
    public static let detailDefaults: [String: Double] = GradeValues.detailDefaults
    public static let detailLimits: [String: ClosedRange<Double>] = Dictionary(uniqueKeysWithValues: detailKeys.map { ($0, GradeValues.detailLimit($0)) })
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
    public static let curveIdentity: [[Double]] = [[0, 0], [1, 1]]
    public static let maxCurvePoints = 16, maxSecondaries = 4

    /// Default ink/paper palettes the shader uses when the grade names none.
    public static let defaultPalette = ["#000000", "#ffffff"]
    public static let printPalette = ["#1a1a1a", "#f5f5dc"]

    // MARK: Presets (HF_COLOR_GRADING_PRESETS: each preset is the contract defaults overlaid with its values)

    public struct Preset: Sendable {
        public let id: String, intensity: Double
        public let adjust: [String: Double], details: [String: Double], effects: [String: Double]
    }
    static func preset(_ id: String, _ adjust: [String: Double] = [:], _ details: [String: Double] = [:], _ effects: [String: Double] = [:], _ intensity: Double = 1) -> Preset {
        Preset(id: id, intensity: intensity, adjust: adjustZero.merging(adjust) { _, b in b },
               details: detailDefaults.merging(details) { _, b in b }, effects: effectDefaults.merging(effects) { _, b in b })
    }
    static let vintageWashAdjust: [String: Double] = ["exposure": 0.03, "contrast": -0.12, "highlights": -0.1, "shadows": 0.16, "whites": -0.04,
                                                      "blacks": 0.08, "temperature": 0.13, "vibrance": -0.08, "saturation": -0.08]
    public static let presets: [Preset] = [
        preset("neutral"),
        preset("warm-daylight", ["exposure": 0.06, "contrast": 0.07, "highlights": -0.06, "shadows": 0.08, "temperature": 0.18, "saturation": 0.08]),
        preset("clean-studio", ["contrast": 0.08, "highlights": -0.08, "shadows": 0.06, "temperature": -0.08, "tint": 0.03, "saturation": 0.04]),
        preset("skin-soft", ["exposure": 0.04, "contrast": -0.03, "highlights": -0.12, "shadows": 0.12, "temperature": 0.08, "tint": 0.02, "saturation": 0.04]),
        preset("food-pop", ["exposure": 0.06, "contrast": 0.1, "shadows": 0.06, "temperature": 0.14, "vibrance": 0.1, "saturation": 0.18]),
        preset("night-lift", ["exposure": 0.08, "contrast": 0.08, "highlights": -0.18, "shadows": 0.2, "blacks": -0.08, "saturation": 0.04], ["vignette": 0.12]),
        preset("muted-editorial", ["exposure": -0.02, "contrast": 0.08, "highlights": -0.08, "shadows": 0.06, "blacks": -0.05, "temperature": -0.03, "saturation": -0.12], ["vignette": 0.1]),
        preset("vintage-wash", vintageWashAdjust, ["vignette": 0.18]),
        preset("mono-clean", ["contrast": 0.12, "highlights": -0.04, "shadows": 0.04, "blacks": -0.08, "saturation": -1]),
        preset("mono-fade", ["contrast": -0.04, "highlights": -0.06, "shadows": 0.1, "blacks": 0.12, "saturation": -1], ["vignette": 0.08]),
        preset("soft-boost", ["exposure": 0.06, "contrast": -0.04, "highlights": -0.14, "shadows": 0.16, "vibrance": 0.08, "saturation": 0.1]),
        preset("bright-pop", ["exposure": 0.12, "contrast": 0.12, "whites": 0.08, "blacks": -0.04, "vibrance": 0.08, "saturation": 0.14]),
        preset("deep-contrast", ["exposure": -0.03, "contrast": 0.2, "highlights": -0.08, "shadows": -0.08, "blacks": -0.12, "saturation": 0.06]),
        preset("creator-camcorder", ["contrast": 0.08, "highlights": -0.05, "shadows": 0.02, "whites": 0.03, "blacks": -0.04, "temperature": -0.03,
                                     "tint": -0.015, "vibrance": -0.03, "saturation": -0.06],
               ["vignette": 0.06, "grain": 0.08, "grainSize": 0.18, "grainRoughness": 0.58], ["chromaBleed": 0.55], 0.72),
        preset("vhs-playback", ["contrast": -0.04, "saturation": -0.08], ["grain": 0.16, "grainSize": 0.12, "grainRoughness": 0.72],
               ["tapeDamage": 0.82, "tapeTracking": 0.85, "tapeNoise": 0.3, "tapeSpeed": 0.5, "chromaBleed": 0.5, "chromaticAberration": 0.18,
                "scanlines": 0.35, "scanlineCount": 0.17, "scanlineSoftness": 1, "digitalGlitch": 0.32, "digitalGlitchLineTear": 0.08, "digitalGlitchSpeed": 0.5]),
        preset("home-movie-8mm", vintageWashAdjust, ["vignette": 0.28, "vignetteMidpoint": 0.54, "vignetteFeather": 0.72, "grain": 0.34, "grainSize": 0.18, "grainRoughness": 0.72],
               ["filmArtifacts": 0.62], 0.72),
        preset("editorial-halftone", ["contrast": 0.04, "saturation": 0.04], [:], ["halftone": 0.94, "halftoneSize": 0.36]),
        preset("two-ink-print", ["contrast": 0.08, "highlights": -0.06, "shadows": 0.04], [:], ["twoInkPrint": 1, "twoInkPrintSize": 0.42]),
    ]
    public static func preset(named id: String?) -> Preset? { id.flatMap { id in presets.first { $0.id == id } } }

    // MARK: Normalization (normalizeHfColorGrading)

    /// nil when the grade is switched off (`enabled: false`).
    public init?(json o: NativeJSONObject) {
        if case .bool(false)? = o["enabled"] { return nil }
        var presetId: String?
        switch o["preset"] {
        case .string(let s)?: let t = s.trimmingCharacters(in: .whitespacesAndNewlines); presetId = t.isEmpty ? nil : t
        case .number(let d)?: presetId = jsNumberString(d)
        default: presetId = nil
        }
        let p = Self.preset(named: presetId)
        preset = presetId
        if let v = Self.number(o["version"]), v.isFinite, v >= 3 { version = 3 }
        let rawAdjust = Self.object(o["adjust"]), rawDetails = Self.object(o["details"])
        let rawEffects = (o["effectsEnabled"] == .bool(false)) ? nil : Self.object(o["effects"])
        for k in Self.adjustKeys { adjust[k] = Self.limited(rawAdjust?[k], fallback: p?.adjust[k] ?? Self.adjustZero[k], GradeValues.adjustLimit(k)) }
        for k in Self.detailKeys { details[k] = Self.limited(rawDetails?[k], fallback: p?.details[k] ?? Self.detailDefaults[k], GradeValues.detailLimit(k)) }
        for k in Self.effectKeys { effects[k] = Self.limited(rawEffects?[k], fallback: p?.effects[k] ?? Self.effectDefaults[k], Self.effectLimit(k)) }
        if o["effectsEnabled"] == .bool(false) { for k in Self.effectKeys { effects[k] = Self.effectDefaults[k] ?? 0 } }
        intensity = GradeValues.intensity(o["intensity"], fallback: p?.intensity ?? 1)
        // wheels
        let w = Self.object(o["wheels"])
        for k in Self.wheelKeys {
            let x = Self.object(w?[k])
            wheels[k] = Wheel(hue: Self.wrapDegrees(x?["hue"]), amount: Self.limited(x?["amount"], fallback: 0, GradeValues.wheelAmountLimit),
                              level: Self.limited(x?["level"], fallback: 0, GradeValues.wheelLevelLimit))
        }
        let c = Self.object(o["curves"])
        for k in Self.curveKeys { curves[k] = Self.normalizeCurve(c?[k]) }
        let h = Self.object(o["hueCurves"])
        for k in Self.hueCurveKeys { hueCurves[k] = Self.normalizeHueCurve(h?[k], limit: k == "hueVsHue" ? -180...180 : -1...1) }
        if case .array(let a)? = o["secondaries"] { secondaries = a.prefix(Self.maxSecondaries).compactMap(Self.normalizeSecondary) }
        if case .array(let a)? = o["palette"], (2...6).contains(a.count) {
            let colors = a.compactMap { v -> String? in
                if case .string(let s) = v, s.range(of: "^#[0-9a-f]{6}$", options: [.regularExpression, .caseInsensitive]) != nil { return s.lowercased() }
                return nil
            }
            palette = colors.count == a.count ? colors : nil
        }
        switch o["lut"] {
        case .string(let s)?: let t = s.trimmingCharacters(in: .whitespacesAndNewlines); lut = t.isEmpty ? nil : Lut(src: t)
        case .object(let l)?:
            if case .string(let s)? = l["src"], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let i = Self.number(l["intensity"]).flatMap { $0.isFinite ? Swift.min(1, Swift.max(0, $0)) : nil } ?? 1
                lut = Lut(src: s.trimmingCharacters(in: .whitespacesAndNewlines), intensity: i)
            }
        default: break
        }
    }

    /// The enabled `color-grading` effect on a clip, normalized; nil when the clip has none (or it is switched off).
    public static func clipGrade(_ clip: NativeProjectClip) -> ColorGradeParams? {
        // The panels keep one grade per clip, the first `color-grading` effect (TimelineEditor.colorGrading).
        guard let e = clip.effects.first(where: { $0.effectId == effectId }), e.enabled else { return nil }
        return ColorGradeParams(json: e.parameters ?? NativeJSONObject())
    }

    // MARK: Activity (isHfColorGradingActive)

    public var hasWheelGrade: Bool { Self.wheelKeys.contains { k in let w = wheels[k] ?? Wheel(); return abs(w.amount) > 0.0001 || abs(w.level) > 0.0001 } }
    public var hasRgbCurves: Bool { Self.curveKeys.contains { k in (curves[k] ?? []).contains { abs($0[0] - $0[1]) > 0.0001 } } }
    public var hasHueCurves: Bool { Self.hueCurveKeys.contains { k in (hueCurves[k] ?? []).contains { abs($0[1]) > 0.0001 } } }
    public var hasSecondaryCorrections: Bool { secondaries.contains { $0.enabled && $0.hasCorrection } }

    /// Whether the grade changes any pixel (an inactive grade draws nothing).
    public var isActive: Bool {
        if abs(detail("vignette")) > 0.0001 || abs(detail("grain")) > 0.0001 || Self.activeEffectKeys.contains(where: { abs(effect($0)) > 0.0001 }) { return true }
        if intensity == 0 { return false }
        if let lut, lut.intensity != 0 { return true }
        return Self.adjustKeys.contains { abs(adjust($0)) > 0.0001 } || hasWheelGrade || hasRgbCurves || hasHueCurves || hasSecondaryCorrections
    }

    /// Whether the picture changes over time on a still frame (grain, film dust, tape, glitch, waving hatch lines).
    public var isTimeVarying: Bool {
        effect("filmArtifacts") > 0 || detail("grain") > 0 || (effect("tapeDamage") > 0 && effect("tapeSpeed") > 0)
            || (effect("digitalGlitch") > 0 && effect("digitalGlitchSpeed") > 0) || (effect("crosshatch") > 0 && effect("crosshatchWave") > 0)
    }

    /// Effects that sample neighbouring pixels (their result depends on the frame's size, not only on each pixel).
    public var isPointwise: Bool {
        !["blur", "pixelate", "chromaBleed", "tapeDamage", "filmArtifacts", "halftone", "twoInkPrint", "ascii", "dither", "bloom",
          "monoScreen", "scanlines", "chromaticAberration", "crtCurvature", "digitalGlitch", "engraving", "crosshatch", "kuwahara"]
            .contains { effect($0) > 0 } && detail("vignette") <= 0 && detail("grain") <= 0
    }

    /// The ink/paper palette the stylize effects draw with.
    public var resolvedPalette: [String] {
        palette ?? (effect("engraving") > 0 || effect("crosshatch") > 0 ? Self.printPalette : Self.defaultPalette)
    }

    // MARK: Helpers

    static func object(_ v: NativeJSONValue?) -> NativeJSONObject? { if case .object(let o)? = v { return o }; return nil }
    /// The reading rules are `GradeValues` (MpvfxShared), shared with the inspector so it shows what renders.
    static func number(_ v: NativeJSONValue?) -> Double? { GradeValues.number(v) }
    static func limited(_ v: NativeJSONValue?, fallback: Double?, _ limit: ClosedRange<Double>) -> Double {
        GradeValues.limited(v, fallback: fallback, limit)
    }
    static func wrapDegrees(_ v: NativeJSONValue?, fallback: Double = 0) -> Double { GradeValues.wrapDegrees(v, fallback: fallback) }
    /// Parses the stored points; the clamping, ordering and end points are `GradeCurve`'s, which the curve graph
    /// draws with, so the graph shows the curve this renders.
    static func normalizeCurve(_ v: NativeJSONValue?) -> [[Double]] {
        guard let points = numericPoints(v) else { return curveIdentity }
        return GradeCurve.normalizedRGB(points)
    }
    static func normalizeHueCurve(_ v: NativeJSONValue?, limit: ClosedRange<Double>) -> [[Double]] {
        guard let points = numericPoints(v) else { return [] }
        return GradeCurve.normalizedHue(points, limit: limit)
    }
    /// `[[x, y], ...]` with finite numbers, else nil.
    static func numericPoints(_ v: NativeJSONValue?) -> [[Double]]? {
        guard case .array(let a)? = v else { return nil }
        var points: [[Double]] = []
        for p in a {
            guard case .array(let xy) = p, xy.count == 2, let x = number(xy[0]), let y = number(xy[1]), x.isFinite, y.isFinite else { return nil }
            points.append([x, y])
        }
        return points
    }
    static func softRange(_ o: NativeJSONObject?) -> SoftRange {
        let a = limited(o?["min"], fallback: 0, 0...1), b = limited(o?["max"], fallback: 1, 0...1)
        return SoftRange(min: Swift.min(a, b), max: Swift.max(a, b), softness: limited(o?["softness"], fallback: 0.05, 0...0.5))
    }
    static func normalizeSecondary(_ v: NativeJSONValue) -> Secondary? {
        guard case .object(let x) = v, let key = object(x["key"]), let cor = object(x["correction"]) else { return nil }
        var s = Secondary()
        if case .bool(false)? = x["enabled"] { s.enabled = false }
        let hue = object(key["hue"])
        s.hueRange = limited(hue?["range"], fallback: 180, 0...180)
        s.hueCenter = wrapDegrees(hue?["center"])
        s.hueSoftness = limited(hue?["softness"], fallback: 0, 0...(180 - s.hueRange))
        s.saturation = softRange(object(key["saturation"]))
        s.luma = softRange(object(key["luma"]))
        s.hueShift = limited(cor["hueShift"], fallback: 0, -180...180)
        s.saturationShift = limited(cor["saturation"], fallback: 0, -1...1)
        s.lumaShift = limited(cor["luma"], fallback: 0, -1...1)
        s.temperature = limited(cor["temperature"], fallback: 0, -1...1)
        s.tint = limited(cor["tint"], fallback: 0, -1...1)
        return s
    }
}

/// FNV-1a over UTF-16 units, modulo 10000: the per-clip grain seed (`Nb`).
public func colorGradeSeed(_ key: String) -> Int {
    var h: UInt32 = 2_166_136_261
    for u in key.utf16 { h ^= UInt32(u); h = h &* 16_777_619 }
    return Int(h % 10_000)
}
