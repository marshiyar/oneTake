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
// Parity helpers: localeCompare replacement, parseFloat/Number, Int64 edges.
import XCTest
@testable import MpvfxShared

final class JSParityTests: XCTestCase {
    func sorted(_ a: [String]) -> [String] { a.sorted { jsLocaleCompare($0, $1) < 0 } }

    func testLocaleCompareCaseTies() {
        // ICU default: lowercase before uppercase at tertiary; case ignored at primary.
        XCTAssertEqual(sorted(["B", "a", "A", "b"]), ["a", "A", "b", "B"])
        XCTAssertEqual(sorted(["key:B", "key:a"]), ["key:a", "key:B"])
        XCTAssertEqual(jsLocaleCompare("Ab", "aC"), -1)  // primary b < c wins over case
    }
    func testLocaleCompareAccentTies() {
        XCTAssertEqual(sorted(["é", "e", "f", "E"]), ["e", "E", "é", "f"])
        XCTAssertEqual(jsLocaleCompare("café", "cafe"), 1)
        XCTAssertEqual(jsLocaleCompare("cafe\u{301}", "caf\u{e9}"), 0)   // NFC == NFD
    }
    func testLocaleCompareDigitsAreNotNumeric() {
        XCTAssertEqual(sorted(["key10", "key9", "key1", "keyA"]), ["key1", "key10", "key9", "keyA"])
        XCTAssertEqual(sorted(["a-1", "a_1", "a1"]), ["a_1", "a-1", "a1"])
    }
    func testJsMathRoundEdgeCases() {
        XCTAssertEqual(jsMathRound(0.49999999999999994), 0)
        XCTAssertEqual(jsMathRound(4503599627370497), 4503599627370497)
        for x in [-0.5, -0.25, -0.0] {
            let r = jsMathRound(x)
            XCTAssertEqual(r, 0, "\(x)"); XCTAssertEqual(r.sign, .minus, "\(x) must round to -0")
        }
        XCTAssertEqual(jsMathRound(2.5), 3)
        XCTAssertEqual(jsMathRound(-2.5), -2)
        XCTAssertEqual(jsMathRound(0.5).sign, .plus)
    }
    func testParseFloatAndNumber() {
        XCTAssertEqual(jsParseFloat("640px"), 640); XCTAssertEqual(jsParseFloat("  -1.5e2x"), -150)
        XCTAssertTrue(jsParseFloat("auto").isNaN); XCTAssertEqual(jsParseFloat("1e"), 1); XCTAssertEqual(jsParseFloat(".5"), 0.5)
        XCTAssertEqual(jsNumber(" 40 "), 40); XCTAssertEqual(jsNumber(""), 0); XCTAssertTrue(jsNumber("40px").isNaN)
        XCTAssertEqual(jsNumber("0x10"), 16); XCTAssertTrue(jsNumber("e5").isNaN)
    }
    func testSourceTimeAtInt64Max() {
        // A frame equal to Int64.max is not a safe integer; arithmetic must throw, never wrap or trap.
        let maxFrame = Double(Int64.max)   // 2^63 exactly, not representable in Int64 -> conversion fails
        XCTAssertThrowsError(try advanceSourcePosition(NativeSourcePosition(sourceInFrame: maxFrame), playbackRate: nil, timelineFrames: 0))
        XCTAssertThrowsError(try availableTimelineFrames(NativeSourcePosition(sourceInFrame: 0), playbackRate: nil, sourceDurationFrames: maxFrame))
        XCTAssertThrowsError(try sourceRangeFits(NativeSourcePosition(sourceInFrame: 0), playbackRate: nil, durationFrames: 1, sourceDurationFrames: maxFrame))
        // Largest Int64-exact Double below 2^63: multiplication by a rate numerator of 2 overflows.
        let big = 9_223_372_036_854_774_784.0
        XCTAssertThrowsError(try sourceRangeFits(NativeSourcePosition(sourceInFrame: 0), playbackRate: .init(numerator: 2, denominator: 1),
                                                 durationFrames: big, sourceDurationFrames: 1))
    }
}
