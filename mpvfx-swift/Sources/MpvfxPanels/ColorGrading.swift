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

/// The color-grading model (color-grading contract v2) as a native
/// value type. Stored on the clip as an effect (`effectId: "color-grading"`, parameters = this object in its
/// JSON shape), so it rides the existing document schema, undo and save paths.
public struct ColorGrading: Equatable, Sendable {
    public static let effectId = "color-grading"
    public static let contractVersion = 2
    public static let maxCurvePoints = 16, maxSecondaries = 4
    public static let adjustKeys = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature", "tint", "vibrance", "saturation"]
    public static let wheelKeys = ["shadows", "midtones", "highlights"]
    public static let curveKeys = ["master", "red", "green", "blue"]
    public static let hueCurveKeys = ["hueVsHue", "hueVsSaturation", "hueVsLuma"]
    public static let detailKeys = ["vignette", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "grain", "grainSize", "grainRoughness"]
    public static let detailDefaults: [String: Double] = ["vignetteMidpoint": 0.5, "vignetteFeather": 0.65, "grainSize": 0.25, "grainRoughness": 0.5]

    public struct Wheel: Equatable, Sendable {
        public var hue = 0.0, amount = 0.0, level = 0.0
        public init(hue: Double = 0, amount: Double = 0, level: Double = 0) { self.hue = hue; self.amount = amount; self.level = level }
        public var isNeutral: Bool { abs(amount) < 1e-9 && abs(level) < 1e-9 }
    }
    public struct Secondary: Equatable, Sendable {
        public var enabled = true
        public var hueCenter = 0.0, hueRange = 30.0, hueSoftness = 20.0
        public var satMin = 0.0, satMax = 1.0, satSoftness = 0.1
        public var lumaMin = 0.0, lumaMax = 1.0, lumaSoftness = 0.1
        public var hueShift = 0.0, saturation = 0.0, luma = 0.0, temperature = 0.0, tint = 0.0
        public init() {}
    }
    public struct Lut: Equatable, Sendable { public var src: String; public var intensity: Double
        public init(src: String, intensity: Double = 1) { self.src = src; self.intensity = intensity } }

    public var enabled = true
    public var preset: String? = nil
    public var intensity = 1.0
    public var adjust: [String: Double] = [:]
    public var wheels: [String: Wheel] = [:]
    /// (input, output) in 0…1, sorted by input. Empty = identity.
    public var curves: [String: [[Double]]] = [:]
    /// (hue degrees, delta). Empty = flat.
    public var hueCurves: [String: [[Double]]] = [:]
    public var secondaries: [Secondary] = []
    public var details: [String: Double] = [:]
    public var effects: [String: Double] = [:]
    public var palette: [String]? = nil
    public var lut: Lut? = nil

    public init() {}

    /// The value the renderer draws: the stored one, else the named preset's, else the contract default
    /// (`ColorGradeParams` reads a missing key the same way).
    public func adjustValue(_ k: String) -> Double { adjust[k] ?? presetValues?.adjust[k] ?? 0 }
    public func detail(_ k: String) -> Double { details[k] ?? presetValues?.details[k] ?? Self.detailDefaults[k] ?? 0 }
    public func wheel(_ k: String) -> Wheel { wheels[k] ?? Wheel() }
    /// A stylize effect value as rendered: stored, else the preset's, else the contract default.
    public func effect(_ k: String) -> Double { effects[k] ?? presetValues?.effects[k] ?? GradeValues.effectDefaults[k] ?? 0 }
    /// The named preset's values, which fill the keys the grade leaves out; nil for no preset or an unknown name.
    var presetValues: Preset? { preset.flatMap(Self.preset) }
    /// A control's own default (what a reset writes): 0 for an adjust key, the contract default for a detail.
    public static func defaultDetail(_ k: String) -> Double { detailDefaults[k] ?? 0 }
    public func curve(_ k: String) -> [[Double]] { let c = curves[k] ?? []; return c.isEmpty ? [[0, 0], [1, 1]] : c }
    public func hueCurve(_ k: String) -> [[Double]] { hueCurves[k] ?? [] }

