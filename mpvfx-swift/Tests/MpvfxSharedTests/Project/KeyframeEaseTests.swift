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

/// Pure maths of the easing panel: influence and velocity, easy ease, and hostile input.
final class KeyframeEaseTests: XCTestCase {
    private func points(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CubicBezierControlPoints {
        CubicBezierControlPoints(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    func testLinearAndHoldProgress() {
        XCTAssertEqual(KeyframeEase.progress(.linear, at: 0.25), 0.25)
        XCTAssertEqual(KeyframeEase.progress(.hold, at: 0.99), 0)
        XCTAssertEqual(KeyframeEase.progress(.hold, at: 1), 1)
        XCTAssertEqual(KeyframeEase.slope(.linear, at: 0.7), 1)
        XCTAssertEqual(KeyframeEase.slope(.hold, at: 0.5), 0)
    }

    func testProgressEndpointsAndClamping() {
        let p = NativeInterpolation.cubicBezier(points(0.34, 1.56, 0.64, 1))
        XCTAssertEqual(KeyframeEase.progress(p, at: 0), 0)
        XCTAssertEqual(KeyframeEase.progress(p, at: 1), 1)
        XCTAssertEqual(KeyframeEase.progress(p, at: -3), 0, "time before the segment clamps to its start")
        XCTAssertEqual(KeyframeEase.progress(p, at: 9), 1)
        XCTAssertGreaterThan(KeyframeEase.progress(p, at: 0.6), 1, "an overshoot curve passes its end value")
    }

    func testHostileInputNeverReturnsNaN() {
        let bad = NativeInterpolation.cubicBezier(points(.nan, .infinity, -4, 7))
        for t in [Double.nan, -.infinity, 0, 0.5, 1, .infinity] {
            XCTAssertTrue(KeyframeEase.progress(bad, at: t).isFinite, "progress at \(t)")
            XCTAssertTrue(KeyframeEase.slope(bad, at: t).isFinite, "slope at \(t)")
        }
        XCTAssertNil(KeyframeEase.handles(points(.nan, 0, 1, 1)))
    }

    func testInfluenceAndSlopeOfTheEaseInAndOutPreset() throws {
        let h = try XCTUnwrap(KeyframeEase.handles(points(0.42, 0, 0.58, 1)))
        XCTAssertEqual(h.outInfluence, 0.42, accuracy: 1e-12); XCTAssertEqual(h.outSlope, 0)
        XCTAssertEqual(h.inInfluence, 0.42, accuracy: 1e-12); XCTAssertEqual(h.inSlope, 0, accuracy: 1e-12)
        let linearLike = try XCTUnwrap(KeyframeEase.handles(points(0.25, 0.25, 0.75, 0.75)))
        XCTAssertEqual(linearLike.outSlope, 1, accuracy: 1e-12); XCTAssertEqual(linearLike.inSlope, 1, accuracy: 1e-12)
    }

    func testHandlesRoundTripAndClamp() throws {
        let p = points(0.3, 0.6, 0.8, 0.9)
        let back = KeyframeEase.points(try XCTUnwrap(KeyframeEase.handles(p)))
        XCTAssertEqual(back.x1, p.x1, accuracy: 1e-12); XCTAssertEqual(back.y1, p.y1, accuracy: 1e-12)
        XCTAssertEqual(back.x2, p.x2, accuracy: 1e-12); XCTAssertEqual(back.y2, p.y2, accuracy: 1e-12)
        let wild = KeyframeEase.points(.init(outInfluence: 5, outSlope: 100, inInfluence: -1, inSlope: -5000))
        XCTAssertEqual(wild.x1, 1); XCTAssertEqual(wild.y1, KeyframeEase.yRange.upperBound)
        XCTAssertEqual(wild.x2, 1 - KeyframeEase.influenceRange.lowerBound, accuracy: 1e-12)
        XCTAssertEqual(wild.y2, KeyframeEase.yRange.upperBound, "in slope −5000 pulls y2 up to the range's top")
        let nan = KeyframeEase.points(.init(outInfluence: .nan, outSlope: .nan, inInfluence: .infinity, inSlope: 1))
        XCTAssertTrue([nan.x1, nan.y1, nan.x2, nan.y2].allSatisfy(\.isFinite), "non-finite numbers never reach the document")
    }

    func testVelocityIsSlopeTimesTheSegmentsLinearSpeed() {
        // 0 → 100 units over 2 s: the linear speed is 50 units/s.
        XCTAssertEqual(KeyframeEase.velocity(slope: 0.5, valueChange: -100, seconds: 2), 25)
        XCTAssertEqual(KeyframeEase.slope(velocity: 25, valueChange: 100, seconds: 2), 0.5)
        XCTAssertEqual(KeyframeEase.slope(velocity: 25, valueChange: 0, seconds: 2), 0, "a flat segment has no speed")
        XCTAssertEqual(KeyframeEase.velocity(slope: 1, valueChange: 100, seconds: 0), 0, "a zero-length segment has no speed")
    }

    func testEasyEaseSides() {
        XCTAssertEqual(KeyframeEase.easyEaseInfluence, 1.0 / 3, accuracy: 1e-12)
        let both = KeyframeEase.easyEase(.linear, out: true, in: true)
        XCTAssertEqual(both, .cubicBezier(points(1.0 / 3, 0, 1 - KeyframeEase.easyEaseInfluence, 1)))
        // Out only on a linear segment keeps its in side linear (slope 1 at the end).
        guard case .cubicBezier(let o) = KeyframeEase.easyEase(.linear, out: true, in: false) else { return XCTFail("not a curve") }
        XCTAssertEqual(o.x1, 1.0 / 3, accuracy: 1e-12); XCTAssertEqual(o.y1, 0)
        XCTAssertEqual(KeyframeEase.slope(.cubicBezier(o), at: 1), 1, accuracy: 1e-9)
        // In only keeps an existing out handle.
        let custom = NativeInterpolation.cubicBezier(points(0.2, 0.5, 0.9, 0.95))
        guard case .cubicBezier(let i) = KeyframeEase.easyEase(custom, out: false, in: true) else { return XCTFail("not a curve") }
        XCTAssertEqual(i.x1, 0.2); XCTAssertEqual(i.y1, 0.5)
        XCTAssertEqual(i.x2, 2.0 / 3, accuracy: 1e-12); XCTAssertEqual(i.y2, 1)
        XCTAssertEqual(KeyframeEase.easyEase(.hold, out: true, in: true), .hold, "a hold stays a hold")
    }
}
