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
@testable import MpvfxColor
import MpvfxShared

/// Grades that exercise every control and stylize effect, for comparing renderers (Metal vs the CPU reference).
enum GradeReferenceCases {
    struct Case {
        var name: String
        var json: String
        var lut: CubeLUT? = nil
        var interpolation: CubeLUT.Interpolation = .trilinear
        /// Effects driven by hash noise (sin-based or fract jumps) can flip a few pixels on 1-ulp differences.
        var noisy = false
    }

    static func params(_ s: String) -> ColorGradeParams {
        let v = try! JSONDecoder().decode(NativeJSONValue.self, from: Data(s.utf8))
        guard case .object(let o) = v, let p = ColorGradeParams(json: o) else { fatalError("bad grade json: \(s)") }
        return p
    }

    static func renderer(_ c: Case) -> ColorGradeRenderer {
        ColorGradeRenderer(params: params(c.json), lut: c.lut, seedKey: "clip:reference", interpolation: c.interpolation)
    }

    /// A warm/cool test card: gradients, a hard edge, a circle and a few colour patches (so the qualifiers, edge
    /// detectors and Kuwahara have structure to work on), opaque except a translucent strip at the bottom.
    static func card(width: Int, height: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let fx = Double(x) / Double(max(1, width - 1)), fy = Double(y) / Double(max(1, height - 1))
            var r = fx, g = fy, b = x < width / 2 ? 0.16 : 0.86
            let dx = fx - 0.7, dy = fy - 0.35
            if dx * dx + dy * dy < 0.02 { r = 0.93; g = 0.25; b = 0.2 }                 // red disc
            if fx > 0.1 && fx < 0.25 && fy > 0.55 && fy < 0.8 { r = 0.85; g = 0.6; b = 0.45 } // skin-like patch
            if fx > 0.3 && fx < 0.4 && fy > 0.6 && fy < 0.75 { r = 0.1; g = 0.7; b = 0.25 }   // green patch
            r += sin(Double(x) * 0.9 + Double(y) * 0.3) * 0.03                                // fine texture
            func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            px[i] = q(r); px[i + 1] = q(g); px[i + 2] = q(b); px[i + 3] = fy > 0.92 ? 160 : 255
        } }
        return px
    }

    static var invertLut: CubeLUT { CubeLUT(size: 2, table: CubeLUT.identity(size: 2).table.map { SIMD3(1, 1, 1) - $0 }) }
    /// A 17-point creative LUT (lifted blacks, warm highlights, desaturated mids).
    static var lookLut: CubeLUT {
        var l = CubeLUT.identity(size: 17)
        l.table = l.table.map { c in
            let luma = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
            var o = c + (SIMD3(repeating: luma) - c) * 0.3
            o = o * 0.9 + SIMD3(0.06, 0.04, 0.03)
            o.x += luma * luma * 0.08; o.z -= luma * luma * 0.05
            return simdClamp(o, .zero, .one)
        }
        return l.quantized8
    }

    static var all: [Case] {
        var cases: [Case] = []
        for k in ColorGradeParams.adjustKeys {
            cases.append(Case(name: "adjust.\(k)+", json: #"{"adjust":{"\#(k)":0.6}}"#))
            cases.append(Case(name: "adjust.\(k)-", json: #"{"adjust":{"\#(k)":-0.45}}"#))
        }
        // Contract 3: Warmth and Tint as channel gains, in the primary and in a secondary.
        cases.append(Case(name: "v3.whiteBalance", json: #"{"version":3,"adjust":{"temperature":0.7,"tint":-0.4}}"#))
        cases.append(Case(name: "v3.secondaryWhiteBalance", json: #"{"version":3,"secondaries":[{"key":{"hue":{"center":0,"range":180,"softness":0}},"correction":{"temperature":-0.6,"tint":0.5}}]}"#))
        // Lift / Gamma / Gain / Offset and the contrast pivot (issue #176).
        for k in GradeValues.balanceKeys {
            cases.append(Case(name: "balance.\(k)", json: #"{"balance":{"\#(k)":{"hue":200,"amount":0.7,"level":0.35}}}"#))
        }
        cases.append(Case(name: "balance.all", json: #"{"balance":{"lift":{"hue":30,"amount":0.4,"level":-0.3},"gamma":{"hue":300,"amount":0.5,"level":-0.6},"gain":{"hue":120,"amount":0.3,"level":0.5},"offset":{"hue":60,"amount":0.2,"level":-0.2}}}"#))
        cases.append(Case(name: "pivot", json: #"{"adjust":{"contrast":0.6},"pivot":0.3}"#))
        cases.append(Case(name: "intensity", json: #"{"adjust":{"saturation":-1,"exposure":0.4},"intensity":0.4}"#))
        for k in ColorGradeParams.wheelKeys {
            cases.append(Case(name: "wheel.\(k)", json: #"{"wheels":{"\#(k)":{"hue":210,"amount":0.8,"level":0.3}}}"#))
        }
        cases.append(Case(name: "curve.master", json: #"{"curves":{"master":[[0,0.05],[0.3,0.2],[0.7,0.85],[1,0.95]]}}"#))
        cases.append(Case(name: "curve.rgb", json: #"{"curves":{"red":[[0,0],[0.5,0.7],[1,1]],"green":[[0,0.1],[1,0.9]],"blue":[[0,0],[0.4,0.3],[1,1]]}}"#))
        cases.append(Case(name: "hue.hueVsHue", json: #"{"hueCurves":{"hueVsHue":[[0,60],[120,-30],[240,90]]}}"#))
        cases.append(Case(name: "hue.hueVsSaturation", json: #"{"hueCurves":{"hueVsSaturation":[[0,-0.8],[120,0.5],[240,-0.2]]}}"#))
        cases.append(Case(name: "hue.hueVsLuma", json: #"{"hueCurves":{"hueVsLuma":[[0,0.3],[120,-0.2],[240,0.1]]}}"#))
        // Curve shapes the editor makes: a steep rise after a flat floor, end points without (0,0)/(1,1), the
        // 16-point maximum, and a local hue bump between two flat anchors (the first point on an empty hue curve).
        cases.append(Case(name: "curve.steep", json: #"{"curves":{"red":[[0,0],[0.58,0],[0.62,0.65],[1,1]],"master":[[0.2,0.1],[0.8,0.9]]}}"#))
        let sixteen = (0..<16).map { i in "[\(Double(i) / 15),\(i % 2 == 0 ? Double(i) / 15 : min(1, Double(i) / 15 + 0.08))]" }.joined(separator: ",")
        cases.append(Case(name: "curve.sixteenPoints", json: #"{"curves":{"green":[\#(sixteen)]}}"#))
        cases.append(Case(name: "hue.localBump", json: #"{"hueCurves":{"hueVsSaturation":[[60,0],[120,0.8],[180,0]],"hueVsHue":[[0,0],[30,40],[90,0],[180,-25],[270,0],[330,15]]}}"#))
        cases.append(Case(name: "secondaries", json: """
        {"secondaries":[{"key":{"hue":{"center":10,"range":30,"softness":20},"saturation":{"min":0.2,"max":1,"softness":0.1},"luma":{"min":0.1,"max":0.9,"softness":0.1}},
                          "correction":{"hueShift":40,"saturation":-0.5,"luma":0.1,"temperature":0.3,"tint":-0.2}},
                         {"key":{"hue":{"center":130,"range":40,"softness":30}},"correction":{"saturation":0.6,"hueShift":-25}}]}
        """))
        cases.append(Case(name: "lut.invert", json: #"{"lut":{"src":"x.cube","intensity":1}}"#, lut: invertLut))
        cases.append(Case(name: "lut.trilinear", json: #"{"lut":{"src":"x.cube","intensity":0.8}}"#, lut: lookLut))
        cases.append(Case(name: "lut.tetrahedral", json: #"{"lut":{"src":"x.cube","intensity":0.8}}"#, lut: lookLut, interpolation: .tetrahedral))
        cases.append(Case(name: "detail.vignette", json: #"{"details":{"vignette":0.9,"vignetteMidpoint":0.3,"vignetteRoundness":0.5,"vignetteFeather":0.4}}"#))
        cases.append(Case(name: "detail.vignetteSquare", json: #"{"details":{"vignette":0.7,"vignetteRoundness":-1}}"#))
        cases.append(Case(name: "detail.grain", json: #"{"details":{"grain":1,"grainSize":0.6,"grainRoughness":0.8}}"#, noisy: true))
        for k in ColorGradeParams.activeEffectKeys {
            var extra = ""
            if k == "digitalGlitch" {
                extra = #","digitalGlitchColorSplit":1,"digitalGlitchLineTear":0.8,"digitalGlitchPixelate":0.7,"digitalGlitchBlockAmount":0.5,"digitalGlitchBlockDisplacement":1,"digitalGlitchBlockOpacity":1,"digitalGlitchSpeed":0.6"#
            }
            if k == "tapeDamage" { extra = #","tapeTracking":0.8,"tapeNoise":1,"tapeSpeed":0.7"# }
            if k == "bloom" { extra = #","bloomRadius":24"# }
            let noisy = ["tapeDamage", "filmArtifacts", "twoInkPrint", "digitalGlitch"].contains(k)
            let amount = k == "bloom" ? "2" : "0.85"
            cases.append(Case(name: "effect.\(k)", json: #"{"effects":{"\#(k)":\#(amount)\#(extra)}}"#, noisy: noisy))
        }
        cases.append(Case(name: "effect.blurStrong", json: #"{"effects":{"blur":1}}"#))
        cases.append(Case(name: "effect.chromaticAngle", json: #"{"effects":{"chromaticAberration":1,"chromaticAngle":0.3}}"#))
        for s in 0...7 {
            cases.append(Case(name: "effect.ascii.style\(s)", json: #"{"effects":{"ascii":1,"asciiSize":0.1,"asciiStyle":\#(s),"asciiColor":0.5}}"#))
        }
        cases.append(Case(name: "effect.ascii.rotationInvert", json: #"{"effects":{"ascii":1,"asciiSize":0.15,"asciiRotation":1,"asciiInvert":1}}"#))
        for s in 0...4 {
            cases.append(Case(name: "effect.monoScreen.shape\(s)", json: #"{"effects":{"monoScreen":1,"monoScreenShape":\#(s),"monoScreenSize":0.5,"monoScreenAngle":0.3,"monoScreenSpread":0.6}}"#))
        }
        cases.append(Case(name: "effect.monoScreen.invert", json: #"{"effects":{"monoScreen":1,"monoScreenInvert":1}}"#))
        cases.append(Case(name: "effect.crosshatch.full", json: #"{"effects":{"crosshatch":1,"crosshatchEdges":1,"crosshatchLineWeight":0.8,"crosshatchWave":1,"crosshatchWaveFrequency":0.7}}"#))
        cases.append(Case(name: "effect.engraving.full", json: #"{"effects":{"engraving":1,"engravingWave":1,"engravingSharpness":1,"engravingAngle":0.6}}"#))
        cases.append(Case(name: "effect.kuwahara.max", json: #"{"effects":{"kuwahara":1,"kuwaharaRadius":1,"kuwaharaSharpness":1,"kuwaharaSaturation":0.8}}"#))
        cases.append(Case(name: "effect.blurKuwahara", json: #"{"effects":{"blur":0.4,"kuwahara":0.8}}"#))
        cases.append(Case(name: "effect.dither.palette", json: ##"{"effects":{"dither":1,"ditherSize":0.5},"palette":["#101020","#504060","#a08070","#f0e0c0"]}"##))
        cases.append(Case(name: "effect.scanlines.soft", json: #"{"effects":{"scanlines":1,"scanlineCount":0.5,"scanlineSoftness":1}}"#))
        cases.append(Case(name: "effect.pixelateTapeBleed", json: #"{"effects":{"pixelate":0.3,"chromaBleed":1,"tapeDamage":0.5}}"#, noisy: true))
        cases.append(Case(name: "preset.vhs", json: #"{"preset":"vhs-playback"}"#, noisy: true))
        cases.append(Case(name: "preset.8mm", json: #"{"preset":"home-movie-8mm"}"#, noisy: true))
        cases.append(Case(name: "heavy.kuwaharaCrosshatchAscii", json: heavyJSON))
        return cases
    }

    /// The performance case: Kuwahara at full radius, crosshatch with edges, ASCII with edge rotation, plus a grade.
    static let heavyJSON = #"{"adjust":{"exposure":0.2,"contrast":0.2,"saturation":0.1},"effects":{"kuwahara":1,"kuwaharaRadius":1,"crosshatch":0.6,"crosshatchEdges":1,"ascii":0.5,"asciiSize":0.1,"asciiRotation":1}}"#
}
