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
@testable import MpvfxShared

final class NativeSpeedRampTests: XCTestCase {
    func testConstantTwoXExactlyMatchesPlaybackRateForEveryFrame() {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 2)])
        for frame in 0...300 {
            XCTAssertEqual(ramp.sourcePosition(atClipFrame: Double(frame)), Double(frame) * 2)
        }
    }

    func testTenMinuteSlowMiddleHasLessThanHalfFrameIntegrationDrift() {
        let duration = 10.0 * 60 * 60 // 10 minutes at 60 fps
        let ramp = NativeSpeedRamp(points: [
            .init(t: 0, speed: 1), .init(t: duration * 0.25, speed: 1),
            .init(t: duration * 0.40, speed: 0.25, ease: .cubicBezier(.init(x1: 0.42, y1: 0, x2: 0.58, y2: 1))),
            .init(t: duration * 0.60, speed: 0.25), .init(t: duration * 0.75, speed: 1),
        ])
        var stepped = 0.0
        for frame in 0..<Int(duration) { stepped += ramp.sourcePosition(atClipFrame: Double(frame + 1)) - ramp.sourcePosition(atClipFrame: Double(frame)) }
        XCTAssertLessThan(abs(stepped - ramp.sourcePosition(atClipFrame: duration)), 0.5)
    }

    func testInverseRoundTripsSourcePositions() {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 0.5), .init(t: 100, speed: 3), .init(t: 300, speed: 1)])
        for frame in stride(from: 0.0, through: 300, by: 1.25) {
            XCTAssertEqual(ramp.clipFrame(atSourcePosition: ramp.sourcePosition(atClipFrame: frame), durationFrames: 300), frame, accuracy: 1e-8)
        }
    }

    func testOneThousandRandomSplitMapsAreContinuousAtCut() {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 100, speed: 0.2), .init(t: 500, speed: 4)])
        var state: UInt64 = 0x269
        for _ in 0..<1_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let cut = 1 + Double(state % 498)
            let right = ramp.sliced(from: cut, until: 500)
            XCTAssertEqual(ramp.sourcePosition(atClipFrame: cut) + right.sourcePosition(atClipFrame: 0),
                           ramp.sourcePosition(atClipFrame: cut), accuracy: 1e-9)
        }
    }
}
