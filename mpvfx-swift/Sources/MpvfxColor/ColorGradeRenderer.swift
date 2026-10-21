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

/// Applies one clip's grade and stylize effects to RGBA8 frames (straight alpha, rows top to bottom), exactly as the
/// grading shader defines them. Preview and export both call this, so they produce the same pixels.
///
/// `time` is the composition time in seconds (the shader's `u_effectTime`); the grain seed is the clip's seed plus
/// `floor(time * 60)`. The frame's size is the shader's resolution: effects measured
/// in pixels (grain, print screens, engraving lines) follow the size the clip is drawn at.
public final class ColorGradeRenderer: Equatable, Sendable {
    public let params: ColorGradeParams
    public let lut: CubeLUT?
    public let seed: Int
    public let interpolation: CubeLUT.Interpolation
    let base: GradeProgram

    /// - Parameters:
    ///   - lut: the grade's `.cube`, already loaded (nil skips the LUT stage; `CubeLUTCache` loads them).
    ///   - seedKey: identifies the clip for the grain seed (the clip id).
    public init(params: ColorGradeParams, lut: CubeLUT? = nil, seedKey: String = "", interpolation: CubeLUT.Interpolation = .trilinear) {
        self.params = params; self.lut = lut; self.interpolation = interpolation
        seed = colorGradeSeed(seedKey)
        base = Self.program(params, lut: lut, interpolation: interpolation)
        signature = "\(params.hashValueKey)|\(lut.map { "\($0.size):\($0.table.count):\($0.table.reduce(SIMD3<Float>.zero, +))" } ?? "-")|\(seed)|\(interpolation)"
    }

    /// Renderers that draw the same pixels compare equal.
    public static func == (a: ColorGradeRenderer, b: ColorGradeRenderer) -> Bool { a === b || a.signature == b.signature }

    /// The renderer for a clip's grade, loading its LUT from the project folder; nil when the clip has no active grade.
    public static func forClip(_ params: ColorGradeParams?, clipId: String, projectDir: String?, luts: CubeLUTCache = .shared) -> ColorGradeRenderer? {
        guard let params, params.isActive else { return nil }
        var lut: CubeLUT?
        if let l = params.lut, l.intensity > 0, let path = CubeLUTCache.resolve(l.src, projectDir: projectDir) { lut = luts.lut(at: path) }
        return ColorGradeRenderer(params: params, lut: lut, seedKey: clipId)
    }

    /// A short key that changes whenever the rendered pixels could (cache keys).
    public let signature: String

    public var isActive: Bool { params.isActive }