    /// Anything differs from neutral (`hasHfColorGradingAuthoredValues`).
    public var isAuthored: Bool {
        preset.map { $0 != "neutral" } ?? false || adjust.values.contains { abs($0) > 1e-6 }
            || wheels.values.contains { !$0.isNeutral } || curves.values.contains { !$0.isEmpty && $0 != [[0, 0], [1, 1]] }
            || hueCurves.values.contains { !$0.isEmpty } || !secondaries.isEmpty || lut != nil
            || Self.detailKeys.contains { abs(detail($0) - (Self.detailDefaults[$0] ?? 0)) > 1e-6 }
            || effects.contains { k, v in Self.activeEffectKeys.contains(k) && v > 1e-4 }
    }

    /// Applies a preset (adjust/details/effects replaced by the preset's values; wheels/curves/LUT kept).
    public func applying(_ p: Preset) -> ColorGrading {
        var g = self
        g.preset = p.id; g.intensity = p.intensity; g.adjust = p.adjust; g.details = p.details
        g.effects = g.effects.filter { !Self.activeEffectKeys.contains($0.key) }.merging(p.effects) { _, b in b }
        return g
    }

    // MARK: JSON (the stored object shape)

    public var json: NativeJSONObject {
        var o = NativeJSONObject()
        func num(_ d: [String: Double], keys: [String]) -> NativeJSONValue {
            var m = NativeJSONObject(); for k in keys { if let v = d[k] { m[k] = .number(v) } }; return .object(m)
        }
        func pts(_ p: [[Double]]) -> NativeJSONValue { .array(p.map { .array($0.map { .number($0) }) }) }
        o["enabled"] = .bool(enabled)
        o["preset"] = preset.map { .string($0) } ?? .null
        o["intensity"] = .number(intensity)
        o["adjust"] = num(adjust, keys: Self.adjustKeys)
        if !wheels.isEmpty {
            var w = NativeJSONObject()
            for k in Self.wheelKeys { if let v = wheels[k] { w[k] = .object(["hue": .number(v.hue), "amount": .number(v.amount), "level": .number(v.level)]) } }
            o["wheels"] = .object(w)
        }
        if !curves.isEmpty { var c = NativeJSONObject(); for k in Self.curveKeys { if let v = curves[k] { c[k] = pts(v) } }; o["curves"] = .object(c) }
        if !hueCurves.isEmpty { var c = NativeJSONObject(); for k in Self.hueCurveKeys { if let v = hueCurves[k] { c[k] = pts(v) } }; o["hueCurves"] = .object(c) }
        if !secondaries.isEmpty {
            o["secondaries"] = .array(secondaries.map { s in .object([
                "enabled": .bool(s.enabled),
                "key": .object([
                    "hue": .object(["center": .number(s.hueCenter), "range": .number(s.hueRange), "softness": .number(s.hueSoftness)]),
                    "saturation": .object(["min": .number(s.satMin), "max": .number(s.satMax), "softness": .number(s.satSoftness)]),
                    "luma": .object(["min": .number(s.lumaMin), "max": .number(s.lumaMax), "softness": .number(s.lumaSoftness)]),
                ]),
                "correction": .object(["hueShift": .number(s.hueShift), "saturation": .number(s.saturation), "luma": .number(s.luma),
                                       "temperature": .number(s.temperature), "tint": .number(s.tint)]),
            ]) })
        }
        o["details"] = num(details, keys: Self.detailKeys)
        if !effects.isEmpty { var e = NativeJSONObject(); for (k, v) in effects.sorted(by: { $0.key < $1.key }) { e[k] = .number(v) }; o["effects"] = .object(e) }
        o["palette"] = palette.map { .array($0.map { .string($0) }) } ?? .null
        o["lut"] = lut.map { .object(["src": .string($0.src), "intensity": .number($0.intensity)]) } ?? .null
        o["colorSpace"] = .string("rec709")
        return o
    }

