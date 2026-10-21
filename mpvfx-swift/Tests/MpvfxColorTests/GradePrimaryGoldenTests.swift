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

enum GradeJSONError: Error { case notAnObject(String) }

/// Golden values of the CPU reference for every primary control and tonal wheel, and the identity at defaults.
///
/// Each expected pixel is worked by hand from the shader's formulas in double precision
/// (`applyPrimaryGrade`, `applyTonalWheels`): the unrounded values sit at least 0.2 from a rounding boundary, so the
/// renderer's 32-bit arithmetic rounds to the same byte.
final class GradePrimaryGoldenTests: XCTestCase {
    func grade(_ text: String) throws -> ColorGradeRenderer {
        let value = try JSONDecoder().decode(NativeJSONValue.self, from: Data(text.utf8))
        guard case .object(let o) = value else { throw GradeJSONError.notAnObject(text) }
        return ColorGradeRenderer(params: try XCTUnwrap(ColorGradeParams(json: o)), seedKey: "clip-1")
    }

    /// One pixel graded through the frame path (`apply`, what preview and export call).
    func graded(_ text: String, _ rgb: [UInt8]) throws -> [UInt8] {
        var px = rgb + [255]
        try grade(text).apply(&px, width: 1, height: 1, time: 0)
        return Array(px.prefix(3))
    }