    /// Grades `rgba` (width * height * 4 bytes, rows top first) in place.
    public func apply(_ rgba: inout [UInt8], width: Int, height: Int, time: Double) {
        guard params.isActive, width > 0, height > 0, rgba.count >= width * height * 4 else { return }
        var p = base.copy()
        p.u.resolution = V2(Float(width), Float(height))
        p.u.effectTime = Float(Swift.max(0, time))
        p.u.grainSeed = Float(seed) + Float((Swift.max(0, time) * 60).rounded(.down))
        // Source texture, flipped into GL orientation (row 0 = bottom), 8-bit values as WebGL samples them.
        var px = [V4](repeating: .zero, count: width * height)
        rgba.withUnsafeBufferPointer { src in
            px.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let srow = y * width * 4, drow = (height - 1 - y) * width
                    for x in 0..<width {
                        let i = srow + x * 4
                        dst[drow + x] = V4(Float(src[i]), Float(src[i + 1]), Float(src[i + 2]), Float(src[i + 3])) / 255
                    }
                }
            }
        }
        p.source = GLTexture(width: width, height: height, px: px)
        if p.blurAmount > 0 { p.prepareBlur(blur: p.blurAmount) }
        if p.bloomAmount > 0 { p.prepareBloom(radius: p.ef(.bloomRadius)) }
        if p.kuwaharaAmount > 0 { p.prepareKuwahara(radius: p.ef(.kuwaharaRadius), sharpness: p.ef(.kuwaharaSharpness), saturation: p.ef(.kuwaharaSaturation)) }
        let prepared = p
        concurrentRows(height, elementsPerRow: width * 4, into: &rgba) { rows in
            var out = [UInt8](repeating: 0, count: rows.count * width * 4)
            for y in rows {
                let gy = height - 1 - y
                let row = (y - rows.lowerBound) * width * 4
                for x in 0..<width {
                    let c = prepared.shade(V2(Float(x) + 0.5, Float(gy) + 0.5))
                    let q = (simdClamp4(c) * 255).rounded(.toNearestOrAwayFromZero)
                    let i = row + x * 4
                    out[i] = UInt8(q.x); out[i + 1] = UInt8(q.y); out[i + 2] = UInt8(q.z); out[i + 3] = UInt8(q.w)
                }
            }
            return out
        }
    }

    /// The grade of one colour, without the spatial effects (scopes, swatches, tests): primary, wheels, curves,
    /// hue curves, secondaries and LUT, mixed by intensity. Inputs and outputs are 0…1.
    public func gradeColor(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        mix(rgb, base.applyColorGrade(rgb), base.u.intensity)
    }

    // MARK: Program setup (the `Ud` uniform upload and `nx` advanced texture)

    static func byte(_ v: Double) -> Float { Float((Swift.min(1, Swift.max(0, v.isFinite ? v : 0)) * 255).rounded(.toNearestOrAwayFromZero)) / 255 }
    /// yt(): a signed value scaled by `limit`, stored around 128.
    static func signedByte(_ v: Double, _ limit: Double) -> Float {
        byte(Swift.min(1, Swift.max(1.0 / 255, (v * (127 / limit) + 128) / 255)))
    }

    static func program(_ g: ColorGradeParams, lut: CubeLUT?, interpolation: CubeLUT.Interpolation) -> GradeProgram {
        var p = GradeProgram()
        var u = GradeUniforms()
        func f(_ d: Double) -> Float { Float(d) }
        u.exposure = f(g.adjust("exposure")); u.contrast = f(g.adjust("contrast")); u.highlights = f(g.adjust("highlights"))
        u.shadows = f(g.adjust("shadows")); u.whites = f(g.adjust("whites")); u.blacks = f(g.adjust("blacks"))
        u.temperature = f(g.adjust("temperature")); u.tint = f(g.adjust("tint")); u.vibrance = f(g.adjust("vibrance")); u.saturation = f(g.adjust("saturation"))
        u.vignette = f(g.detail("vignette")); u.vignetteMidpoint = f(g.detail("vignetteMidpoint")); u.vignetteRoundness = f(g.detail("vignetteRoundness"))
        u.vignetteFeather = f(g.detail("vignetteFeather")); u.grain = f(g.detail("grain")); u.grainSize = f(g.detail("grainSize"))
        u.grainRoughness = f(g.detail("grainRoughness"))
        func wheel(_ k: String) -> V3 { let w = g.wheels[k] ?? .init(); return V3(f(w.hue / 360), f(w.amount), f(w.level)) }
        u.shadowWheel = wheel("shadows"); u.midtoneWheel = wheel("midtones"); u.highlightWheel = wheel("highlights")
        for k in EK.allCases { u.e[k.rawValue] = f(g.effect(k.key)) }
        u.intensity = f(g.intensity)
        u.whiteBalanceGains = g.whiteBalanceGains
        u.pivot = f(g.pivot)
        func balance(_ k: String) -> V3 { let w = g.balance[k] ?? .init(); return V3(f(w.hue / 360), f(w.amount), f(w.level)) }
        u.liftWheel = balance("lift"); u.gammaWheel = balance("gamma"); u.gainWheel = balance("gain"); u.offsetWheel = balance("offset")
        u.balanceOn = g.hasBalance
        if let key = g.colorKey {
            u.keyEnabled = true
            u.keyColor = V3(f(key.color.x), f(key.color.y), f(key.color.z))
            u.keySimilarity = f(key.similarity); u.keySmoothness = f(key.smoothness); u.keySpill = f(key.spill)
        }
        let pal = g.resolvedPalette
        let last = pal.last ?? "#ffffff"
        u.paletteSize = Float(pal.count)
        u.palette = (0..<6).map { i in hexColor(i < pal.count ? pal[i] : last) }

        // Advanced texture rows (uploaded only when curves, hue curves or a correcting secondary are present).
        u.rgbCurvesEnabled = g.hasRgbCurves
        u.hueCurvesEnabled = g.hasHueCurves
        u.secondaryCount = g.hasSecondaryCorrections ? g.secondaries.filter(\.enabled).count : 0
        if u.rgbCurvesEnabled || u.hueCurvesEnabled || u.secondaryCount > 0 {
            let n = ColorCurves.lutSize
            let zero = [Double](repeating: 0, count: n)
            func rgb(_ k: String) -> [Double] { ColorCurves.compile(g.curves[k] ?? ColorGradeParams.curveIdentity) ?? zero }
            func hue(_ k: String, _ lo: Double, _ hi: Double) -> [Double] {
                let pts = g.hueCurves[k] ?? []
                return pts.count >= 3 ? (ColorCurves.compileHue(pts, outputMin: lo, outputMax: hi) ?? zero) : zero
            }
            let r = rgb("red"), gr = rgb("green"), b = rgb("blue"), m = rgb("master")
            let hh = hue("hueVsHue", -180, 180), hs = hue("hueVsSaturation", -1, 1), hl = hue("hueVsLuma", -1, 1)
            p.curveRows = (0..<n).map { V4(byte(r[$0]), byte(gr[$0]), byte(b[$0]), byte(m[$0])) }
            p.hueRows = (0..<n).map { V4(signedByte(hh[$0], 180), signedByte(hs[$0], 1), signedByte(hl[$0], 1), 1) }
            var texels: [V4] = []
            for s in g.secondaries where s.enabled {
                texels.append(V4(byte(s.hueCenter / 360), byte(s.hueRange / 180), byte(s.hueSoftness / 180), 1))
                texels.append(V4(byte(s.saturation.min), byte(s.saturation.max), byte(s.saturation.softness / 0.5), 0))
                texels.append(V4(byte(s.luma.min), byte(s.luma.max), byte(s.luma.softness / 0.5), 0))
                texels.append(V4(signedByte(s.hueShift, 180), signedByte(s.saturationShift, 1), signedByte(s.lumaShift, 1), signedByte(s.temperature, 1)))
                // The second channel flags contract 3 (gain white balance): 1, else the older 0.5.
                texels.append(V4(signedByte(s.tint, 1), byte(g.whiteBalanceGains ? 1 : 0.5), byte(0.5), 1))
            }
            p.secondaryTexels = texels
        }
        if let lut, let l = g.lut, l.intensity > 0 {
            p.lut = lut; u.lutEnabled = true; u.lutIntensity = f(l.intensity)
        }
        p.interpolation = interpolation
        p.u = u
        p.readAmounts()
        return p
    }
}