    public init(json o: NativeJSONObject) {
        func n(_ v: NativeJSONValue?) -> Double? { if case .number(let d)? = v { return d }; return nil }
        func obj(_ v: NativeJSONValue?) -> NativeJSONObject? { if case .object(let x)? = v { return x }; return nil }
        func nums(_ v: NativeJSONValue?) -> [String: Double] {
            var out: [String: Double] = [:]; if let m = obj(v) { for k in m.keys { if let d = n(m[k]) { out[k] = d } } }; return out
        }
        func pts(_ v: NativeJSONValue?) -> [[Double]] {
            guard case .array(let a)? = v else { return [] }
            return a.compactMap { p in if case .array(let xy) = p, xy.count == 2, let x = n(xy[0]), let y = n(xy[1]) { return [x, y] }; return nil }
        }
        if case .bool(let b)? = o["enabled"] { enabled = b }
        preset = Self.presetId(o["preset"])
        // Numbers are read by the renderer's rules (GradeValues): coerced like JS Number(), clamped to the contract,
        // a null taking the preset's value; keys the grade leaves out stay out and read through the preset.
        let p = presetValues
        intensity = GradeValues.intensity(o["intensity"], fallback: p?.intensity ?? 1)
        adjust = Self.limitedValues(obj(o["adjust"]), keys: Self.adjustKeys, fallback: { p?.adjust[$0] ?? 0 }, GradeValues.adjustLimit)
        if let w = obj(o["wheels"]) {
            for k in Self.wheelKeys {
                guard let x = obj(w[k]) else { continue }
                wheels[k] = Wheel(hue: GradeValues.wrapDegrees(x["hue"]), amount: GradeValues.limited(x["amount"], fallback: 0, GradeValues.wheelAmountLimit),
                                  level: GradeValues.limited(x["level"], fallback: 0, GradeValues.wheelLevelLimit))
            }
        }
        if let c = obj(o["curves"]) { for k in c.keys { curves[k] = pts(c[k]) } }
        if let c = obj(o["hueCurves"]) { for k in c.keys { hueCurves[k] = pts(c[k]) } }
        if case .array(let a)? = o["secondaries"] {
            secondaries = a.compactMap { v in
                guard let x = obj(v) else { return nil }
                var s = Secondary()
                if case .bool(let b)? = x["enabled"] { s.enabled = b }
                let key = obj(x["key"]), hue = obj(key?["hue"]), sat = obj(key?["saturation"]), luma = obj(key?["luma"]), cor = obj(x["correction"])
                s.hueCenter = n(hue?["center"]) ?? s.hueCenter; s.hueRange = n(hue?["range"]) ?? s.hueRange; s.hueSoftness = n(hue?["softness"]) ?? s.hueSoftness
                s.satMin = n(sat?["min"]) ?? s.satMin; s.satMax = n(sat?["max"]) ?? s.satMax; s.satSoftness = n(sat?["softness"]) ?? s.satSoftness
                s.lumaMin = n(luma?["min"]) ?? s.lumaMin; s.lumaMax = n(luma?["max"]) ?? s.lumaMax; s.lumaSoftness = n(luma?["softness"]) ?? s.lumaSoftness
                s.hueShift = n(cor?["hueShift"]) ?? 0; s.saturation = n(cor?["saturation"]) ?? 0; s.luma = n(cor?["luma"]) ?? 0
                s.temperature = n(cor?["temperature"]) ?? 0; s.tint = n(cor?["tint"]) ?? 0
                return s
            }
        }
        details = Self.limitedValues(obj(o["details"]), keys: Self.detailKeys, fallback: { p?.details[$0] ?? Self.defaultDetail($0) }, GradeValues.detailLimit)
        effects = Self.limitedValues(obj(o["effects"]), keys: GradeValues.effectKeys, fallback: { p?.effects[$0] ?? GradeValues.effectDefaults[$0] ?? 0 },
                                     GradeValues.effectLimit)
            .merging(nums(o["effects"]).filter { !GradeValues.effectKeys.contains($0.key) }) { a, _ in a }   // keep keys this build does not know
        if case .array(let a)? = o["palette"] { palette = a.compactMap { if case .string(let s) = $0 { return s }; return nil } }
        // A blank source is no LUT; the strength is clamped to 0…1 and a non-number reads as 1, as the renderer does.
        func source(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        if case .string(let s)? = o["lut"], let src = source(s) { lut = Lut(src: src) }
        else if let l = obj(o["lut"]), case .string(let s)? = l["src"], let src = source(s) {
            lut = Lut(src: src, intensity: GradeValues.number(l["intensity"]).flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } ?? 1)
        }
    }

