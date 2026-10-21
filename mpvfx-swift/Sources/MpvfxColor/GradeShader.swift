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
import Synchronization

// The grading shader on the CPU (grading engine 0.8.20: the
// fragment program, plus its blur/bloom and Kuwahara passes). Preview and export both run
// it, so the two match. Everything is in the shader's own frame: GL texture space with y up (the source is uploaded
// flipped), gl_FragCoord in pixels from the bottom-left, 32-bit floats.

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>

@inline(__always) func fract(_ x: Float) -> Float { x - x.rounded(.down) }
@inline(__always) func glMod(_ x: Float, _ y: Float) -> Float { x - y * (x / y).rounded(.down) }
@inline(__always) func clampf(_ x: Float, _ a: Float, _ b: Float) -> Float { Swift.min(Swift.max(x, a), b) }
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampf((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
}
@inline(__always) func step(_ edge: Float, _ x: Float) -> Float { x < edge ? 0 : 1 }
@inline(__always) func dot3(_ a: V3, _ b: V3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) func clamp3(_ v: V3, _ a: Float, _ b: Float) -> V3 { V3(clampf(v.x, a, b), clampf(v.y, a, b), clampf(v.z, a, b)) }
@inline(__always) func clampUv(_ uv: V2) -> V2 { V2(clampf(uv.x, 0, 1), clampf(uv.y, 0, 1)) }
@inline(__always) func length2(_ v: V2) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
@inline(__always) func lumaOf(_ c: V3) -> Float { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
@inline(__always) func bt601Luma(_ c: V3) -> Float { c.x * 0.299 + c.y * 0.587 + c.z * 0.114 }
@inline(__always) func grainHash(_ p: V2) -> Float { fract(sin(p.x * 127.1 + p.y * 311.7) * 43758.5453123) }
@inline(__always) func digitalHash(_ p: V2) -> Float {
    let qx = glMod(p.x.rounded(.down), 251), qy = glMod(p.y.rounded(.down), 251)
    let x = glMod(qx * qx * 157 + qx * 89, 251), y = glMod(qy * qy * 113 + qy * 47, 251), xy = glMod(qx * qy * 71, 251)
    return glMod(x + y + xy + 19, 251) / 251
}
@inline(__always) func colorSaturation(_ c: V3) -> Float { Swift.max(Swift.max(c.x, c.y), c.z) - Swift.min(Swift.min(c.x, c.y), c.z) }
let PI: Float = 3.14159265359

/// An RGBA texture in GL orientation (row 0 is the bottom), sampled with clamp-to-edge like WebGL.
struct GLTexture: Sendable {
    var width: Int, height: Int
    var px: [V4]
    var linear = true

    init(width: Int, height: Int, px: [V4], linear: Bool = true) { self.width = width; self.height = height; self.px = px; self.linear = linear }

    @inline(__always) func fetch(_ x: Int, _ y: Int) -> V4 {
        px[Swift.min(Swift.max(y, 0), height - 1) * width + Swift.min(Swift.max(x, 0), width - 1)]
    }
    @inline(__always) func sample(_ uv: V2) -> V4 {
        if !linear { return fetch(Int((uv.x * Float(width)).rounded(.down)), Int((uv.y * Float(height)).rounded(.down))) }
        let tx = uv.x * Float(width) - 0.5, ty = uv.y * Float(height) - 0.5
        let x0f = tx.rounded(.down), y0f = ty.rounded(.down)
        let fx = tx - x0f, fy = ty - y0f
        let x0 = Int(x0f), y0 = Int(y0f)
        let a = fetch(x0, y0), b = fetch(x0 + 1, y0), c = fetch(x0, y0 + 1), d = fetch(x0 + 1, y0 + 1)
        let top = a + (b - a) * fx, bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }
    /// Rounds every channel to 8 bits (an RGBA8 render target).
    mutating func quantize8() { for i in px.indices { px[i] = (simdClamp4(px[i]) * 255).rounded(.toNearestOrAwayFromZero) / 255 } }
}
@inline(__always) func simdClamp4(_ v: V4) -> V4 { V4(clampf(v.x, 0, 1), clampf(v.y, 0, 1), clampf(v.z, 0, 1), clampf(v.w, 0, 1)) }

/// Effect settings by index, so the per-pixel code reads an array instead of hashing names.
enum EK: Int, CaseIterable {
    case blur, pixelate, chromaBleed, tapeDamage, tapeTracking, tapeNoise, tapeSpeed, filmArtifacts, halftone, halftoneSize, twoInkPrint, twoInkPrintSize, ascii, asciiSize, asciiInvert, asciiStyle, asciiColor, asciiRotation, dither, ditherSize, bloom, bloomRadius, monoScreen, monoScreenSize, monoScreenAngle, monoScreenSpread, monoScreenShape, monoScreenInvert, scanlines, scanlineCount, scanlineSoftness, chromaticAberration, chromaticAngle, crtCurvature, digitalGlitch, digitalGlitchColorSplit, digitalGlitchLineTear, digitalGlitchPixelate, digitalGlitchBlockAmount, digitalGlitchBlockDisplacement, digitalGlitchBlockOpacity, digitalGlitchSpeed, engraving, engravingSpacing, engravingMinThickness, engravingMaxThickness, engravingAngle, engravingContrast, engravingSharpness, engravingWave, engravingWaveFrequency, crosshatch, crosshatchSpacing, crosshatchThickness, crosshatchAngle, crosshatchContrast, crosshatchEdges, crosshatchLineWeight, crosshatchWave, crosshatchWaveFrequency, kuwahara, kuwaharaRadius, kuwaharaSharpness, kuwaharaSaturation
    var key: String { String(describing: self) }
}

/// The shader's uniforms, read once from the normalized grade.
struct GradeUniforms: Sendable {
    var resolution = V2(1, 1)
    var exposure: Float = 0, contrast: Float = 0, highlights: Float = 0, shadows: Float = 0, whites: Float = 0, blacks: Float = 0
    var temperature: Float = 0, tint: Float = 0, vibrance: Float = 0, saturation: Float = 0
    var vignette: Float = 0, vignetteMidpoint: Float = 0.5, vignetteRoundness: Float = 0, vignetteFeather: Float = 0.65
    var grain: Float = 0, grainSize: Float = 0.25, grainRoughness: Float = 0.5, grainSeed: Float = 0, effectTime: Float = 0
    var shadowWheel = V3.zero, midtoneWheel = V3.zero, highlightWheel = V3.zero
    var rgbCurvesEnabled = false, hueCurvesEnabled = false, secondaryCount = 0
    var lutEnabled = false, lutIntensity: Float = 0
    /// Warmth and Tint as channel gains (grade contract 3) instead of the older additive offsets (contract 2).
    var whiteBalanceGains = false
    var keyEnabled = false
    var keyColor = V3(0, 1, 0)
    var keySimilarity: Float = 0.1
    var keySmoothness: Float = 0.1
    var keySpill: Float = 0
    var intensity: Float = 1
    var e = [Float](repeating: 0, count: EK.allCases.count)
    var palette: [V3] = []
    var paletteSize: Float = 2
}

/// One grade bound to one frame size and time: the uniforms, curve tables, LUT and multipass textures.
struct GradeProgram: Sendable {
    var u = GradeUniforms()
    // Advanced texture (`u_advanced`, 1024 x 3 RGBA8): row 0 RGB curves (r, g, b, master), row 1 hue curves,
    // row 2 secondary qualifier/correction texels. Stored as byte/255.
    var curveRows: [V4] = []
    var hueRows: [V4] = []
    var secondaryTexels: [V4] = []
    var lut: CubeLUT?
    var interpolation: CubeLUT.Interpolation = .trilinear

    var source = GLTexture(width: 1, height: 1, px: [.zero])
    var blur: GLTexture?
    var bloom: GLTexture?
    var kuwahara: GLTexture?

    // Effect amounts used per pixel, read once.
    var pixelate: Float = 0, tapeDamage: Float = 0, tapeTracking: Float = 0, tapeNoise: Float = 0, tapeSpeed: Float = 0
    var chromaBleed: Float = 0, blurAmount: Float = 0, kuwaharaAmount: Float = 0
    var chromaticAberration: Float = 0, chromaticAngle: Float = 0, crtCurvature: Float = 0
    var digitalGlitch: Float = 0
    var filmArtifacts: Float = 0, monoScreen: Float = 0, engraving: Float = 0, crosshatch: Float = 0, halftone: Float = 0
    var twoInkPrint: Float = 0, dither: Float = 0, ascii: Float = 0, bloomAmount: Float = 0, scanlines: Float = 0

    @inline(__always) func ef(_ k: EK) -> Float { u.e[k.rawValue] }

    // MARK: Sampling

    @inline(__always) func sampleSource(_ uv: V2) -> V4 { source.sample(clampUv(uv)) }

    @inline(__always) func samplePrepared(_ uv: V2) -> V4 {
        var base = sampleSource(uv)
        if blurAmount > 0, let blur { base = base + (blur.sample(clampUv(uv)) - base) * blurAmount }
        if kuwaharaAmount > 0, let kuwahara {
            let k = kuwahara.sample(clampUv(uv))
            base = V4(mixf(base.x, k.x, kuwaharaAmount), mixf(base.y, k.y, kuwaharaAmount), mixf(base.z, k.z, kuwaharaAmount), base.w)
        }
        return base
    }

    @inline(__always) func tapeTrackingBand(_ y: Float, _ center: Float, _ width: Float) -> Float {
        let offset = fract(y - center + 0.5) - 0.5
        let triangle = Swift.max(0, 1 - abs(offset) / Swift.max(width, 0.0001))
        return triangle * triangle * (3 - 2 * triangle)
    }

    func sampleMedia(_ uv: V2, _ frag: V2) -> V4 {
        var sampleUv = uv
        if pixelate > 0 {
            let blockSize = mixf(1, 48, pixelate)
            let cells = V2(Swift.max(u.resolution.x / blockSize, 1), Swift.max(u.resolution.y / blockSize, 1))
            let c = V2(clampf(uv.x, 0, 0.999999), clampf(uv.y, 0, 0.999999))
            sampleUv = V2(((c.x * cells.x).rounded(.down) + 0.5) / cells.x, ((c.y * cells.y).rounded(.down) + 0.5) / cells.y)
        }
        let texelX = 1 / Swift.max(u.resolution.x, 1)
        if tapeDamage <= 0 && chromaBleed <= 0 { return samplePrepared(sampleUv) }
        let tapeTime = u.effectTime * mixf(0, 2, tapeSpeed)
        let tapeFrame = (tapeTime * 60).rounded(.down)
        let tapeLine = (sampleUv.y * u.resolution.y * 0.5).rounded(.down)
        var tapeUv = sampleUv
        if tapeDamage > 0 {
            let lineJitter = (digitalHash(V2(tapeLine, (tapeFrame * 0.5).rounded(.down))) - 0.5) * 1.8 * tapeNoise
            let slowWobble = sin(sampleUv.y * 32 + tapeTime * 2.6) * 0.55
            let headSwitch = smoothstep(0.88, 1, sampleUv.y) * sin(sampleUv.y * 240 + tapeTime * 8) * 4
            var trackingShift = tapeTrackingBand(sampleUv.y, fract(0.08 + tapeTime * 0.083), 0.035)
            trackingShift -= tapeTrackingBand(sampleUv.y, fract(0.28 + tapeTime * 0.061), 0.03) * 0.8
            trackingShift += tapeTrackingBand(sampleUv.y, fract(0.5 + tapeTime * 0.047), 0.04) * 0.75
            trackingShift -= tapeTrackingBand(sampleUv.y, fract(0.72 + tapeTime * 0.037), 0.028) * 0.65
            trackingShift += tapeTrackingBand(sampleUv.y, fract(0.89 + tapeTime * 0.029), 0.032) * 0.55
            trackingShift *= tapeTracking * 48
            let tapeShift = (lineJitter + slowWobble + headSwitch + trackingShift) * tapeDamage
            tapeUv = sampleUv + V2(tapeShift * texelX, 0)
        }
        var base = samplePrepared(tapeUv)
        if tapeDamage > 0 {
            let lumaStep = V2(texelX * mixf(1, 3.5, tapeDamage), 0)
            let left = samplePrepared(tapeUv - lumaStep), right = samplePrepared(tapeUv + lumaStep)
            let b3 = V3(base.x, base.y, base.z)
            let tapeLuma = (bt601Luma(V3(left.x, left.y, left.z)) + bt601Luma(b3) * 2 + bt601Luma(V3(right.x, right.y, right.z))) * 0.25
            let centerChroma = b3 - V3(repeating: bt601Luma(b3))
            var tapeColor = V3(repeating: tapeLuma) + centerChroma
            let ghost = samplePrepared(tapeUv - V2(texelX * 12, 0))
            tapeColor = mix(tapeColor, V3(ghost.x, ghost.y, ghost.z), 0.045 * tapeDamage)
            let fineNoise = digitalHash(V2(frag.x.rounded(.down), frag.y.rounded(.down)) + V2(tapeFrame * 17, tapeFrame * 3)) - 0.5
            let band = digitalHash(V2((sampleUv.y * 92).rounded(.down), (tapeFrame / 3).rounded(.down)))
            let dropout = smoothstep(0.985, 1, band) * (digitalHash(V2((sampleUv.x * 18).rounded(.down), tapeLine)) - 0.5)
            tapeColor += V3(repeating: (fineNoise * 0.035 + dropout * 0.12) * tapeDamage * tapeNoise)
            let m = mix(b3, clamp3(tapeColor, 0, 1), tapeDamage)
            base = V4(m.x, m.y, m.z, base.w)
        }
        if chromaBleed > 0 { base = applyChromaBleed(base, tapeUv, texelX) }
        return base
    }

    /// Chroma bleed: the colour (not the luma) blurred horizontally with 1-4-6-4-1 weights over taps `radius`
    /// texels apart.
    func applyChromaBleed(_ base: V4, _ tapeUv: V2, _ texelX: Float) -> V4 {
        let radius = mixf(1, 4, chromaBleed)
        let stepUv = V2(texelX * radius, 0)
        let c0 = V3(base.x, base.y, base.z)
        func rgb(_ v: V4) -> V3 { V3(v.x, v.y, v.z) }
        let c1 = rgb(samplePrepared(tapeUv - stepUv)), c2 = rgb(samplePrepared(tapeUv + stepUv))
        let c3 = rgb(samplePrepared(tapeUv - stepUv * 2)), c4 = rgb(samplePrepared(tapeUv + stepUv * 2))
        let centerLuma = lumaOf(c0)
        func chroma(_ c: V3) -> V3 { c - V3(repeating: lumaOf(c)) }
        // Summed term by term, left to right, so the type checker sees small expressions.
        var weighted: V3 = chroma(c0) * 6
        weighted += chroma(c1) * 4
        weighted += chroma(c2) * 4
        weighted += chroma(c3)
        weighted += chroma(c4)
        let blurred = weighted / 16
        let m = mix(c0, clamp3(V3(repeating: centerLuma) + blurred, 0, 1), chromaBleed)
        return V4(m.x, m.y, m.z, base.w)
    }

    func sampleChromaticMedia(_ uv: V2, _ center: V4, _ frag: V2) -> V4 {
        guard chromaticAberration > 0 else { return center }
        let angle = chromaticAngle * PI * 2
        let offset = V2(cos(angle), sin(angle)) * chromaticAberration * 0.02
        let positive = sampleMedia(uv + offset, frag), negative = sampleMedia(uv - offset, frag)
        return V4(positive.x, center.y, negative.z, center.w)
    }

    func sampleDigitalSplit(_ uv: V2, _ block: V2, _ time: Float, _ amount: Float, _ frag: V2) -> V3 {
        let split = amount * 0.06
        let direction = digitalHash(block * 0.4 + V2((time * 3.7).rounded(.down), (time * 5.3).rounded(.down)))
        let axis = direction > 0.66 ? V2(1, 0) : direction > 0.33 ? V2(0, 1) : V2(0.7071, 0.7071)
        let center = sampleMedia(uv, frag)
        return V3(sampleMedia(uv + axis * split, frag).x, center.y, sampleMedia(uv - axis * split, frag).z)
    }

    func applyDigitalGlitch(_ uv: V2, _ source: V3, _ frag: V2) -> V3 {
        let amount = digitalGlitch
        guard amount > 0 else { return source }
        let colorSplit = clampf(ef(.digitalGlitchColorSplit), 0, 1) * 2
        let lineTear = clampf(ef(.digitalGlitchLineTear), 0, 1) * 2
        let pixelate = clampf(ef(.digitalGlitchPixelate), 0, 1) * 2
        let blockAmount = clampf(ef(.digitalGlitchBlockAmount), 0, 1)
        let blockDisplacement = clampf(ef(.digitalGlitchBlockDisplacement), 0, 1) * 2
        let blockOpacity = clampf(ef(.digitalGlitchBlockOpacity), 0, 1)
        let speed = clampf(ef(.digitalGlitchSpeed), 0, 1) * 2
        let time = u.effectTime * speed
        let blockCount = 8 + blockAmount * 60
        let block = V2((uv.x * blockCount).rounded(.down), (uv.y * blockCount).rounded(.down))
        let randomA = digitalHash(block + V2((time * 7.3).rounded(.down), (time * 11.1).rounded(.down)))
        let randomB = digitalHash(block * 0.7 + V2(17.3 + (time * 6.6).rounded(.down), 29.1))
        let randomC = digitalHash(block + V2((time * 5.7).rounded(.down) * 13, 41))
        let randomD = digitalHash(block * 1.3 + V2(7, (time * 3.2).rounded(.down) * 7))
        var displaced = uv
        if blockDisplacement > 0 && blockOpacity > 0 {
            let threshold = 1 - blockDisplacement * 0.4
            if randomA > threshold { displaced += V2((randomB - 0.5) * blockDisplacement * 0.5, (randomC - 0.5) * blockDisplacement * 0.3) }
            if randomD > 0.92 && blockDisplacement > 0.5 { displaced.x += (digitalHash(V2(block.y, (time * 8).rounded(.down))) - 0.5) * blockDisplacement }
            displaced = uv + (displaced - uv) * blockOpacity
        }
        if lineTear > 0 {
            let row = (uv.y * (50 + lineTear * 150)).rounded(.down)
            let tearA = digitalHash(V2(row * 7.3 + (time * 12 + row * 0.1).rounded(.down) * 3.7, 13))
            let tearB = digitalHash(V2(row * 13.7 + (time * 8.3).rounded(.down) * 5.1, 31))
            if tearA > 1 - lineTear * 0.5 { displaced.x += (tearB - 0.5) * lineTear * 0.4 }
            if tearB > 0.95 && lineTear > 0.3 { displaced.x += (tearA - 0.5) * lineTear * 0.8 }
        }
        if pixelate > 0 {
            let pixelRandom = digitalHash(block * 0.5 + V2((time * 4.9).rounded(.down), 53))
            if pixelRandom > 1 - pixelate * 0.35 {
                let cells = 4 + (1 - pixelRandom) * pixelate * 40
                let c = clampUv(displaced)
                displaced = V2(((c.x * cells).rounded(.down) + 0.5) / cells, ((c.y * cells).rounded(.down) + 0.5) / cells)
            }
        }
        displaced = clampUv(displaced)
        var glitch = sampleDigitalSplit(displaced, block, time, colorSplit, frag)
        if blockDisplacement > 0.2 && blockOpacity > 0 {
            let corruption = digitalHash(block * 1.1 + V2((time * 11.9).rounded(.down), 67))
            var changed = glitch
            if corruption > 0.9 { changed = V3(repeating: 1) - glitch }
            else if corruption > 0.85 { changed = corruption > 0.875 ? V3(glitch.y, glitch.z, glitch.x) : V3(glitch.z, glitch.x, glitch.y) }
            else if corruption > 0.8 {
                let channel = digitalHash(block + V2(73, 73))
                if channel > 0.66 { changed.x = Swift.min(changed.x * 2, 1) }
                else if channel > 0.33 { changed.y = Swift.min(changed.y * 2, 1) }
                else { changed.z = Swift.min(changed.z * 2, 1) }
            }
            glitch = mix(glitch, changed, blockOpacity)
        }
        if blockOpacity > 0 {
            let flash = digitalHash(block * 0.8 + V2((time * 14.7).rounded(.down), 83))
            let flashed = flash > 0.97 ? simdMin(glitch * 1.8, V3(repeating: 1)) : flash > 0.94 ? glitch * 0.3 : glitch
            glitch = mix(glitch, flashed, blockOpacity * 0.6)
        }
        if lineTear > 0.1 {
            let interference = pow(sin(uv.y * (300 + randomA * 200) + time * 30) * 0.5 + 0.5, 6)
            glitch -= V3(repeating: interference * 0.08 * lineTear)
        }
        return mix(source, clamp3(glitch, 0, 1), amount)
    }

    @inline(__always) func applyCrtWarp(_ uv: V2) -> V2 {
        var centered = uv * 2 - 1
        let curvature = crtCurvature * 0.5
        let dist = centered.x * centered.x + centered.y * centered.y
        centered *= 1 + curvature * dist
        return centered * 0.5 + 0.5
    }

    // MARK: Grade

    @inline(__always) func paletteColor(_ index: Float) -> V3 {
        let i = index < 0.5 ? 0 : index < 1.5 ? 1 : index < 2.5 ? 2 : index < 3.5 ? 3 : index < 4.5 ? 4 : 5
        return u.palette[i]
    }

    @inline(__always) func rgbToHsv(_ c: V3) -> V3 {
        let maximum = Swift.max(Swift.max(c.x, c.y), c.z), minimum = Swift.min(Swift.min(c.x, c.y), c.z)
        let delta = maximum - minimum
        var hue: Float = 0
        if delta > 0.00001 {
            if maximum == c.x { hue = glMod((c.y - c.z) / delta, 6) }
            else if maximum == c.y { hue = (c.z - c.x) / delta + 2 }
            else { hue = (c.x - c.y) / delta + 4 }
            hue = fract(hue / 6)
        }
        return V3(hue, maximum > 0.00001 ? delta / maximum : 0, maximum)
    }
    @inline(__always) func hsvToRgb(_ c: V3) -> V3 {
        let bands = V3(abs(fract(c.x) * 6 - 3), abs(fract(c.x + 0.6666667) * 6 - 3), abs(fract(c.x + 0.3333333) * 6 - 3))
        return mix(V3(repeating: 1), clamp3(bands - 1, 0, 1), c.y) * c.z
    }

    /// sampleAdvancedCurve: linear between the two nearest of 1024 texels.
    @inline(__always) func curve(_ rows: [V4], _ coordinate: Float) -> V4 {
        let position = clampf(coordinate, 0, 1) * 1023
        let lower = position.rounded(.down), upper = Swift.min(lower + 1, 1023)
        let a = rows[Int(lower)], b = rows[Int(upper)]
        return a + (b - a) * (position - lower)
    }

    @inline(__always) func wheelDirection(_ hue: Float) -> V3 {
        var d = hsvToRgb(V3(fract(hue), 1, 1))
        d -= V3(repeating: lumaOf(d))
        return d / Swift.max(Swift.max(Swift.max(abs(d.x), abs(d.y)), abs(d.z)), 0.0001)
    }

    func applyTonalWheels(_ input: V3) -> V3 {
        var color = input
        let luma = lumaOf(color)
        let shadows = 1 - smoothstep(0, 0.6, luma), highlights = smoothstep(0.4, 1, luma)
        let midtones = Swift.max(0, 1 - shadows - highlights)
        let total = Swift.max(shadows + midtones + highlights, 0.0001)
        let w = V3(shadows, midtones, highlights) / total
        color += wheelDirection(u.shadowWheel.x) * (u.shadowWheel.y * w.x * 0.18)
        color += wheelDirection(u.midtoneWheel.x) * (u.midtoneWheel.y * w.y * 0.18)
        color += wheelDirection(u.highlightWheel.x) * (u.highlightWheel.y * w.z * 0.18)
        color += V3(repeating: u.shadowWheel.z * w.x * 0.25)
        color += V3(repeating: u.midtoneWheel.z * w.y * 0.25)
        color += V3(repeating: u.highlightWheel.z * w.z * 0.25)
        return color
    }

    @inline(__always) func applyRgbCurves(_ color: V3) -> V3 {
        guard u.rgbCurvesEnabled else { return color }
        let master = V3(curve(curveRows, color.x).w, curve(curveRows, color.y).w, curve(curveRows, color.z).w)
        return V3(curve(curveRows, master.x).x, curve(curveRows, master.y).y, curve(curveRows, master.z).z)
    }

    @inline(__always) func decodeSigned(_ v: Float) -> Float { (v * 255 - 128) / 127 }

    func applyHueCurves(_ color: V3) -> V3 {
        guard u.hueCurvesEnabled else { return color }
        var hsv = rgbToHsv(clamp3(color, 0, 1))
        let c = curve(hueRows, hsv.x)
        let originalLuma = lumaOf(color)
        hsv.x = fract(hsv.x + decodeSigned(c.x) * 0.5)
        hsv.y = clampf(hsv.y * Swift.max(0, 1 + decodeSigned(c.y)), 0, 1)
        var shifted = hsvToRgb(hsv)
        shifted += V3(repeating: originalLuma - lumaOf(shifted) + decodeSigned(c.z))
        return shifted
    }

    @inline(__always) func softRangeMask(_ value: Float, _ minimum: Float, _ maximum: Float, _ softness: Float) -> Float {
        if value < minimum { return softness <= 0 ? 0 : smoothstep(minimum - softness, minimum, value) }
        if value > maximum { return softness <= 0 ? 0 : 1 - smoothstep(maximum, maximum + softness, value) }
        return 1
    }
    @inline(__always) func hueRangeMask(_ hue: Float, _ saturation: Float, _ key: V4) -> Float {
        let distance = abs(fract(hue - key.x + 0.5) - 0.5) * 360
        let range = key.y * 180, softness = key.z * 180
        if range < 179.999 && saturation < 0.001 { return 0 }
        if distance <= range { return 1 }
        if softness <= 0 { return 0 }
        return 1 - smoothstep(range, range + softness, distance)
    }

    func applySecondary(_ color: V3, _ index: Int) -> V3 {
        let base = index * 5
        let hueKey = secondaryTexels[base], satKey = secondaryTexels[base + 1], lumaKey = secondaryTexels[base + 2]
        let correction = secondaryTexels[base + 3], tintCorrection = secondaryTexels[base + 4]
        var hsv = rgbToHsv(clamp3(color, 0, 1))
        let luma = lumaOf(color)
        var mask = hueRangeMask(hsv.x, hsv.y, hueKey)
        mask *= softRangeMask(hsv.y, satKey.x, satKey.y, satKey.z * 0.5)
        mask *= softRangeMask(luma, lumaKey.x, lumaKey.y, lumaKey.z * 0.5)
        if mask <= 0 { return color }
        hsv.x = fract(hsv.x + decodeSigned(correction.x) * 0.5)
        var corrected = hsvToRgb(hsv)
        let correctedLuma = lumaOf(corrected)
        corrected = mix(V3(repeating: correctedLuma), corrected, Swift.max(0, 1 + decodeSigned(correction.y)))
        corrected += V3(repeating: decodeSigned(correction.z))
        let temperature = decodeSigned(correction.w), tint = decodeSigned(tintCorrection.x)
        if tintCorrection.y > 0.75 {   // contract 3: the secondary's flag texel is 1, not 0.5
            corrected *= whiteBalanceGain(temperature, tint)
        } else {
            corrected.x += temperature * 0.08 + tint * 0.04
            corrected.z -= temperature * 0.08 - tint * 0.04
            corrected.y -= tint * 0.08
        }
        return mix(color, corrected, mask)
    }

    /// Warmth and Tint as per-channel gains (grade contract 3): at a mid grey they move R, G and B as far as the
    /// older offsets did, normalized so a grey keeps its luma; black stays black and nothing is added.
    @inline(__always) func whiteBalanceGain(_ temperature: Float, _ tint: Float) -> V3 {
        let g = V3(1 + temperature * 0.16 + tint * 0.08, 1 - tint * 0.16, 1 - temperature * 0.16 + tint * 0.08)
        return g / lumaOf(g)
    }

    func applyAdvancedGrade(_ input: V3) -> V3 {
        var color = applyTonalWheels(input)
        color = applyRgbCurves(color)
        color = applyHueCurves(color)
        for i in 0..<Swift.min(u.secondaryCount, 4) { color = applySecondary(color, i) }
        return color
    }

    @inline(__always) func applyLut(_ color: V3) -> V3 {
        guard u.lutEnabled, let lut else { return color }
        return lut.apply(color, strength: u.lutIntensity, interpolation: interpolation)
    }

    func applyPrimaryGrade(_ input: V3) -> V3 {
        var color = input * pow(2, u.exposure)
        let y = lumaOf(color)
        let shadowMask = 1 - smoothstep(0, 0.65, y), highlightMask = smoothstep(0.35, 1, y)
        color += V3(repeating: u.shadows * 0.35 * shadowMask)
        color += V3(repeating: u.highlights * 0.35 * highlightMask)
        let blackPoint = clampf(u.blacks * 0.18, -0.18, 0.18)
        let whitePoint = clampf(1 - u.whites * 0.18, 0.82, 1.18)
        color = (color - V3(repeating: blackPoint)) / Swift.max(whitePoint - blackPoint, 0.2)
        if u.whiteBalanceGains {
            color *= whiteBalanceGain(u.temperature, u.tint)
        } else {
            color.x += u.temperature * 0.08 + u.tint * 0.04
            color.z -= u.temperature * 0.08 - u.tint * 0.04
            color.y -= u.tint * 0.08
        }
        color = (color - 0.5) * Swift.max(0, 1 + u.contrast) + 0.5
        let satLuma = lumaOf(color)
        let currentSat = clampf(colorSaturation(color), 0, 1)
        let skinLike = smoothstep(0.02, 0.18, color.x - color.y) * smoothstep(0, 0.16, color.y - color.z) * smoothstep(0.18, 0.82, satLuma)
        let vibranceWeight = (1 - currentSat * 0.72) * mixf(1, 0.55, skinLike)
        color = mix(V3(repeating: satLuma), color, Swift.max(0, 1 + u.vibrance * vibranceWeight))
        color = mix(V3(repeating: satLuma), color, Swift.max(0, 1 + u.saturation))
        return color
    }

    func applyColorGrade(_ color: V3) -> V3 {
        let c = applyAdvancedGrade(applyPrimaryGrade(color))
        return clamp3(applyLut(clamp3(c, 0, 1)), 0, 1)
    }

    // MARK: Stylize

    func dustMask(_ uv: V2, _ frameBucket: Float) -> Float {
        let grid = V2(128, 72)
        let cell = V2((uv.x * grid.x).rounded(.down), (uv.y * grid.y).rounded(.down))
        let local = V2(fract(uv.x * grid.x), fract(uv.y * grid.y)) - 0.5
        let chance = grainHash(cell + V2(repeating: frameBucket * 19.13))
        let radius = mixf(0.05, 0.34, grainHash(cell + V2(7.1, 7.1)))
        return step(0.9975, chance) * (1 - smoothstep(radius, radius + 0.08, length2(local)))
    }

    @inline(__always) func screenDot(_ p: V2, _ ink: Float, _ angle: Float, _ sharpness: Float) -> Float {
        let c = cos(angle), s = sin(angle)
        // GLSL mat2(c, -s, s, c) is column-major: q = (c*p.x + s*p.y, -s*p.x + c*p.y).
        let q = V2(c * p.x + s * p.y, -s * p.x + c * p.y)
        let d = V2(fract(q.x), fract(q.y)) - 0.5
        let radius = clampf(ink, 0, 1).squareRoot() * 0.68
        let edge = mixf(0.16, 0.025, sharpness)
        return 1 - smoothstep(radius - edge, radius + edge, length2(d))
    }

    func monoScreenMask(_ local: V2, _ radius: Float, _ shape: Float, _ softness: Float) -> Float {
        let c = local - 0.5
        var d = length2(c)
        if shape > 0.5 && shape < 1.5 { d = Swift.max(abs(c.x), abs(c.y)) }
        if shape > 1.5 && shape < 2.5 { d = abs(c.x) + abs(c.y) }
        if shape > 2.5 && shape < 3.5 { d = Swift.max(abs(c.x) * 0.86 + c.y * 0.5, -c.y) }
        if shape > 3.5 { d = abs(c.y) }
        let r = shape > 3.5 ? radius * 0.45 : radius
        return 1 - smoothstep(r, r + softness, d)
    }

    var printScale: Float { Swift.max(Swift.min(u.resolution.x, u.resolution.y) / 540, 0.25) }

    func applyMonoScreen(_ source: V3, _ frag: V2) -> V3 {
        let amount = monoScreen
        guard amount > 0 else { return source }
        let invert = step(0.5, ef(.monoScreenInvert))
        var coverage = mixf(1 - lumaOf(source), lumaOf(source), invert)
        coverage = pow(clampf(coverage, 0, 1), mixf(1.7, 0.58, clampf(ef(.monoScreenSpread), 0, 1)))
        let cellPx = mixf(4, 18, clampf(ef(.monoScreenSize), 0, 1)) * printScale
        let angle = clampf(ef(.monoScreenAngle), 0, 1) * PI * 0.5
        let c = cos(angle), s = sin(angle)
        let f = frag / Swift.max(cellPx, 1)
        let point = V2(c * f.x + s * f.y, -s * f.x + c * f.y)
        let radius = coverage.squareRoot() * 0.68
        let ink = monoScreenMask(V2(fract(point.x), fract(point.y)), radius, (ef(.monoScreenShape) + 0.5).rounded(.down), 0.035)
        let paper = paletteColor(Swift.max(u.paletteSize - 1, 1))
        return mix(source, mix(paper, paletteColor(0), ink), amount)
    }

    func applyEngraving(_ source: V3, _ frag: V2) -> V3 {
        let amount = engraving
        guard amount > 0 else { return source }
        let spacing = mixf(3, 20, clampf(ef(.engravingSpacing), 0, 1))
        let minT = mixf(0, 2, clampf(ef(.engravingMinThickness), 0, 1)), maxT = mixf(1, 8, clampf(ef(.engravingMaxThickness), 0, 1))
        let angle = clampf(ef(.engravingAngle), 0, 1) * PI
        let along = V2(cos(angle), sin(angle)), acrossAxis = V2(-along.y, along.x)
        let alongD = frag.x * along.x + frag.y * along.y
        var across = frag.x * acrossAxis.x + frag.y * acrossAxis.y
        let frequency = mixf(1, 10, clampf(ef(.engravingWaveFrequency), 0, 1))
        across += sin(alongD * frequency * 0.01) * clampf(ef(.engravingWave), 0, 1) * 3
        let sp = Swift.max(spacing, 1)
        let lineIndex = (across / sp).rounded(.down)
        let lineDistance = abs(fract(across / sp) - 0.5) * spacing
        let contrast = mixf(0.5, 2, clampf(ef(.engravingContrast), 0, 1))
        let darkness = 1 - pow(clampf(lumaOf(source), 0, 1), contrast)
        let variation = mixf(0.88, 1.12, digitalHash(V2(lineIndex, 73)))
        let thickness = mixf(minT, maxT, darkness) * variation
        let edge = mixf(1, 0.3, clampf(ef(.engravingSharpness), 0, 1))
        var ink = 1 - smoothstep(Swift.max(thickness * 0.5 - edge, 0), thickness * 0.5 + edge, lineDistance)
        ink *= smoothstep(0.015, 0.12, darkness)
        let paper = paletteColor(Swift.max(u.paletteSize - 1, 1))
        return mix(source, mix(paper, paletteColor(0), ink), amount)
    }

    func crosshatchLine(_ pixel: V2, _ angle: Float, _ spacing: Float, _ thickness: Float, _ seed: Float) -> Float {
        let along = V2(cos(angle), sin(angle)), acrossAxis = V2(-along.y, along.x)
        let alongD = pixel.x * along.x + pixel.y * along.y
        var across = pixel.x * acrossAxis.x + pixel.y * acrossAxis.y
        let frequency = mixf(1, 10, clampf(ef(.crosshatchWaveFrequency), 0, 1))
        across += sin(alongD * frequency * 0.02 + u.effectTime + seed) * clampf(ef(.crosshatchWave), 0, 1) * 5
        let sp = Swift.max(spacing, 1)
        let lineIndex = (across / sp).rounded(.down)
        let distanceToLine = abs(fract(across / sp) - 0.5) * spacing
        let variation = mixf(1, 0.5 + digitalHash(V2(lineIndex, seed)), clampf(ef(.crosshatchLineWeight), 0, 1))
        let halfWidth = thickness * variation * 0.5
        return 1 - smoothstep(Swift.max(halfWidth - 0.5, 0), halfWidth + 0.5, distanceToLine)
    }

    func crosshatchEdge(_ uv: V2, _ frag: V2) -> Float {
        let texel = V2(1 / Swift.max(u.resolution.x, 1), 1 / Swift.max(u.resolution.y, 1))
        func l(_ dx: Float, _ dy: Float) -> Float { let s = sampleMedia(uv + texel * V2(dx, dy), frag); return lumaOf(V3(s.x, s.y, s.z)) }
        let tl = l(-1, -1), tc = l(0, -1), tr = l(1, -1), ml = l(-1, 0), mr = l(1, 0), bl = l(-1, 1), bc = l(0, 1), br = l(1, 1)
        let gx = -tl - 2 * ml - bl + tr + 2 * mr + br
        let gy = -tl - 2 * tc - tr + bl + 2 * bc + br
        return (gx * gx + gy * gy).squareRoot()
    }

    func applyCrosshatch(_ uv: V2, _ source: V3, _ frag: V2) -> V3 {
        let amount = crosshatch
        guard amount > 0 else { return source }
        let spacing = mixf(5, 30, clampf(ef(.crosshatchSpacing), 0, 1))
        let thickness = mixf(1, 5, clampf(ef(.crosshatchThickness), 0, 1))
        let baseAngle = -clampf(ef(.crosshatchAngle), 0, 1) * PI
        let contrast = mixf(0.5, 2, clampf(ef(.crosshatchContrast), 0, 1))
        let darkness = 1 - pow(clampf(lumaOf(source), 0, 1), contrast)
        let ink = paletteColor(0), paper = paletteColor(Swift.max(u.paletteSize - 1, 1))
        var result = paper
        result = mix(result, ink, crosshatchLine(frag, baseAngle, spacing, thickness, 1) * smoothstep(0.2, 0.4, darkness))
        result = mix(result, ink, crosshatchLine(frag, baseAngle + PI * 0.5, spacing * 0.95, thickness * 0.9, 2) * smoothstep(0.4, 0.6, darkness))
        result = mix(result, ink, crosshatchLine(frag, baseAngle + PI * 0.25, spacing * 0.9, thickness * 0.8, 3) * smoothstep(0.6, 0.8, darkness))
        result = mix(result, ink, crosshatchLine(frag, baseAngle - PI * 0.25, spacing * 0.85, thickness * 0.7, 4) * smoothstep(0.75, 0.9, darkness))
        result = mix(result, ink, smoothstep(0.9, 1, darkness) * 0.8)
        let edgeStrength = mixf(0, 2, clampf(ef(.crosshatchEdges), 0, 1))
        if edgeStrength > 0 {
            let edge = smoothstep(0.1, 0.3, crosshatchEdge(uv, frag)) * edgeStrength
            result = mix(result, ink, clampf(edge, 0, 1))
        }
        return mix(source, result, amount)
    }

    func applyHalftone(_ source: V3, _ frag: V2) -> V3 {
        let amount = halftone
        guard amount > 0 else { return source }
        let cmy = V3(repeating: 1) - source
        let k = Swift.min(cmy.x, Swift.min(cmy.y, cmy.z))
        let inks = simdMax(cmy - V3(repeating: k * 0.72), .zero)
        let scale = Swift.min(u.resolution.x, u.resolution.y) / 540
        let cellPx = mixf(5, 14, clampf(ef(.halftoneSize), 0, 1)) * Swift.max(scale, 0.25)
        let p = frag / Swift.max(cellPx, 1)
        let cyan = screenDot(p, inks.x, 0.261799, 0.78), magenta = screenDot(p, inks.y, 1.308997, 0.78)
        let yellow = screenDot(p, inks.z, 0, 0.78), blackInk = screenDot(p, k, 0.785398, 0.82)
        var c = V3(0.975, 0.962, 0.925)
        c *= mix(V3(repeating: 1), V3(0.05, 0.79, 0.86), cyan)
        c *= mix(V3(repeating: 1), V3(0.91, 0.08, 0.48), magenta)
        c *= mix(V3(repeating: 1), V3(0.98, 0.83, 0.08), yellow)
        c *= mix(V3(repeating: 1), V3(repeating: 0.035), blackInk * 0.92)
        return mix(source, c, amount)
    }

    func applyTwoInkPrint(_ source: V3, _ frag: V2) -> V3 {
        let amount = twoInkPrint
        guard amount > 0 else { return source }
        let darkness = 1 - lumaOf(source)
        let warmBias = clampf(source.x - (source.y + source.z) * 0.5, -0.35, 0.35)
        let coolBias = clampf((source.y + source.z) * 0.5 - source.x, -0.35, 0.35)
        let redTone = smoothstep(0.08, 0.72, darkness) * (1 - 0.68 * smoothstep(0.66, 1, darkness))
        let tealTone = smoothstep(0.30, 0.92, darkness)
        let redCoverage = clampf(redTone + warmBias * 1.35 - coolBias * 0.35, 0, 1)
        let tealCoverage = clampf(tealTone + coolBias * 1.1 - warmBias * 0.45, 0, 1)
        let scale = Swift.min(u.resolution.x, u.resolution.y) / 540
        let cellPx = mixf(4.5, 12, clampf(ef(.twoInkPrintSize), 0, 1)) * Swift.max(scale, 0.25)
        let p = frag / Swift.max(cellPx, 1)
        let redDot = screenDot(p, redCoverage, 0.261799, 0.84)
        let tealDot = screenDot(p + V2(0.12, -0.08), tealCoverage, 1.308997, 0.84)
        let paperNoise = grainHash(V2((frag.x * 0.5).rounded(.down), (frag.y * 0.5).rounded(.down))) - 0.5
        let paper = V3(0.955, 0.910, 0.795) + paperNoise * 0.018
        var c = paper * (1 - redDot) * (1 - tealDot)
        c += V3(0.88, 0.13, 0.075) * (redDot * (1 - tealDot))
        c += V3(0.035, 0.285, 0.355) * ((1 - redDot) * tealDot)
        c += V3(0.045, 0.055, 0.052) * (redDot * tealDot)
        return mix(source, clamp3(c, 0, 1), amount)
    }

    static let bayer: [Float] = [0.5, 8.5, 2.5, 10.5, 12.5, 4.5, 14.5, 6.5, 3.5, 11.5, 1.5, 9.5, 15.5, 7.5, 13.5, 5.5].map { $0 / 16 }

    func applyDither(_ source: V3, _ frag: V2) -> V3 {
        let amount = dither
        guard amount > 0 else { return source }
        let pixelSize = mixf(1, 5, clampf(ef(.ditherSize), 0, 1)) * printScale
        let ps = Swift.max(pixelSize, 1)
        let bx = glMod((frag.x / ps).rounded(.down), 4), by = glMod((frag.y / ps).rounded(.down), 4)
        let levels = clampf(u.paletteSize, 2, 6)
        let index = clampf(lumaOf(source) * (levels - 1) + Self.bayer[Int(by) * 4 + Int(bx)], 0, levels - 1).rounded(.down)
        return mix(source, paletteColor(index), amount)
    }

    func standardAsciiSample(_ b: Float, _ g: V2) -> Float {
        let x = g.x, y = g.y
        if b < 0.1 { return 0 }
        if b < 0.2 { return x == 2 && y == 5 ? 1 : 0 }
        if b < 0.3 { return x == 2 && (y == 2 || y == 4) ? 1 : 0 }
        if b < 0.4 { return (y == 2 || y == 4) && x >= 1 && x <= 3 ? 1 : 0 }
        if b < 0.5 {
            let cross = (x == 2 && y >= 2 && y <= 4) || (y == 3 && x >= 1 && x <= 3)
            let diagonals = (x == 1 || x == 3) && (y == 2 || y == 4)
            return cross || diagonals ? 1 : 0
        }
        if b < 0.6 { return ((y == 2 || y == 4) && x >= 1 && x <= 3) || ((x == 1 || x == 3) && y == 3) ? 1 : 0 }
        let outline = ((y == 1 || y == 5) && x >= 1 && x <= 3) || ((x == 0 || x == 4) && y >= 2 && y <= 4) || ((x == 1 || x == 3) && y >= 1 && y <= 5)
        if b < 0.7 { return outline ? 1 : 0 }
        if b < 0.8 { let slash = abs(x - 2) == abs(y - 3) && x >= 1 && x <= 3; return outline || slash ? 1 : 0 }
        if b < 0.9 {
            let loops = ((y == 1 || y == 3 || y == 5) && x >= 1 && x <= 3) || ((x == 1 || x == 3) && (y == 2 || y == 4))
            return loops ? 1 : 0
        }
        return 1
    }

    func asciiStyleSample(_ style: Float, _ b: Float, _ uv: V2) -> Float {
        let g = V2((uv.x * 5).rounded(.down), (uv.y * 7).rounded(.down))
        let x = g.x, y = g.y
        if style < 0.5 { return standardAsciiSample(b, g) }
        if style < 1.5 {
            let checker = glMod(x + y, 2)
            let ruled: Float = glMod(x, 2) == 0 || glMod(y, 2) == 0 ? 1 : 0
            if b < 0.125 { return 0 }
            if b < 0.25 { return checker == 0 ? 0.5 : 0 }
            if b < 0.375 { return ruled * 0.6 }
            if b < 0.5 { return checker == 0 ? 1 : 0 }
            if b < 0.625 { return ruled > 0.5 ? 1 : 0.3 }
            if b < 0.75 { return checker == 0 ? 1 : 0.7 }
            if b < 0.875 { return ruled > 0.5 ? 1 : 0.85 }
            return 1
        }
        if style < 2.5 {
            if b < 0.14 { return 0 }
            if b < 0.28 { return x == 2 && y == 1 ? 1 : 0 }
            if b < 0.42 { return x == 2 && y == 5 ? 1 : 0 }
            if b < 0.56 { return y == 3 && x >= 1 && x <= 3 ? 1 : 0 }
            if b < 0.7 { return (x == 2 && y >= 2 && y <= 4) || (y == 3 && x >= 1 && x <= 3) ? 1 : 0 }
            if b < 0.84 { return abs(x - 2) == abs(y - 3) && y >= 2 && y <= 4 ? 1 : 0 }
            return x == 1 || x == 3 || y == 2 || y == 4 ? 1 : 0
        }
        if style < 3.5 { return y >= 6 - b * 7 ? 1 : 0 }
        if style < 4.5 {
            let dy = (uv.y * 4).rounded(.down), dx = (uv.x * 2).rounded(.down)
            if b < 0.125 { return 0 }
            if b < 0.25 { return dy == 3 ? 1 : 0 }
            if b < 0.375 { return dy >= 2 ? 1 : 0 }
            if b < 0.5 { return dy >= 1 ? 1 : 0 }
            if b < 0.625 { return dy >= 1 || dx == 1 ? 1 : 0 }
            if b < 0.75 { return 1 }
            if b < 0.875 { return glMod(x + y, 2) < 1.5 ? 1 : 0.7 }
            return 1
        }
        if style < 5.5 {
            if b < 0.125 { return 0 }
            if b < 0.25 { return x == 2 && y == 3 ? 1 : 0 }
            if b < 0.375 { return y == 3 && x >= 1 && x <= 3 ? 1 : 0 }
            if b < 0.5 { return x + y == 5 || x + y == 6 ? 1 : 0 }
            if b < 0.625 { return x == 2 ? 1 : 0 }
            if b < 0.75 { return abs(x - y / 1.4) < 0.7 && x >= 1 && x <= 3 ? 1 : 0 }
            if b < 0.875 { return x == 2 || y == 3 ? 1 : 0 }
            return x == 1 || x == 3 || y == 2 || y == 4 ? 1 : 0
        }
        if style < 6.5 {
            let top = y == 0 && x >= 1 && x <= 3, topLeft = x == 1 && y <= 3, topRight = x == 3 && y <= 3
            let middle = y == 3 && x >= 1 && x <= 3, bottomLeft = x == 1 && y >= 3, bottomRight = x == 3 && y >= 3
            let bottom = y == 6 && x >= 1 && x <= 3
            if b < 0.1 { return 0 }
            if b < 0.2 { return topRight || bottomRight ? 1 : 0 }
            if b < 0.3 { return top || topRight || middle || bottomLeft || bottom ? 1 : 0 }
            if b < 0.4 { return top || topRight || middle || bottomRight || bottom ? 1 : 0 }
            if b < 0.5 { return topLeft || middle || topRight || bottomRight ? 1 : 0 }
            if b < 0.6 { return top || topLeft || middle || bottomRight || bottom ? 1 : 0 }
            if b < 0.7 { return top || topLeft || middle || bottomLeft || bottomRight || bottom ? 1 : 0 }
            if b < 0.8 { return top || topRight || bottomRight ? 1 : 0 }
            if b < 0.9 { return top || topLeft || topRight || middle || bottomLeft || bottomRight || bottom ? 1 : 0 }
            return top || topLeft || topRight || middle || bottomRight || bottom ? 1 : 0
        }
        let slash = x - y, backslash = x + y
        if b < 0.16 { return 0 }
        if b < 0.33 { return glMod(slash, 3) < 0.5 ? 1 : 0 }
        if b < 0.5 { return glMod(slash, 2) < 0.5 ? 1 : 0 }
        let a = glMod(slash, 2) < 0.5, d = glMod(backslash, 2) < 0.5
        if b < 0.66 { return a || d ? 1 : 0 }
        if b < 0.83 { return glMod(slash, 1.5) < 0.5 || glMod(backslash, 1.5) < 0.5 ? 1 : 0.2 }
        return glMod(slash, 1) < 0.6 || glMod(backslash, 1) < 0.6 ? 1 : 0.5
    }

    func asciiEdgeDirection(_ uv: V2, _ stepUv: V2, _ frag: V2) -> V2 {
        func l(_ dx: Float, _ dy: Float) -> Float { let s = sampleMedia(uv + V2(dx * stepUv.x, dy * stepUv.y), frag); return bt601Luma(V3(s.x, s.y, s.z)) }
        let tl = l(-1, -1), t = l(0, -1), tr = l(1, -1), le = l(-1, 0), r = l(1, 0), bl = l(-1, 1), b = l(0, 1), br = l(1, 1)
        return V2(-tl - 2 * le - bl + tr + 2 * r + br, -tl - 2 * t - tr + bl + 2 * b + br)
    }

    func applyAscii(_ source: V3, _ frag: V2) -> V3 {
        let amount = ascii
        guard amount > 0 else { return source }
        let cellHeight = mixf(4, 80, clampf(ef(.asciiSize), 0, 1)) * printScale
        let cell = V2((frag.x / cellHeight).rounded(.down), (frag.y / cellHeight).rounded(.down))
        var cellUv = V2((cell.x + 0.5) * cellHeight / Swift.max(u.resolution.x, 1), (cell.y + 0.5) * cellHeight / Swift.max(u.resolution.y, 1))
        cellUv = applyCrtWarp(cellUv)
        let s = sampleMedia(cellUv, frag)
        let cellColor = applyColorGrade(V3(s.x, s.y, s.z))
        var brightness = bt601Luma(cellColor)
        let invert = step(0.5, ef(.asciiInvert))
        brightness = mixf(brightness, 1 - brightness, invert)
        var glyphUv = V2(fract(frag.x / cellHeight), fract(frag.y / cellHeight))
        let rotation = clampf(ef(.asciiRotation), 0, 1)
        if rotation > 0 {
            let stepUv = V2(cellHeight / Swift.max(u.resolution.x, 1), cellHeight / Swift.max(u.resolution.y, 1))
            let edge = asciiEdgeDirection(cellUv, stepUv, frag)
            if length2(edge) > 0.1 {
                let angle = atan2(edge.y, edge.x), c = cos(angle), sn = sin(angle)
                let centered = glyphUv - 0.5
                let rotated = V2(centered.x * c - centered.y * sn, centered.x * sn + centered.y * c) + 0.5
                glyphUv = glyphUv + (rotated - glyphUv) * rotation
            }
        }
        let ink = asciiStyleSample((ef(.asciiStyle) + 0.5).rounded(.down), brightness, glyphUv)
        let background = paletteColor(0)
        let inkColor = mix(paletteColor(Swift.max(u.paletteSize - 1, 1)), cellColor, clampf(ef(.asciiColor), 0, 1))
        return mix(source, mix(background, inkColor, ink), amount)
    }

    func applyScanlines(_ source: V3, _ vuv: V2) -> V3 {
        let amount = scanlines
        guard amount > 0 else { return source }
        let count = mixf(50, 500, clampf(ef(.scanlineCount), 0, 1))
        let softness = clampf(ef(.scanlineSoftness), 0, 1)
        let wave = 0.5 + 0.5 * sin(vuv.y * count * PI)
        let line = mixf(1 - wave, pow(1 - wave, 2.2), softness)
        return source * (1 - line * amount)
    }

    // MARK: main()

    func shade(_ frag: V2) -> V4 {
        let vuv = V2(frag.x / u.resolution.x, frag.y / u.resolution.y)
        let originalUv = vuv
        let uv = crtCurvature > 0 ? applyCrtWarp(originalUv) : originalUv
        var displayMask: Float = 1
        if crtCurvature > 0 {
            let ex = smoothstep(0, 0.006, uv.x) * (1 - smoothstep(0.994, 1, uv.x))
            let ey = smoothstep(0, 0.006, uv.y) * (1 - smoothstep(0.994, 1, uv.y))
            displayMask = ex * ey
        }
        var sampleColor = sampleMedia(uv, frag)
        sampleColor = sampleChromaticMedia(uv, sampleColor, frag)
        var s3 = V3(sampleColor.x, sampleColor.y, sampleColor.z)
        s3 = applyDigitalGlitch(uv, s3, frag)
        var color = mix(s3, applyColorGrade(s3), u.intensity)
        let grainAmount = clampf(u.grain, 0, 1)
        if grainAmount > 0 {
            let grainPixelSize = mixf(1, 6, clampf(u.grainSize, 0, 1))
            let gc = V2((frag.x / grainPixelSize).rounded(.down), (frag.y / grainPixelSize).rounded(.down)) + V2(u.grainSeed, u.grainSeed * 1.37)
            let grainBase = grainHash(gc) - grainHash(gc + V2(19.19, 73.31))
            let grainFine = grainHash(frag + V2(u.grainSeed * 2.11, u.grainSeed * 0.71)) - 0.5
            let grain = mixf(grainBase * 0.7, grainBase + grainFine * 0.35, clampf(u.grainRoughness, 0, 1))
            let gl = lumaOf(color)
            let grainMask = smoothstep(0.02, 0.55, gl) * (1 - smoothstep(0.88, 1, gl))
            color += V3(repeating: grain * grainAmount * mixf(0.025, 0.08, grainMask))
        }
        if filmArtifacts > 0 {
            let filmFrame = u.grainSeed.rounded(.down)
            let dust = dustMask(vuv, (filmFrame / 3).rounded(.down))
            let dustTone = grainHash(V2((filmFrame / 3).rounded(.down), 8))
            color = mix(color, V3(repeating: dustTone > 0.5 ? 0.95 : 0.02), dust * 0.72 * filmArtifacts)
            let scratchBucket = (filmFrame / 12).rounded(.down)
            let scratchX = grainHash(V2(scratchBucket, 4.2))
            let scratchLife = step(0.78, grainHash(V2(scratchBucket, 8.4)))
            let scratch = (1 - smoothstep(0, 1.4 / Swift.max(u.resolution.x, 1), abs(vuv.x - scratchX))) * scratchLife
            color = mix(color, V3(0.94, 0.88, 0.76), scratch * 0.28 * filmArtifacts)
        }
        if monoScreen > 0 { color = applyMonoScreen(clamp3(color, 0, 1), frag) }
        if engraving > 0 { color = applyEngraving(clamp3(color, 0, 1), frag) }
        if crosshatch > 0 { color = applyCrosshatch(uv, clamp3(color, 0, 1), frag) }
        if halftone > 0 { color = applyHalftone(clamp3(color, 0, 1), frag) }
        if twoInkPrint > 0 { color = applyTwoInkPrint(clamp3(color, 0, 1), frag) }
        if dither > 0 { color = applyDither(clamp3(color, 0, 1), frag) }
        if ascii > 0 { color = applyAscii(clamp3(color, 0, 1), frag) }
        if bloomAmount > 0, let bloom {
            let b = bloom.sample(clampUv(uv)); color += V3(b.x, b.y, b.z) * bloomAmount
        }
        if scanlines > 0 { color = applyScanlines(clamp3(color, 0, 1), vuv) }
        if u.vignette > 0 {
            let aspect = u.resolution.x > u.resolution.y ? V2(u.resolution.x / Swift.max(u.resolution.y, 1), 1) : V2(1, u.resolution.y / Swift.max(u.resolution.x, 1))
            let vu = V2(abs((vuv.x - 0.5) * 2) * aspect.x, abs((vuv.y - 0.5) * 2) * aspect.y)
            let power = mixf(8, 1.8, clampf(u.vignetteRoundness * 0.5 + 0.5, 0, 1))
            let distance = pow(pow(vu.x, power) + pow(vu.y, power), 1 / power)
            let mid = mixf(0.22, 1.08, clampf(u.vignetteMidpoint, 0, 1))
            let feather = mixf(0.08, 0.72, clampf(u.vignetteFeather, 0, 1))
            let mask = smoothstep(mid, mid + feather, distance)
            color *= 1 - mask * clampf(u.vignette, 0, 1) * 0.75
        }
        if crtCurvature > 0 { color *= displayMask }
        var graded = clamp3(color, 0, 1)
        var alpha = sampleColor.w
        if u.keyEnabled {
            func chroma(_ value: V3) -> V2 {
                let y = lumaOf(value)
                return V2((value.z - y) / 1.8556, (value.x - y) / 1.5748)
            }
            let distance = length2(chroma(V3(sampleColor.x, sampleColor.y, sampleColor.z)) - chroma(u.keyColor))
            let matte = smoothstep(u.keySimilarity, u.keySimilarity + Swift.max(u.keySmoothness, 0.000001), distance)
            alpha *= matte
            let excessGreen = Swift.max(0, graded.y - Swift.max(graded.x, graded.z))
            graded.y -= excessGreen * u.keySpill
        }
        return V4(graded.x, graded.y, graded.z, alpha)
    }

    // MARK: Multipass (blur / bloom, Kuwahara)

    /// The separable blur/bloom pass (`u_bloomPass` 0 = 25-tap blur on premultiplied colour, 1 = 9-tap bloom with a
    /// luminance threshold). Renders `src` into a `width` x `height` RGBA8 target along `direction`.
    static func blurPass(_ src: GLTexture, width: Int, height: Int, direction: V2, radius: Float, bloomPass: Bool, threshold: Float) -> GLTexture {
        let res = V2(Float(width), Float(height))
        @Sendable @inline(__always) func read(_ uv: V2) -> V4 {
            var c = src.sample(clampUv(uv))
            if bloomPass {
                let lum = c.x * 0.299 + c.y * 0.587 + c.z * 0.114
                if threshold >= 0 && lum <= threshold { c = V4(0, 0, 0, c.w) }
                return V4(c.x, c.y, c.z, 1)
            }
            return V4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
        }
        let blurWeights: [Float] = [0.08077993, 0.07918038, 0.07456928, 0.06747307, 0.05865827, 0.04899551, 0.03931982, 0.03031761,
                                    0.02245983, 0.01598624, 0.01093238, 0.00718308, 0.00453456]
        let bloomWeights: [Float] = [0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216]
        let r = Swift.max(radius, 0)
        let stepUv = V2(direction.x * r / Swift.max(res.x, 1), direction.y * r / Swift.max(res.y, 1)) * (bloomPass ? 0.5 : 1.0 / 12.0)
        let weights = bloomPass ? bloomWeights : blurWeights
        var out = [V4](repeating: .zero, count: width * height)
        concurrentRows(height, elementsPerRow: width, into: &out) { rows in
            var buf = [V4](repeating: .zero, count: rows.count * width)
            for y in rows {
                for x in 0..<width {
                    let vuv = V2((Float(x) + 0.5) / res.x, (Float(y) + 0.5) / res.y)
                    var c = read(vuv) * weights[0]
                    for k in 1..<weights.count {
                        c += read(vuv + stepUv * Float(k)) * weights[k]
                        c += read(vuv - stepUv * Float(k)) * weights[k]
                    }
                    if !bloomPass && c.w > 0.0001 { c = V4(c.x / c.w, c.y / c.w, c.z / c.w, c.w) }
                    buf[(y - rows.lowerBound) * width + x] = (simdClamp4(c) * 255).rounded(.toNearestOrAwayFromZero) / 255
                }
            }
            return buf
        }
        return GLTexture(width: width, height: height, px: out)
    }

    mutating func prepareBlur(blur amount: Float) {
        guard amount > 0 else { return }
        let w = source.width, h = source.height
        let radius = 0.75 + pow(amount, 1.35) * 32
        let iterations = amount > 0.55 ? 3 : 2
        var current = source
        for _ in 0..<iterations {
            let a = Self.blurPass(current, width: w, height: h, direction: V2(1, 0), radius: radius, bloomPass: false, threshold: -1)
            current = Self.blurPass(a, width: w, height: h, direction: V2(0, 1), radius: radius, bloomPass: false, threshold: -1)
        }
        blur = current
    }

    mutating func prepareBloom(radius bloomRadius: Float) {
        let w = Swift.max(1, Int((Float(source.width) / 2).rounded(.up))), h = Swift.max(1, Int((Float(source.height) / 2).rounded(.up)))
        let s = bloomRadius / 2
        let a = Self.blurPass(source, width: w, height: h, direction: V2(1, 0), radius: s, bloomPass: true, threshold: 0.5)
        bloom = Self.blurPass(a, width: w, height: h, direction: V2(0, 1), radius: s, bloomPass: true, threshold: -1)
    }

    mutating func prepareKuwahara(radius kr: Float, sharpness: Float, saturation: Float) {
        let w = source.width, h = source.height
        let texel = V2(1 / Float(w), 1 / Float(h))
        let radius = Int((mixf(2, 16, clampf(kr, 0, 1)) + 0.5).rounded(.down))
        // Horizontal moments (half-float target, NEAREST): mean colour and mean squared magnitude / 3 over x..x+radius.
        let source = source, blur = blur, blurAmount = blurAmount
        var moments = [V4](repeating: .zero, count: w * h)
        concurrentRows(h, elementsPerRow: w, into: &moments) { rows in
            var buf = [V4](repeating: .zero, count: rows.count * w)
            for y in rows {
                for x in 0..<w {
                    var sum = V3.zero, sq: Float = 0
                    for o in 0...radius {
                        let uv = V2((Float(x) + 0.5) / Float(w) + Float(o) * texel.x, (Float(y) + 0.5) / Float(h))
                        var c = source.sample(clampUv(uv))
                        if blurAmount > 0, let b = blur { c = c + (b.sample(clampUv(uv)) - c) * blurAmount }
                        let rgb = V3(c.x, c.y, c.z)
                        sum += rgb; sq += dot3(rgb, rgb) / 3
                    }
                    let n = Float(radius + 1)
                    buf[(y - rows.lowerBound) * w + x] = V4(sum.x / n, sum.y / n, sum.z / n, sq / n)
                }
            }
            return buf
        }
        let m = GLTexture(width: w, height: h, px: moments, linear: false)
        let exponent = 1 + clampf(sharpness, 0, 1) * 8
        let satAmount = clampf(saturation, 0, 1) * 2
        let origins: [V2] = [V2(Float(-radius), Float(-radius)), V2(0, Float(-radius)), V2(Float(-radius), 0), V2(0, 0)]
        var out = [V4](repeating: .zero, count: w * h)
        concurrentRows(h, elementsPerRow: w, into: &out) { rows in
            var buf = [V4](repeating: .zero, count: rows.count * w)
            for y in rows {
                for x in 0..<w {
                    let vuv = V2((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h))
                    var means = [V3](repeating: .zero, count: 4), variances = [Float](repeating: 0, count: 4)
                    var minVariance: Float = 1
                    for q in 0..<4 {
                        var moment = V4.zero
                        for o in 0...radius {
                            let off = origins[q] + V2(0, Float(o))
                            moment += m.sample(clampUv(vuv + off * texel))
                        }
                        moment /= Float(radius + 1)
                        let mean = V3(moment.x, moment.y, moment.z)
                        let variance = Swift.max(moment.w * 3 - dot3(mean, mean), 0)
                        means[q] = mean; variances[q] = variance
                        minVariance = Swift.min(minVariance, variance)
                    }
                    var result = V3.zero, total: Float = 0
                    for q in 0..<4 {
                        let weight = pow((minVariance + 0.0001) / (variances[q] + 0.0001), exponent)
                        result += means[q] * weight; total += weight
                    }
                    result /= Swift.max(total, 0.0001)
                    let l = lumaOf(result)
                    let c = clamp3(mix(V3(repeating: l), result, satAmount), 0, 1)
                    buf[(y - rows.lowerBound) * w + x] = (V4(c.x, c.y, c.z, 1) * 255).rounded(.toNearestOrAwayFromZero) / 255
                }
            }
            return buf
        }
        kuwahara = GLTexture(width: w, height: h, px: out)
    }
}

/// Computes rows in parallel and publishes each completed row into the existing output array.
/// Workers own at most one row of scratch storage each. The mutex exclusively owns the destination
/// until concurrentPerform joins all workers; its lock protects only the row copy, never pixel work.
/// No output pointers cross threads, and elements beyond the rendered rows are left unchanged.
func concurrentRows<Element: Sendable>(_ count: Int, elementsPerRow: Int, into output: inout [Element],
                                       _ body: @Sendable (Range<Int>) -> [Element]) {
    guard count > 0 else { return }
    precondition(elementsPerRow > 0 && output.count / elementsPerRow >= count)
    let workers = Swift.max(1, Swift.min(ProcessInfo.processInfo.activeProcessorCount, count))
    if workers == 1 || count < 16 {
        for row in 0..<count {
            let values = body(row..<row + 1)
            precondition(values.count == elementsPerRow)
            let start = row * elementsPerRow
            output.replaceSubrange(start..<start + elementsPerRow, with: values)
        }
        return
    }
    // Transfer the array's ownership, rather than leaving a second reference that would force a
    // full-frame copy on the first publication. Array's usual copy-on-write still protects callers
    // that share the original frame, just as an ordinary in-place render does.
    let result = Mutex(output)
    output = []
    let chunk = (count + workers - 1) / workers
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        let lo = w * chunk, hi = Swift.min(count, lo + chunk)
        guard lo < hi else { return }
        for row in lo..<hi {
            let values = body(row..<row + 1)
            precondition(values.count == elementsPerRow)
            let start = row * elementsPerRow
            result.withLock { $0.replaceSubrange(start..<start + elementsPerRow, with: values) }
        }
    }
    output = result.withLock { values in
        let completed = values
        values = []
        return completed
    }
}