func hexColor(_ s: String) -> V3 {
    var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    if h.count != 6 { h = "000000" }
    let v = UInt32(h, radix: 16) ?? 0
    return V3(Float((v >> 16) & 0xff) / 255, Float((v >> 8) & 0xff) / 255, Float(v & 0xff) / 255)
}

extension GradeProgram {
    mutating func readAmounts() {
        func c(_ k: EK) -> Float { clampf(ef(k), 0, 1) }
        pixelate = c(.pixelate); tapeDamage = c(.tapeDamage); tapeTracking = c(.tapeTracking); tapeNoise = c(.tapeNoise); tapeSpeed = c(.tapeSpeed)
        chromaBleed = c(.chromaBleed); blurAmount = c(.blur); kuwaharaAmount = c(.kuwahara)
        chromaticAberration = c(.chromaticAberration); chromaticAngle = c(.chromaticAngle); crtCurvature = c(.crtCurvature)
        digitalGlitch = c(.digitalGlitch); filmArtifacts = c(.filmArtifacts); monoScreen = c(.monoScreen); engraving = c(.engraving)
        crosshatch = c(.crosshatch); halftone = c(.halftone); twoInkPrint = c(.twoInkPrint); dither = c(.dither); ascii = c(.ascii)
        bloomAmount = Swift.max(0, ef(.bloom)); scanlines = c(.scanlines)
    }

    /// A program sharing the read-only tables, with its own per-frame state.
    func copy() -> GradeProgram {
        var p = GradeProgram()
        p.u = u; p.curveRows = curveRows; p.hueRows = hueRows; p.secondaryTexels = secondaryTexels
        p.lut = lut; p.interpolation = interpolation
        p.readAmounts()
        return p
    }
}

extension ColorGradeParams {
    /// Stable text of every value (renderer signatures).
    var hashValueKey: String {
        func d(_ m: [String: Double]) -> String { m.keys.sorted().map { "\($0)=\(m[$0]!)" }.joined(separator: ",") }
        let w = ColorGradeParams.wheelKeys.map { k in let x = wheels[k] ?? .init(); return "\(x.hue),\(x.amount),\(x.level)" }.joined(separator: ";")
        let c = ColorGradeParams.curveKeys.map { "\(curves[$0] ?? [])" }.joined(separator: ";")
        let h = ColorGradeParams.hueCurveKeys.map { "\(hueCurves[$0] ?? [])" }.joined(separator: ";")
        let s = secondaries.map { "\($0)" }.joined(separator: ";")
        let b = GradeValues.balanceKeys.map { k in let x = balance[k] ?? .init(); return "\(x.hue),\(x.amount),\(x.level)" }.joined(separator: ";")
        return "v\(version)|p\(pivot)|\(b)|\(intensity)|\(d(adjust))|\(d(details))|\(d(effects))|\(w)|\(c)|\(h)|\(s)|\(palette ?? [])|\(lut.map { "\($0.src)@\($0.intensity)" } ?? "")|\(String(describing: colorKey))"
    }
}
