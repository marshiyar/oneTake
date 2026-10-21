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

/// Warmth and Tint (issue #172). Contract 3 grades scale the channels, so black stays black and a grey keeps its luma;
/// contract 2 grades (no `version`) keep the additive offsets they were graded with.
///
/// Expected bytes are worked by hand from `whiteBalanceGain`: gains (1 + 0.16 t + 0.08 n, 1 - 0.16 n, 1 - 0.16 t + 0.08 n)
/// divided by their Rec. 709 luma, for Warmth t and Tint n; each unrounded value is at least 0.1 from a rounding boundary.
final class GradeWhiteBalanceTests: XCTestCase {
    func graded(_ text: String, _ rgb: [UInt8]) throws -> [UInt8] {
        let value = try JSONDecoder().decode(NativeJSONValue.self, from: Data(text.utf8))
        guard case .object(let o) = value else { throw GradeJSONError.notAnObject(text) }
        var px = rgb + [255]
        ColorGradeRenderer(params: try XCTUnwrap(ColorGradeParams(json: o)), seedKey: "clip-1").apply(&px, width: 1, height: 1, time: 0)
        return Array(px.prefix(3))
    }

    func testContract3WarmthAndTintKeepBlackBlack() throws {
        for adjust in [#""temperature":1"#, #""temperature":-1"#, #""tint":1"#, #""tint":-1"#, #""temperature":0.6,"tint":-0.8"#] {
            XCTAssertEqual(try graded(#"{"version":3,"adjust":{\#(adjust)}}"#, [0, 0, 0]), [0, 0, 0], adjust)
        }
    }

    func testContract3WarmthAndTintScaleGreyAndWhite() throws {
        // Warmth +1: gains (1.1345, 0.9780, 0.8216) on 0.502 -> 145.22, 125.19, 105.16.
        XCTAssertEqual(try graded(#"{"version":3,"adjust":{"temperature":1}}"#, [128, 128, 128]), [145, 125, 105])
        // Tint +1: gains (1.1890, 0.9248, 1.1890) -> 152.19, 118.37, 152.19; on white 255, 235.81, 255.
        XCTAssertEqual(try graded(#"{"version":3,"adjust":{"tint":1}}"#, [128, 128, 128]), [152, 118, 152])
        XCTAssertEqual(try graded(#"{"version":3,"adjust":{"tint":1}}"#, [255, 255, 255]), [255, 236, 255])
        // Warmth -1: gains (0.8593, 1.0230, 1.1867) -> white 219.12, 255, 255.
        XCTAssertEqual(try graded(#"{"version":3,"adjust":{"temperature":-1}}"#, [255, 255, 255]), [219, 255, 255])
    }

    func testContract3KeepsAGreysLuma() throws {
        for adjust in [#""temperature":1"#, #""temperature":-1"#, #""tint":1"#, #""tint":-0.5"#] {
            let out = try graded(#"{"version":3,"adjust":{\#(adjust)}}"#, [100, 100, 100])
            let luma = 0.2126 * Double(out[0]) + 0.7152 * Double(out[1]) + 0.0722 * Double(out[2])
            XCTAssertEqual(luma, 100, accuracy: 0.75, "\(adjust): \(out)")
        }
    }

    /// A grade stored without a version (contract 2) renders exactly as before: the additive offsets.
    func testContract2GradesKeepTheirLook() throws {
        XCTAssertEqual(try graded(#"{"adjust":{"temperature":1}}"#, [0, 0, 0]), [20, 0, 0])
        XCTAssertEqual(try graded(#"{"version":2,"adjust":{"temperature":-1}}"#, [0, 0, 0]), [0, 0, 20])
        XCTAssertEqual(try graded(#"{"adjust":{"tint":1}}"#, [0, 0, 0]), [10, 0, 10])
        XCTAssertEqual(try graded(#"{"adjust":{"temperature":1}}"#, [128, 128, 128]), [148, 128, 108])
        XCTAssertEqual(try graded(#"{"version":"x","adjust":{"temperature":1}}"#, [128, 128, 128]), [148, 128, 108], "an unreadable version is 2")
    }

    func testSecondaryWarmthFollowsTheContract() throws {
        let secondary = #""secondaries":[{"key":{"hue":{"center":0,"range":180,"softness":0}},"correction":{"temperature":1}}]"#
        XCTAssertEqual(try graded(#"{"version":3,\#(secondary)}"#, [0, 0, 0]), [0, 0, 0], "contract 3: black stays black")
        XCTAssertEqual(try graded(#"{\#(secondary)}"#, [0, 0, 0]), [20, 0, 0], "contract 2: the additive offset")
        let warm = try graded(#"{"version":3,\#(secondary)}"#, [128, 128, 128])
        XCTAssertGreaterThan(Int(warm[0]), Int(warm[2]) + 30, "the secondary still warms a grey: \(warm)")
    }

    func testTheVersionIsPartOfTheRendererSignature() throws {
        let v2 = ColorGradeRenderer(params: try XCTUnwrap(ColorGradeParams(json: ["adjust": .object(["temperature": .number(1)])])))
        let v3 = ColorGradeRenderer(params: try XCTUnwrap(ColorGradeParams(json: ["version": .number(3), "adjust": .object(["temperature": .number(1)])])))
        XCTAssertNotEqual(v2.signature, v3.signature, "a cached contract 2 frame is not reused for contract 3")
    }
}
