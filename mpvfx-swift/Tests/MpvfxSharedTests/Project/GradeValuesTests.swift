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
import MpvfxShared

/// The grade reading rules shared by the renderer and the inspector: hostile and out-of-range stored values read as
/// a typed, clamped number and never as NaN, infinity or a value past the contract limit.
final class GradeValuesTests: XCTestCase {
    func testOutOfRangeValuesClampToTheContractLimits() {
        XCTAssertEqual(GradeValues.limited(.number(5), fallback: 0, GradeValues.adjustLimit("exposure")), 2)
        XCTAssertEqual(GradeValues.limited(.number(-5), fallback: 0, GradeValues.adjustLimit("exposure")), -2)
        XCTAssertEqual(GradeValues.limited(.number(1.5), fallback: 0, GradeValues.adjustLimit("contrast")), 1)
        XCTAssertEqual(GradeValues.limited(.number(-1e308), fallback: 0, GradeValues.adjustLimit("saturation")), -1)
        XCTAssertEqual(GradeValues.limited(.number(-0.3), fallback: 0, GradeValues.detailLimit("vignette")), 0)
        XCTAssertEqual(GradeValues.limited(.number(-0.3), fallback: 0, GradeValues.detailLimit("vignetteRoundness")), -0.3)
        XCTAssertEqual(GradeValues.limited(.number(2), fallback: 0, GradeValues.wheelAmountLimit), 1)
        XCTAssertEqual(GradeValues.limited(.number(-2), fallback: 0, GradeValues.wheelLevelLimit), -1)
    }

    func testNonFiniteAndNonNumericValuesReadAsZero() {
        let limit = GradeValues.adjustLimit("contrast")
        for hostile: NativeJSONValue in [.number(.nan), .number(.infinity), .number(-.infinity), .string("abc"), .string("1e999"),
                                         .array([.number(1)]), .object(["x": .number(1)])] {
            XCTAssertEqual(GradeValues.limited(hostile, fallback: 0.4, limit), 0, "\(hostile)")
        }
    }

    func testStringsBooleansAndNullReadAsJavaScriptNumbers() {
        let limit = GradeValues.adjustLimit("contrast")
        XCTAssertEqual(GradeValues.limited(.string(" 0.25 "), fallback: 0, limit), 0.25)
        XCTAssertEqual(GradeValues.limited(.string(""), fallback: 0.4, limit), 0, "Number('') is 0")
        XCTAssertEqual(GradeValues.limited(.bool(true), fallback: 0, limit), 1)
        XCTAssertEqual(GradeValues.limited(.bool(false), fallback: 0.4, limit), 0)
        XCTAssertEqual(GradeValues.limited(.null, fallback: 0.4, limit), 0.4, "null takes the fallback, as an absent key does")
        XCTAssertEqual(GradeValues.limited(nil, fallback: 0.4, limit), 0.4)
        XCTAssertEqual(GradeValues.limited(nil, fallback: nil, limit), 0)
    }

    func testHuesWrapIntoOneTurn() {
        XCTAssertEqual(GradeValues.wrapDegrees(.number(370)), 10)
        XCTAssertEqual(GradeValues.wrapDegrees(.number(-30)), 330)
        XCTAssertEqual(GradeValues.wrapDegrees(.number(720)), 0)
        XCTAssertEqual(GradeValues.wrapDegrees(.string("90")), 90)
        XCTAssertEqual(GradeValues.wrapDegrees(.number(.nan), fallback: 12), 12)
        XCTAssertEqual(GradeValues.wrapDegrees(.array([]), fallback: 12), 12)
    }

    func testIntensityClampsAndFallsBackToThePreset() {
        XCTAssertEqual(GradeValues.intensity(.number(1.7), fallback: 0.72), 1)
        XCTAssertEqual(GradeValues.intensity(.number(-1), fallback: 0.72), 0)
        XCTAssertEqual(GradeValues.intensity(nil, fallback: 0.72), 0.72)
        XCTAssertEqual(GradeValues.intensity(.string("x"), fallback: 0.72), 0.72)
        XCTAssertEqual(GradeValues.intensity(.object([:]), fallback: 0.72), 0.72)
        XCTAssertEqual(GradeValues.intensity(.null, fallback: 0.72), 0, "Number(null) is 0")
    }
}
