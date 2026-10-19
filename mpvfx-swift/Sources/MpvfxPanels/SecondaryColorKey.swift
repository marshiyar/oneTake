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

/// The Grade secondary's eyedropper and selection matte: sample a qualifier key
/// from a frame around a point, and the 0…1 mask a key selects for a pixel, with the same hue / saturation / luma
/// ranges and softness the grade shader keys with (GradeShader.applySecondary).
public enum SecondaryColorKey {
    /// HSV with hue in degrees (rgbToHsv).
    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), c = mx - mn
        var h = 0.0
        if c > 0 {
            if mx == r { h = ((g - b) / c).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / c + 2 }
            else { h = (r - g) / c + 4 }
            h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        return (h, mx == 0 ? 0 : c / mx, mx)
    }
    static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { r * 0.2126 + g * 0.7152 + b * 0.0722 }

    /// sampleColorGradingSecondary: the alpha-weighted mean of a (2·radius+1)² patch at pixel (x, y) of a straight
    /// RGBA frame. Hue is the saturation-weighted circular mean, range 18°, softness 12° (a neutral sample selects
    /// every hue); saturation and luma ±0.2 around the mean, softness 0.1. Writes the key into `s`; false when the
    /// patch is fully transparent.
    public static func sample(_ image: CanvasImage, x: Double, y: Double, radius: Int = 2, into s: inout ColorGrading.Secondary) -> Bool {
        guard image.width > 0, image.height > 0 else { return false }
        let cx = Int(x.rounded(.down)), cy = Int(y.rounded(.down))
        let x0 = max(0, min(image.width - 1, cx - radius)), x1 = max(0, min(image.width - 1, cx + radius))
        let y0 = max(0, min(image.height - 1, cy - radius)), y1 = max(0, min(image.height - 1, cy + radius))
        var hx = 0.0, hy = 0.0, sat = 0.0, lum = 0.0, weight = 0.0
        for py in y0...y1 { for px in x0...x1 {
            let o = (py * image.width + px) * 4
            let a = Double(image.rgba[o + 3]) / 255
            guard a > 0 else { continue }
            let r = Double(image.rgba[o]) / 255, g = Double(image.rgba[o + 1]) / 255, b = Double(image.rgba[o + 2]) / 255
            let c = hsv(r, g, b), rad = c.h * .pi / 180
            hx += cos(rad) * c.s * a; hy += sin(rad) * c.s * a
            sat += c.s * a; lum += luma(r, g, b) * a; weight += a
        } }
        guard weight > 0 else { return false }
        let hue = (atan2(hy, hx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let ms = sat / weight, ml = lum / weight
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        if ms < 0.02 { s.hueCenter = 0; s.hueRange = 180; s.hueSoftness = 0 }
        else { s.hueCenter = hue; s.hueRange = 18; s.hueSoftness = 12 }
        s.satMin = clamp(ms - 0.2); s.satMax = clamp(ms + 0.2); s.satSoftness = 0.1
        s.lumaMin = clamp(ml - 0.2); s.lumaMax = clamp(ml + 0.2); s.lumaSoftness = 0.1
        return true
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    static func softRange(_ v: Double, _ lo: Double, _ hi: Double, _ soft: Double) -> Double {
        if v < lo { return soft <= 0 ? 0 : smoothstep(lo - soft, lo, v) }
        if v > hi { return soft <= 0 ? 0 : 1 - smoothstep(hi, hi + soft, v) }
        return 1
    }

    /// How strongly the key selects a pixel (colorGradingSecondaryMask; the shader's hue/sat/luma masks).
    public static func mask(_ r: Double, _ g: Double, _ b: Double, _ s: ColorGrading.Secondary) -> Double {
        let c = hsv(max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)))
        var d = abs(c.h - s.hueCenter).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        var m: Double
        if s.hueRange < 179.999 && c.s < 0.001 { m = 0 }
        else if d <= s.hueRange { m = 1 }
        else if s.hueSoftness <= 0 { m = 0 }
        else { m = 1 - smoothstep(s.hueRange, s.hueRange + s.hueSoftness, d) }
        m *= softRange(c.s, s.satMin, s.satMax, s.satSoftness * 0.5)
        m *= softRange(luma(r, g, b), s.lumaMin, s.lumaMax, s.lumaSoftness * 0.5)
        return m
    }

    /// buildColorGradingSecondaryMatte: the mask as grey, alpha kept.
    public static func matte(_ image: CanvasImage, _ s: ColorGrading.Secondary) -> CanvasImage {
        var out = [UInt8](repeating: 0, count: image.rgba.count)
        for o in stride(from: 0, to: image.rgba.count, by: 4) {
            let a = image.rgba[o + 3]
            let v = a == 0 ? 0 : UInt8((mask(Double(image.rgba[o]) / 255, Double(image.rgba[o + 1]) / 255, Double(image.rgba[o + 2]) / 255, s) * 255).rounded())
            out[o] = v; out[o + 1] = v; out[o + 2] = v; out[o + 3] = a
        }
        return CanvasImage(width: image.width, height: image.height, rgba: out)
    }
}
