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
// Source time math, with its Int64 range edges.
import XCTest
@testable import MpvfxShared

final class NativeSourceTimeTests: XCTestCase {
    func testRationalFromNumberRecoversSmallFractions() throws {
        XCTAssertEqual(try rationalFromNumber(1.0 / 30), NativePlaybackRate(numerator: 1, denominator: 30))
        XCTAssertEqual(try rationalFromNumber(0), NativePlaybackRate(numerator: 0, denominator: 1))
        XCTAssertThrowsError(try rationalFromNumber(-1)); XCTAssertThrowsError(try rationalFromNumber(.infinity))
    }
    func testSourcePositionFromSeconds() throws {
        let p = try sourcePositionFromSeconds(1.5, frameRate: .init(numerator: 30000, denominator: 1001))
        // 1.5 * 30000/1001 = 45000/1001 = 44 + 956/1001
        XCTAssertEqual(p, NativeSourcePosition(sourceInFrame: 44, sourceInFraction: .init(numerator: 956, denominator: 1001)))
    }
    func testAdvanceAndFit() throws {
        let clip = NativeSourcePosition(sourceInFrame: 10, sourceInFraction: .init(numerator: 1, denominator: 2))
        let rate = NativePlaybackRate(numerator: 3, denominator: 2)
        XCTAssertEqual(try advanceSourcePosition(clip, playbackRate: rate, timelineFrames: 3), NativeSourcePosition(sourceInFrame: 15))
        XCTAssertEqual(try availableTimelineFrames(clip, playbackRate: rate, sourceDurationFrames: 16), 3)
        XCTAssertTrue(try sourceRangeFits(clip, playbackRate: rate, durationFrames: 3, sourceDurationFrames: 15))
        XCTAssertFalse(try sourceRangeFits(clip, playbackRate: rate, durationFrames: 4, sourceDurationFrames: 15))
        XCTAssertThrowsError(try advanceSourcePosition(clip, playbackRate: rate, timelineFrames: -8))
        XCTAssertEqual(sourceFrameValue(clip), 10.5)
    }
    func testMaxSafeIntegerStillFits() throws {
        let p = try advanceSourcePosition(NativeSourcePosition(sourceInFrame: 9_007_199_254_740_990), playbackRate: nil, timelineFrames: 1)
        XCTAssertEqual(p.sourceInFrame, 9_007_199_254_740_991)
        XCTAssertThrowsError(try advanceSourcePosition(NativeSourcePosition(sourceInFrame: 9_007_199_254_740_991), playbackRate: nil, timelineFrames: 1))
    }
    func testInt64OverflowThrowsInsteadOfWrapping() {
        // safe-int frame * 1e9 denominator exceeds Int64 (JS BigInt would succeed).
        let clip = NativeSourcePosition(sourceInFrame: 9_007_199_254_740_991, sourceInFraction: .init(numerator: 1, denominator: 1_000_000_000))
        XCTAssertThrowsError(try advanceSourcePosition(clip, playbackRate: nil, timelineFrames: 0))
        XCTAssertThrowsError(try sourceRangeFits(clip, playbackRate: nil, durationFrames: 1, sourceDurationFrames: 9_007_199_254_740_991))
    }
}