    /// The stored preset id as the renderer reads it: a trimmed string (empty = none) or a number's JS text.
    static func presetId(_ v: NativeJSONValue?) -> String? {
        switch v {
        case .string(let s)?: let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
        case .number(let d)?: return jsNumberString(d)
        default: return nil
        }
    }

    /// The `keys` present in `o`, each read by `GradeValues.limited` with its fallback and limit.
    static func limitedValues(_ o: NativeJSONObject?, keys: [String], fallback: (String) -> Double,
                              _ limit: (String) -> ClosedRange<Double>) -> [String: Double] {
        var out: [String: Double] = [:]
        guard let o else { return out }
        for k in keys where o[k] != nil { out[k] = GradeValues.limited(o[k], fallback: fallback(k), limit(k)) }
        return out
    }

    // MARK: Presets (HF_COLOR_GRADING_PRESETS, values ported verbatim; zero/default entries omitted)

    public struct Preset: Sendable {
        public let id: String, label: String
        /// Grade presets (no stylize effect) appear in the Grade grid; the rest are effect looks.
        public let grade: Bool
        public let intensity: Double
        public let adjust: [String: Double], details: [String: Double], effects: [String: Double]
    }
    public static let presets: [Preset] = [
        .init(id: "neutral", label: "Neutral", grade: true, intensity: 1,
              adjust: [:], details: [:], effects: [:]),
        .init(id: "warm-daylight", label: "Warm Daylight", grade: true, intensity: 1,
              adjust: ["exposure": 0.06, "contrast": 0.07, "highlights": -0.06, "shadows": 0.08, "temperature": 0.18, "saturation": 0.08], details: [:], effects: [:]),
        .init(id: "clean-studio", label: "Clean Studio", grade: true, intensity: 1,
              adjust: ["contrast": 0.08, "highlights": -0.08, "shadows": 0.06, "temperature": -0.08, "tint": 0.03, "saturation": 0.04], details: [:], effects: [:]),
        .init(id: "skin-soft", label: "Skin Soft", grade: true, intensity: 1,
              adjust: ["exposure": 0.04, "contrast": -0.03, "highlights": -0.12, "shadows": 0.12, "temperature": 0.08, "tint": 0.02, "saturation": 0.04], details: [:], effects: [:]),
        .init(id: "food-pop", label: "Food Pop", grade: true, intensity: 1,
              adjust: ["exposure": 0.06, "contrast": 0.1, "shadows": 0.06, "temperature": 0.14, "vibrance": 0.1, "saturation": 0.18], details: [:], effects: [:]),
        .init(id: "night-lift", label: "Night Lift", grade: true, intensity: 1,
              adjust: ["exposure": 0.08, "contrast": 0.08, "highlights": -0.18, "shadows": 0.2, "blacks": -0.08, "saturation": 0.04], details: ["vignette": 0.12], effects: [:]),
        .init(id: "muted-editorial", label: "Muted Editorial", grade: true, intensity: 1,
              adjust: ["exposure": -0.02, "contrast": 0.08, "highlights": -0.08, "shadows": 0.06, "blacks": -0.05, "temperature": -0.03, "saturation": -0.12], details: ["vignette": 0.1], effects: [:]),
        .init(id: "vintage-wash", label: "Vintage Wash", grade: true, intensity: 1,
              adjust: ["exposure": 0.03, "contrast": -0.12, "highlights": -0.1, "shadows": 0.16, "whites": -0.04, "blacks": 0.08, "temperature": 0.13, "vibrance": -0.08, "saturation": -0.08], details: ["vignette": 0.18], effects: [:]),
        .init(id: "mono-clean", label: "Mono Clean", grade: true, intensity: 1,
              adjust: ["contrast": 0.12, "highlights": -0.04, "shadows": 0.04, "blacks": -0.08, "saturation": -1], details: [:], effects: [:]),
        .init(id: "mono-fade", label: "Mono Fade", grade: true, intensity: 1,
              adjust: ["contrast": -0.04, "highlights": -0.06, "shadows": 0.1, "blacks": 0.12, "saturation": -1], details: ["vignette": 0.08], effects: [:]),
        .init(id: "soft-boost", label: "Soft Boost", grade: true, intensity: 1,
              adjust: ["exposure": 0.06, "contrast": -0.04, "highlights": -0.14, "shadows": 0.16, "vibrance": 0.08, "saturation": 0.1], details: [:], effects: [:]),
        .init(id: "bright-pop", label: "Bright Pop", grade: true, intensity: 1,
              adjust: ["exposure": 0.12, "contrast": 0.12, "whites": 0.08, "blacks": -0.04, "vibrance": 0.08, "saturation": 0.14], details: [:], effects: [:]),
        .init(id: "deep-contrast", label: "Deep Contrast", grade: true, intensity: 1,
              adjust: ["exposure": -0.03, "contrast": 0.2, "highlights": -0.08, "shadows": -0.08, "blacks": -0.12, "saturation": 0.06], details: [:], effects: [:]),
        .init(id: "creator-camcorder", label: "Creator Camcorder", grade: false, intensity: 0.72,
              adjust: ["contrast": 0.08, "highlights": -0.05, "shadows": 0.02, "whites": 0.03, "blacks": -0.04, "temperature": -0.03, "tint": -0.015, "vibrance": -0.03, "saturation": -0.06], details: ["vignette": 0.06, "grain": 0.08, "grainSize": 0.18, "grainRoughness": 0.58], effects: ["chromaBleed": 0.55]),
        .init(id: "vhs-playback", label: "VHS Playback", grade: false, intensity: 1,
              adjust: ["contrast": -0.04, "saturation": -0.08], details: ["grain": 0.16, "grainSize": 0.12, "grainRoughness": 0.72], effects: ["chromaBleed": 0.5, "tapeDamage": 0.82, "tapeTracking": 0.85, "tapeNoise": 0.3, "scanlines": 0.35, "scanlineCount": 0.17, "scanlineSoftness": 1, "chromaticAberration": 0.18, "digitalGlitch": 0.32, "digitalGlitchLineTear": 0.08, "digitalGlitchSpeed": 0.5]),
        .init(id: "home-movie-8mm", label: "8mm Home Movie", grade: false, intensity: 0.72,
              adjust: ["exposure": 0.03, "contrast": -0.12, "highlights": -0.1, "shadows": 0.16, "whites": -0.04, "blacks": 0.08, "temperature": 0.13, "vibrance": -0.08, "saturation": -0.08], details: ["vignette": 0.28, "vignetteMidpoint": 0.54, "vignetteFeather": 0.72, "grain": 0.34, "grainSize": 0.18, "grainRoughness": 0.72], effects: ["filmArtifacts": 0.62]),
        .init(id: "editorial-halftone", label: "Editorial Halftone", grade: false, intensity: 1,
              adjust: ["contrast": 0.04, "saturation": 0.04], details: [:], effects: ["halftone": 0.94, "halftoneSize": 0.36]),
        .init(id: "two-ink-print", label: "Two-Ink Print", grade: false, intensity: 1,
              adjust: ["contrast": 0.08, "highlights": -0.06, "shadows": 0.04], details: [:], effects: ["twoInkPrint": 1, "twoInkPrintSize": 0.42]),
    ]
    public static var gradePresets: [Preset] { presets.filter(\.grade) }
    public static func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }

    // MARK: Stylize effects (Effects section: families and amount keys)

    public static let activeEffectKeys = ["blur", "pixelate", "chromaBleed", "tapeDamage", "filmArtifacts", "halftone", "twoInkPrint", "ascii", "dither",
                                          "bloom", "monoScreen", "scanlines", "chromaticAberration", "crtCurvature", "digitalGlitch", "engraving", "crosshatch", "kuwahara"]
    public static let effectFamilies: [(id: String, label: String, effects: [(key: String, label: String)])] = [
        ("essentials", "Essentials", [("blur", "Blur"), ("pixelate", "Pixelate"), ("bloom", "Bloom")]),
        ("retro-glitch", "Retro & Glitch", [("chromaBleed", "Chroma Softening"), ("tapeDamage", "Tape Damage"), ("filmArtifacts", "Film Artifacts"),
                                            ("scanlines", "Scanlines"), ("crtCurvature", "CRT Curvature"), ("chromaticAberration", "Channel Separation"),
                                            ("digitalGlitch", "Digital Glitch")]),
        ("print", "Print", [("halftone", "Halftone"), ("twoInkPrint", "Two-Ink Print"), ("dither", "Ordered Dither"), ("monoScreen", "Mono Screen")]),
        ("art", "Art", [("ascii", "ASCII"), ("engraving", "Engraving"), ("crosshatch", "Crosshatch"), ("kuwahara", "Kuwahara Paint")]),
    ]

    /// Primary adjust sliders (COLOR_GRADING_ADJUST_SLIDERS): key, label, min, max, scale, suffix.
    public static let adjustSliders: [(key: String, label: String, min: Double, max: Double, scale: Double, suffix: String)] = [
        ("exposure", "Exposure", -200, 200, 100, ""), ("contrast", "Contrast", -100, 100, 100, "%"),
        ("highlights", "Highlights", -100, 100, 100, "%"), ("shadows", "Shadows", -100, 100, 100, "%"),
        ("whites", "White Point", -100, 100, 100, "%"), ("blacks", "Black Point", -100, 100, 100, "%"),
        ("temperature", "Warmth", -100, 100, 100, "%"), ("tint", "Tint", -100, 100, 100, "%"),
        ("vibrance", "Vibrance", -100, 100, 100, "%"), ("saturation", "Saturation", -100, 100, 100, "%"),
    ]
    public static let detailSliders: [(key: String, label: String, min: Double, max: Double)] = [
        ("vignette", "Vignette", 0, 100), ("vignetteMidpoint", "Midpoint", 0, 100), ("vignetteRoundness", "Roundness", -100, 100),
        ("vignetteFeather", "Feather", 0, 100), ("grain", "Grain", 0, 100), ("grainSize", "Grain Size", 0, 100), ("grainRoughness", "Roughness", 0, 100),
    ]
}

