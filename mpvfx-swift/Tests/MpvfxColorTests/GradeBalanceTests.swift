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

/// Lift / Gamma / Gain / Offset and the contrast pivot (issue #176), worked by hand from `applyBalance` and
/// `applyPrimaryGrade`: lift adds `0.25 * level` scaled by (1 - x), gain multiplies by 1 + `0.5 * level`, gamma raises
/// to 1 / (1 + `0.5 * level`), offset adds `0.25 * level`. Each unrounded value is at least 0.1 from a rounding boundary.
final class GradeBalanceTests: XCTestCase {
    func graded(_ text: String, _ rgb: [UInt8]) throws -> [UInt8] {
        let value = try JSONDecoder().decode(NativeJSONValue.self, from: Data(text.utf8))
        guard case .object(let o) = value else { throw GradeJSONError.notAnObject(text) }
        var px = rgb + [255]
        ColorGradeRenderer(params: try XCTUnwrap(ColorGradeParams(json: o)), seedKey: "clip-1").apply(&px, width: 1, height: 1, time: 0)
        return Array(px.prefix(3))
    }
    func params(_ text: String) throws -> ColorGradeParams {
        let o = try XCTUnwrap(try JSONDecoder().decode(NativeJSONValue.self, from: Data(text.utf8)).objectValue, text)
        return try XCTUnwrap(ColorGradeParams(json: o))
    }
    func balance(_ wheel: String, level: Double, hue: Double = 0, amount: Double = 0) -> String {
        #"{"balance":{"\#(wheel)":{"hue":\#(hue),"amount":\#(amount),"level":\#(level)}}}"#
    }

    func testLiftMovesBlackAndKeepsWhite() throws {
        XCTAssertEqual(try graded(balance("lift", level: 1), [0, 0, 0]), [64, 64, 64])          // 0.25 -> 63.75
        XCTAssertEqual(try graded(balance("lift", level: 1), [255, 255, 255]), [255, 255, 255])
        XCTAssertEqual(try graded(balance("lift", level: 1, hue: 240, amount: 1), [255, 255, 255]), [255, 255, 255], "a coloured lift keeps white")
        let blue = try graded(balance("lift", level: 0, hue: 240, amount: 1), [0, 0, 0])
        XCTAssertGreaterThan(Int(blue[2]), 20, "a blue lift tints black: \(blue)")
    }

    func testGainScalesAndKeepsBlack() throws {
        XCTAssertEqual(try graded(balance("gain", level: 1), [0, 0, 0]), [0, 0, 0])
        XCTAssertEqual(try graded(balance("gain", level: 1, hue: 0, amount: 1), [0, 0, 0]), [0, 0, 0], "a coloured gain keeps black")
        XCTAssertEqual(try graded(balance("gain", level: 1), [100, 100, 100]), [150, 150, 150])
        XCTAssertEqual(try graded(balance("gain", level: -0.5), [200, 200, 200]), [150, 150, 150])
    }

    func testGammaBendsTheMidtonesAndKeepsTheEnds() throws {
        XCTAssertEqual(try graded(balance("gamma", level: 1), [0, 0, 0]), [0, 0, 0])
        XCTAssertEqual(try graded(balance("gamma", level: 1), [255, 255, 255]), [255, 255, 255])
        XCTAssertEqual(try graded(balance("gamma", level: 1), [64, 64, 64]), [101, 101, 101])   // 0.25098^(1/1.5) -> 101.43
        XCTAssertEqual(try graded(balance("gamma", level: -0.5), [128, 128, 128]), [102, 102, 102]) // 0.50196^(1/0.75) -> 101.73
    }

    func testOffsetShiftsEverything() throws {
        XCTAssertEqual(try graded(balance("offset", level: 0.5), [0, 0, 0]), [32, 32, 32])       // 0.125 -> 31.88
        XCTAssertEqual(try graded(balance("offset", level: 0.5), [100, 100, 100]), [132, 132, 132])
    }

    func testNeutralBalanceIsAnIdentity() throws {
        let neutral = #"{"balance":{"lift":{"hue":120,"amount":0,"level":0},"gamma":{},"gain":{"level":0},"offset":{"amount":0}}}"#
        let params = try params(neutral)
        XCTAssertFalse(params.isActive, "a neutral balance draws nothing")
        XCTAssertFalse(params.hasBalance)
    }

    func testContrastPivotsOnTheGivenLuma() throws {
        // Pivot 0.25: a pixel at luma 0.25 stays (64), mid grey moves away from it: (0.502 - 0.25) * 1.5 + 0.25 -> 160.1.
        XCTAssertEqual(try graded(#"{"adjust":{"contrast":0.5},"pivot":0.25}"#, [64, 64, 64]), [64, 64, 64])
        XCTAssertEqual(try graded(#"{"adjust":{"contrast":0.5},"pivot":0.25}"#, [128, 128, 128]), [160, 160, 160])
        // No pivot is 0.5: the existing behaviour, byte for byte.
        XCTAssertEqual(try graded(#"{"adjust":{"contrast":0.5}}"#, [64, 64, 64]), [32, 32, 32])
        XCTAssertEqual(try graded(#"{"adjust":{"contrast":0.5},"pivot":0.5}"#, [64, 64, 64]), [32, 32, 32])
    }

    func testBalanceAndPivotAreReadByTheContractRules() throws {
        let text = #"{"pivot":7,"balance":{"lift":{"hue":-90,"amount":4,"level":-3}}}"#
        let p = try params(text)
        XCTAssertEqual(p.pivot, 1)
        XCTAssertEqual(p.balance["lift"], .init(hue: 270, amount: 1, level: -1))
        XCTAssertNotEqual(ColorGradeRenderer(params: p).signature, ColorGradeRenderer(params: ColorGradeParams()).signature)
    }
}