    func testHighlightsLiftOnlyTheBrightTones() throws {
        // y = 0.7843: highlight mask 0.7427, + 0.6 * 0.35 * mask = 0.9403 -> 239.77; no shadow mask above 0.65.
        XCTAssertEqual(try graded(#"{"adjust":{"highlights":0.6}}"#, [200, 200, 200]), [240, 240, 240])
        XCTAssertEqual(try graded(#"{"adjust":{"highlights":0.6}}"#, [40, 40, 40]), [40, 40, 40], "no highlight mask below 0.35")
    }

    func testShadowsLiftOnlyTheDarkTones() throws {
        // y = 0.1569: shadow mask 0.8534, + 0.6 * 0.35 * mask = 0.3361 -> 85.70.
        XCTAssertEqual(try graded(#"{"adjust":{"shadows":0.6}}"#, [40, 40, 40]), [86, 86, 86])
        XCTAssertEqual(try graded(#"{"adjust":{"shadows":0.6}}"#, [230, 230, 230]), [230, 230, 230], "no shadow mask above 0.65")
    }

    func testWhitePointAndBlackPointStretchTheRange() throws {
        // White point 1 - 0.09: 0.7843 / 0.91 -> 219.78. Black point 0.09: (0.1569 - 0.09) / 0.91 -> 18.74.
        XCTAssertEqual(try graded(#"{"adjust":{"whites":0.5}}"#, [200, 200, 200]), [220, 220, 220])
        XCTAssertEqual(try graded(#"{"adjust":{"blacks":0.5}}"#, [40, 40, 40]), [19, 19, 19])
    }

    func testTintMovesGreenAgainstMagenta() throws {
        // r += 0.04, g -= 0.08, b += 0.04 on 0.502: 138.2, 107.6, 138.2.
        XCTAssertEqual(try graded(#"{"adjust":{"tint":1}}"#, [128, 128, 128]), [138, 108, 138])
    }

    func testVibranceWeighsMutedAndSkinTones() throws {
        // A skin-like orange: weight (1 - 0.549 * 0.72) * mix(1, 0.55, skin) -> 230.68, 114.22, 26.88.
        XCTAssertEqual(try graded(#"{"adjust":{"vibrance":1}}"#, [200, 120, 60]), [231, 114, 27])
        // A sky blue pulled half way to its luma by its weight: 80.36, 136.17, 178.03.
        XCTAssertEqual(try graded(#"{"adjust":{"vibrance":-0.5}}"#, [60, 140, 200]), [80, 136, 178])
    }

    func testNegativeExposureHalvesEveryChannel() throws {
        XCTAssertEqual(try graded(#"{"adjust":{"exposure":-1}}"#, [200, 100, 50]), [100, 50, 25])
    }

    func testChainedPrimaryControlsApplyInShaderOrder() throws {
        // exposure, black/white point, temperature, contrast, vibrance, saturation: 255 (clipped), 101.00, 17.70.
        let json = #"{"adjust":{"exposure":0.3,"contrast":0.2,"saturation":0.3,"temperature":-0.4}}"#
        XCTAssertEqual(try graded(json, [180, 90, 40]), [255, 101, 18])
    }

    func testTonalWheelsTintTheirOwnRange() throws {
        // Midtones at 120 degrees (green), amount 1, on mid grey: the midtone weight 0.8904 * 0.18 along the green axis.
        XCTAssertEqual(try graded(#"{"wheels":{"midtones":{"hue":120,"amount":1,"level":0}}}"#, [128, 128, 128]), [89, 144, 89])
        // Shadows at 240 degrees (blue) on a dark grey.
        XCTAssertEqual(try graded(#"{"wheels":{"shadows":{"hue":240,"amount":1,"level":0}}}"#, [30, 30, 30]), [27, 27, 71])
        // Highlights at 30 degrees, half amount, with a 0.2 level lift.
        XCTAssertEqual(try graded(#"{"wheels":{"highlights":{"hue":30,"amount":0.5,"level":0.2}}}"#, [230, 230, 230]), [255, 239, 221])
    }

    // MARK: Identity at defaults

    /// Every 8-bit value through the colour path of a grade whose controls are all at their defaults comes back
    /// unchanged, at full and at partial intensity.
    func testDefaultsAreABitExactIdentity() throws {
        for json in [#"{}"#, #"{"preset":"neutral","intensity":0.5}"#] {
            let r = try grade(json)
            for v in 0...255 {
                let x = Float(v) / 255
                for rgb in [SIMD3<Float>(x, x, x), SIMD3<Float>(x, 1 - x, Float((v * 7) % 256) / 255)] {
                    let out = r.gradeColor(rgb)
                    XCTAssertEqual((out * 255).rounded(.toNearestOrAwayFromZero), (rgb * 255).rounded(.toNearestOrAwayFromZero), "\(json) at \(rgb)")
                }
            }
        }
    }

    /// A grade written out with every control at its default value, as the inspector stores one, is inactive and
    /// leaves the frame's bytes alone.
    func testExplicitDefaultsLeaveTheFrameAlone() throws {
        let adjust = GradeValues.adjustKeys.map { "\"\($0)\":0" }.joined(separator: ",")
        let details = GradeValues.detailKeys.map { "\"\($0)\":\(GradeValues.detailDefaults[$0] ?? 0)" }.joined(separator: ",")
        let wheels = GradeValues.wheelKeys.map { "\"\($0)\":{\"hue\":0,\"amount\":0,\"level\":0}" }.joined(separator: ",")
        let json = #"{"enabled":true,"preset":"neutral","intensity":1,"adjust":{\#(adjust)},"details":{\#(details)},"wheels":{\#(wheels)}}"#
        let r = try grade(json)
        XCTAssertFalse(r.isActive)
        var px: [UInt8] = []
        for i in 0..<64 { px += [UInt8(i * 4), UInt8(255 - i * 4), UInt8(i * 3), 255] }
        let before = px
        r.apply(&px, width: 8, height: 8, time: 0)
        XCTAssertEqual(px, before)
    }

    /// An identity `.cube` at full strength changes no 8-bit value.
    func testIdentityLutIsAnIdentity() throws {
        let params = try XCTUnwrap(ColorGradeParams(json: ["lut": .object(["src": .string("id.cube"), "intensity": .number(1)])]))
        for interpolation in [CubeLUT.Interpolation.trilinear, .tetrahedral] {
            let r = ColorGradeRenderer(params: params, lut: CubeLUT.identity(size: 17), seedKey: "c", interpolation: interpolation)
            var px: [UInt8] = []
            for v in 0..<256 { px += [UInt8(v), UInt8(255 - v), UInt8((v * 37) % 256), 255] }
            let before = px
            r.apply(&px, width: 16, height: 16, time: 0)
            XCTAssertEqual(px, before, "\(interpolation)")
        }
    }
}
