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
import XCTest
@testable import MpvfxColor
import MpvfxShared

/// Expected values are recorded reference values of the grading engine 0.8.20 (curves, LUTs and grade normalization,
/// evaluated once) or are worked by hand from the grading shader's formulas.
final class ColorGradeTests: XCTestCase {
    // MARK: Helpers

    func grade(_ json: NativeJSONObject, lut: CubeLUT? = nil) -> ColorGradeRenderer {
        ColorGradeRenderer(params: ColorGradeParams(json: json)!, lut: lut, seedKey: "clip-1")
    }

    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255, width: Int = 8, height: Int = 8) -> [UInt8] {
        (0..<(width * height)).flatMap { _ in [r, g, b, a] }
    }

    func pixel(_ px: [UInt8], _ x: Int, _ y: Int, width: Int) -> [UInt8] { let i = (y * width + x) * 4; return Array(px[i..<i + 4]) }

    func applied(_ r: ColorGradeRenderer, _ px: [UInt8], width: Int = 8, height: Int = 8, time: Double = 0) -> [UInt8] {
        var out = px; r.apply(&out, width: width, height: height, time: time); return out
    }

    func json(_ s: String) -> NativeJSONObject {
        let v = try! JSONDecoder().decode(NativeJSONValue.self, from: Data(s.utf8))
        guard case .object(let o) = v else { fatalError("not an object") }
        return o
    }

    /// A test card: gradients plus a hard edge, so spatial effects have something to work on.
    func card(width: Int, height: Int) -> [UInt8] {
        var px: [UInt8] = []
        for y in 0..<height { for x in 0..<width {
            let r = UInt8(x * 255 / max(1, width - 1)), g = UInt8(y * 255 / max(1, height - 1))
            let b: UInt8 = x < width / 2 ? 40 : 220
            px += [r, g, b, 255]
        } }
        return px
    }

    // MARK: Curves (compileHfColorCurve / compileHfHueCurve)

    func testRgbCurveMatchesTSCompiler() {
        let c = ColorCurves.compile([[0, 0], [0.25, 0.15], [0.75, 0.9], [1, 1]])!
        let expected: [(Int, Double)] = [(0, 0), (100, 0.04269644618034363), (256, 0.15020021796226501), (511, 0.5381211638450623),
                                         (767, 0.8998546600341797), (1023, 1)]
        for (i, v) in expected { XCTAssertEqual(c[i], v, accuracy: 1e-7, "index \(i)") }
        XCTAssertNil(ColorCurves.compile([[0.1, 0], [1, 1]]), "curves must start at 0")
    }

    func testHueCurveMatchesTSCompiler() {
        let h = ColorCurves.compileHue([[0, 30], [120, -40], [240, 10]], outputMin: -180, outputMax: 180)!
        let expected: [(Int, Double)] = [(0, 30), (100, 15.495954513549805), (341, -39.99980163574219), (512, -18.571428298950195),
                                         (682, 9.943842887878418), (1000, 29.848594665527344)]
        for (i, v) in expected { XCTAssertEqual(h[i], v, accuracy: 1e-5, "index \(i)") }
        XCTAssertNil(ColorCurves.compileHue([[0, 1], [10, 1]], outputMin: -1, outputMax: 1), "three points at least")
    }

    // MARK: .cube parsing (parseCubeLut / packCubeLutToRgba8)

    let cube = "TITLE \"t\"\n# c\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1.2\n"

    func testCubeParseMatchesTS() throws {
        let lut = try CubeLUT(parsing: cube)
        XCTAssertEqual(lut.title, "t")
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.table[1], SIMD3(1, 0, 0))
        XCTAssertEqual(lut.table[7].z, 1.2, accuracy: 1e-6)
        // The upload clamps to 0…1 and rounds to bytes.
        XCTAssertEqual(lut.quantized8.table[7], SIMD3(1, 1, 1))
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")) { e in
            XCTAssertEqual("\(e)", "1D cube LUTs are not supported yet at line 2") }
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n")) { e in
            XCTAssertEqual("\(e)", "Expected 8 LUT rows for size 2, found 1") }
        XCTAssertThrowsError(try CubeLUT(parsing: "LUT_3D_SIZE 65\n")) { e in
            XCTAssertEqual("\(e)", "LUT_3D_SIZE 65 exceeds max 64 at line 1") }
    }

    func testCubeSamplingTrilinearAndTetrahedral() throws {
        let id = CubeLUT.identity(size: 17)
        let c = SIMD3<Float>(0.13, 0.62, 0.91)
        for mode in [CubeLUT.Interpolation.trilinear, .tetrahedral] {
            let s = id.sample(c, interpolation: mode)
            XCTAssertEqual(s.x, c.x, accuracy: 1e-5); XCTAssertEqual(s.y, c.y, accuracy: 1e-5); XCTAssertEqual(s.z, c.z, accuracy: 1e-5)
        }
        // A non-linear 2-point cube: the two schemes agree on the lattice and differ inside a cell.
        var t = id; t = CubeLUT.identity(size: 2)
        t.table[7] = SIMD3(0.5, 0.5, 0.5)   // white maps to grey
        XCTAssertEqual(t.sample(SIMD3(1, 1, 1), interpolation: .tetrahedral), SIMD3(0.5, 0.5, 0.5))
        let mid = SIMD3<Float>(0.5, 0.5, 0.5)
        XCTAssertNotEqual(t.sample(mid, interpolation: .trilinear), t.sample(mid, interpolation: .tetrahedral))
        // Strength mixes with the input.
        let inv = CubeLUT(size: 2, table: id.table.isEmpty ? [] : CubeLUT.identity(size: 2).table.map { SIMD3(1, 1, 1) - $0 })
        XCTAssertEqual(inv.apply(SIMD3(0.2, 0.2, 0.2), strength: 0.5).x, 0.5, accuracy: 1e-6)
        // Domain clamps.
        let wide = CubeLUT(size: 2, table: CubeLUT.identity(size: 2).table, domainMin: SIMD3(repeating: 0), domainMax: SIMD3(repeating: 2))
        XCTAssertEqual(wide.sample(SIMD3(1, 1, 1)).x, 0.5, accuracy: 1e-6)
        XCTAssertTrue(try CubeLUT(parsing: id.cubeText).table.count == 17 * 17 * 17)
    }

    // MARK: Normalization (normalizeHfColorGrading)

    func testNormalizationMatchesTS() {
        let p = ColorGradeParams(json: json("""
        {"preset":"vhs-playback","adjust":{"exposure":3},"effects":{"scanlines":0.5},"details":{},
         "wheels":{"shadows":{"hue":-30,"amount":2,"level":-0.5}},"curves":{"master":[[0.2,0.3],[0.8,0.7]]},
         "hueCurves":{"hueVsHue":[[10,200],[100,0],[370,5]]},
         "secondaries":[{"key":{"hue":{"center":400,"range":170,"softness":30},"saturation":{"min":0.8,"max":0.2}},"correction":{"hueShift":500}}],
         "lut":{"src":" a.cube ","intensity":2}}
        """))!
        XCTAssertEqual(p.adjust("exposure"), 2)
        XCTAssertEqual(p.adjust("contrast"), -0.04)          // from the preset
        XCTAssertEqual(p.adjust("saturation"), -0.08)
        XCTAssertEqual(p.wheels["shadows"], .init(hue: 330, amount: 1, level: -0.5))
        XCTAssertEqual(p.curves["master"], [[0, 0], [0.2, 0.3], [0.8, 0.7], [1, 1]])
        XCTAssertEqual(p.hueCurves["hueVsHue"], [])           // 370 wraps onto 10: duplicate input
        XCTAssertEqual(p.secondaries.count, 1)
        let s = p.secondaries[0]
        XCTAssertEqual(s.hueCenter, 40); XCTAssertEqual(s.hueRange, 170); XCTAssertEqual(s.hueSoftness, 10)
        XCTAssertEqual(s.saturation, .init(min: 0.2, max: 0.8, softness: 0.05))
        XCTAssertEqual(s.hueShift, 180)
        XCTAssertEqual(p.lut, .init(src: "a.cube", intensity: 1))
        XCTAssertEqual(p.detail("grain"), 0.16)
        XCTAssertEqual(p.effect("tapeNoise"), 0.3)
        XCTAssertEqual(p.effect("scanlines"), 0.5)
        XCTAssertEqual(p.effect("scanlineCount"), 0.17)
        XCTAssertEqual(p.effect("asciiSize"), 5.0 / 76)
        XCTAssertEqual(p.intensity, 1)
        XCTAssertEqual(ColorGradeParams(json: json("{\"preset\":\"home-movie-8mm\"}"))!.intensity, 0.72)
        XCTAssertEqual(ColorGradeParams(json: json("{}"))!.effect("tapeNoise"), 1)
        XCTAssertNil(ColorGradeParams(json: json("{\"enabled\":false,\"adjust\":{\"exposure\":1}}")))
        XCTAssertFalse(ColorGradeParams(json: json("{\"preset\":\"neutral\"}"))!.isActive)
        XCTAssertTrue(ColorGradeParams(json: json("{\"preset\":\"warm-daylight\"}"))!.isActive)
    }

    func testClipGradeReadsTheFirstColorGradingEffect() {
        var clip = NativeProjectClip.fresh(id: "c", assetId: "a", startFrame: 0, durationFrames: 10)
        XCTAssertNil(ColorGradeParams.clipGrade(clip))
        clip.effects = [NativeClipEffect(id: "e1", effectId: "color-grading", enabled: true, parameters: json("{\"adjust\":{\"exposure\":1}}"))]
        XCTAssertEqual(ColorGradeParams.clipGrade(clip)?.adjust("exposure"), 1)
        clip.effects[0].enabled = false
        XCTAssertNil(ColorGradeParams.clipGrade(clip))
    }

    func testSeedIsTheTSHash() {
        // FNV-1a % 10000 over UTF-16 units (runtime Nb()).
        XCTAssertEqual(colorGradeSeed(""), Int(2_166_136_261 % 10_000))
        XCTAssertEqual(colorGradeSeed("a"), Int(UInt32(0xE40C292C) % 10_000))
    }

    // MARK: Shader, worked by hand from its formulas

    func testInactiveGradeLeavesPixelsAlone() {
        let r = grade(json("{\"preset\":\"neutral\"}"))
        let px = card(width: 8, height: 8)
        XCTAssertEqual(applied(r, px), px)
    }

    func testExposureDoublesLight() {
        // 64/255 * 2^1 = 0.50196 -> 128.
        let out = applied(grade(json("{\"adjust\":{\"exposure\":1}}")), solid(64, 64, 64))
        XCTAssertEqual(pixel(out, 3, 3, width: 8), [128, 128, 128, 255])
    }

    func testSaturationAndIntensity() {
        // Saturation -1 turns pure red into its Rec.709 luma: 0.2126 -> 54.
        XCTAssertEqual(pixel(applied(grade(json("{\"adjust\":{\"saturation\":-1}}")), solid(255, 0, 0)), 0, 0, width: 8), [54, 54, 54, 255])
        // Intensity 0.5 mixes half way: 1 -> 0.6063 (155), 0 -> 0.1063 (27).
        XCTAssertEqual(pixel(applied(grade(json("{\"adjust\":{\"saturation\":-1},\"intensity\":0.5}")), solid(255, 0, 0)), 0, 0, width: 8), [155, 27, 27, 255])
    }

    func testTemperatureShiftsRedAndBlue() {
        // r += 0.08, b -= 0.08 on 128/255: 148 and 108.
        XCTAssertEqual(pixel(applied(grade(json("{\"adjust\":{\"temperature\":1}}")), solid(128, 128, 128)), 0, 0, width: 8), [148, 128, 108, 255])
    }

    func testContrastPivotsOnHalf() {
        // (0.25098 - 0.5) * 1.5 + 0.5 = 0.12647 -> 32.
        XCTAssertEqual(pixel(applied(grade(json("{\"adjust\":{\"contrast\":0.5}}")), solid(64, 64, 64)), 0, 0, width: 8), [32, 32, 32, 255])
    }

    func testLutStage() throws {
        let inv = CubeLUT(size: 2, table: CubeLUT.identity(size: 2).table.map { SIMD3(1, 1, 1) - $0 })
        let full = grade(json("{\"lut\":{\"src\":\"x.cube\",\"intensity\":1}}"), lut: inv)
        XCTAssertEqual(pixel(applied(full, solid(64, 128, 192)), 0, 0, width: 8), [191, 127, 63, 255])
        let half = grade(json("{\"lut\":{\"src\":\"x.cube\",\"intensity\":0.5}}"), lut: inv)
        XCTAssertTrue(pixel(applied(half, solid(64, 128, 192)), 0, 0, width: 8).prefix(3).allSatisfy { abs(Int($0) - 128) <= 1 })
        // A grade whose LUT file did not load leaves the LUT stage out.
        XCTAssertEqual(applied(grade(json("{\"lut\":\"x.cube\"}")), solid(64, 128, 192)), solid(64, 128, 192))
    }

    func testHueVsHueTurnsRedCyanKeepingLuma() {
        // +180 degrees everywhere: hue + 0.5 turn, then the original luma is restored: (1,0,0) -> (0, 0.4252, 0.4252).
        let r = grade(json("{\"hueCurves\":{\"hueVsHue\":[[0,180],[120,180],[240,180]]}}"))
        XCTAssertEqual(pixel(applied(r, solid(255, 0, 0)), 0, 0, width: 8), [0, 108, 108, 255])
    }

    func testSecondaryQualifiesOnlyItsHue() {
        let r = grade(json("""
        {"secondaries":[{"key":{"hue":{"center":0,"range":30,"softness":0}},"correction":{"saturation":-1}}]}
        """))
        var px = solid(255, 0, 0, width: 2, height: 1)
        px[4] = 0; px[5] = 255; px[6] = 0
        r.apply(&px, width: 2, height: 1, time: 0)
        XCTAssertEqual(Array(px[0..<4]), [54, 54, 54, 255])     // red desaturated to its luma
        XCTAssertEqual(Array(px[4..<8]), [0, 255, 0, 255])      // green untouched
    }

    func testMasterCurve() {
        // Master curve through (0.5, 0.25): mid grey goes to about a quarter.
        let out = applied(grade(json("{\"curves\":{\"master\":[[0,0],[0.5,0.25],[1,1]]}}")), solid(128, 128, 128))
        XCTAssertEqual(Double(out[0]), 64, accuracy: 1.5)
        XCTAssertEqual(out[0], out[1]); XCTAssertEqual(out[1], out[2])
    }

    func testWheelLevelLiftsNeutrally() {
        let out = applied(grade(json("{\"wheels\":{\"midtones\":{\"hue\":0,\"amount\":0,\"level\":0.4}}}")), solid(128, 128, 128))
        XCTAssertGreaterThan(out[0], 128)
        XCTAssertEqual(out[0], out[1]); XCTAssertEqual(out[1], out[2])
        let tinted = applied(grade(json("{\"wheels\":{\"highlights\":{\"hue\":0,\"amount\":1,\"level\":0}}}")), solid(230, 230, 230))
        XCTAssertGreaterThan(tinted[0], tinted[2], "a red highlight wheel warms the highlights")
    }

    func testVignetteDarkensCornersOnly() {
        let w = 64, h = 36
        let out = applied(grade(json("{\"details\":{\"vignette\":1}}")), solid(255, 255, 255, width: w, height: h), width: w, height: h)
        XCTAssertEqual(pixel(out, w / 2, h / 2, width: w), [255, 255, 255, 255])
        let corner = pixel(out, 0, 0, width: w)[0]
        XCTAssertLessThan(corner, 120)
        XCTAssertGreaterThanOrEqual(corner, 63)   // at most 75% darker
        XCTAssertEqual(pixel(out, 0, 0, width: w), pixel(out, w - 1, h - 1, width: w))
    }

    func testGrainFollowsTimeAndIsRepeatable() {
        let r = grade(json("{\"details\":{\"grain\":1}}"))
        let px = solid(128, 128, 128, width: 32, height: 32)
        let a = applied(r, px, width: 32, height: 32, time: 1), b = applied(r, px, width: 32, height: 32, time: 1)
        let c = applied(r, px, width: 32, height: 32, time: 1.5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, px)
        // Grain is subtle: within 8% of full scale.
        XCTAssertTrue(zip(a, px).allSatisfy { abs(Int($0) - Int($1)) <= 24 })
    }

    func testScanlinesDarkenRowsNotColumns() {
        let w = 16, h = 64
        let out = applied(grade(json("{\"effects\":{\"scanlines\":1,\"scanlineCount\":0}}")), solid(255, 255, 255, width: w, height: h), width: w, height: h)
        let rows = (0..<h).map { pixel(out, 0, $0, width: w)[0] }
        XCTAssertLessThan(rows.min()!, 120)
        XCTAssertGreaterThan(rows.max()!, 200)
        for y in 0..<h { XCTAssertEqual(pixel(out, 0, y, width: w), pixel(out, w - 1, y, width: w)) }
    }

    /// Every stylize effect changes a test card, keeps its alpha, and renders the same twice.
    func testEveryStylizeEffectRenders() {
        let w = 96, h = 64
        let px = card(width: w, height: h)
        for key in ColorGradeParams.activeEffectKeys {
            var extra = ""
            if key == "digitalGlitch" { extra = ",\"digitalGlitchColorSplit\":1,\"digitalGlitchLineTear\":1,\"digitalGlitchBlockDisplacement\":1,\"digitalGlitchBlockOpacity\":1" }
            let r = grade(json("{\"effects\":{\"\(key)\":1\(extra)}}"))
            XCTAssertTrue(r.isActive, key)
            let a = applied(r, px, width: w, height: h, time: 0.5), b = applied(r, px, width: w, height: h, time: 0.5)
            XCTAssertEqual(a, b, "\(key) is deterministic")
            XCTAssertNotEqual(a, px, "\(key) changes the picture")
            XCTAssertTrue(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 255 }, "\(key) keeps alpha")
        }
    }

    func testHalftoneUsesPrintInks() {
        let w = 64, h = 64
        let out = applied(grade(json("{\"effects\":{\"halftone\":1}}")), solid(255, 255, 255, width: w, height: h), width: w, height: h)
        // White paper prints (almost) no ink: most pixels are the paper colour (0.975, 0.962, 0.925).
        var counts: [[UInt8]: Int] = [:]
        for y in 0..<h { for x in 0..<w { counts[pixel(out, x, y, width: w), default: 0] += 1 } }
        XCTAssertEqual(counts.max { $0.value < $1.value }?.key, [249, 245, 236, 255])
    }

    func testTransparentPixelsStayTransparent() {
        let out = applied(grade(json("{\"adjust\":{\"exposure\":1},\"details\":{\"vignette\":0.5}}")), solid(10, 20, 30, 0))
        XCTAssertTrue(stride(from: 3, to: out.count, by: 4).allSatisfy { out[$0] == 0 })
    }

    func testGradeColorMatchesFramePath() {
        let r = grade(json("{\"preset\":\"food-pop\"}"))
        let c = r.gradeColor(SIMD3(0.4, 0.5, 0.6))
        let out = applied(r, solid(102, 128, 153))
        let ref = r.gradeColor(SIMD3(102, 128, 153) / 255)
        XCTAssertEqual(Int((ref.x * 255).rounded()), Int(out[0]))
        XCTAssertGreaterThan(c.x, 0)
    }
}