/// The curve graph's evaluator: the renderer's own normalization and spline (`GradeCurve`, MpvfxShared), so the
/// line drawn is the curve the preview and export apply, it never leaves the graph's range, and it is monotone
/// between monotone points.
public enum ColorCurveMath {
    /// RGB curve (input and output 0…1) at `x`, as rendered.
    public static func sample(_ points: [[Double]], at x: Double) -> Double {
        GradeCurve.valueRGB(GradeCurve.normalizedRGB(points), at: x)
    }
    /// Hue curve (degrees → delta in `limit`) at `hue`, as rendered: flat (0) with fewer than three points.
    public static func sampleHue(_ points: [[Double]], at hue: Double, limit: ClosedRange<Double>) -> Double {
        GradeCurve.valueHue(GradeCurve.normalizedHue(points, limit: limit), at: hue, limit: limit)
    }
    /// `count + 1` evenly spaced samples across the tab's input range (0…1, or 0…360 degrees for hue curves).
    public static func samples(_ points: [[Double]], hue: Bool, limit: ClosedRange<Double>, count: Int) -> [(x: Double, y: Double)] {
        let rgb = GradeCurve.normalizedRGB(points), h = GradeCurve.normalizedHue(points, limit: limit)
        return (0...count).map { k in
            let n = Double(k) / Double(count)
            return hue ? (n * 360, GradeCurve.valueHue(h, at: n * 360, limit: limit)) : (n, GradeCurve.valueRGB(rgb, at: n))
        }
    }
}
