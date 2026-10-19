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
// Keyframe engine limit tests against the real C++ engine (the keyframe engine via KeyframeRuntime).
import Foundation
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

private func key(_ f: Double, _ v: NativeParameterValue, _ o: NativeInterpolation) -> VkfTrack.Key { .init(frame: f, value: v, outgoing: o) }
private let black = NativeParameterValue.rgba(RgbaValue(red: 0, green: 0, blue: 0, alpha: 1))
private let white = NativeParameterValue.rgba(RgbaValue(red: 1, green: 1, blue: 1, alpha: 1))
private let rgba = VkfTrack(valueType: .rgba, keyframes: [key(0, black, .linear), key(10, white, .hold)])
// y(0) == y(0.5) == 0: a cut at or past the midpoint cannot be one cubic segment, so slice falls back to one
// generated key per frame.
private let flat = NativeInterpolation.cubicBezier(CubicBezierControlPoints(x1: 1.0 / 3, y1: 1, x2: 2.0 / 3, y2: -4.0 / 3))
private let fallback = VkfTrack(valueType: .number, keyframes: [key(0, .number(0), flat), key(2_000_000_000, .number(1), .hold)])
private let shortFallback = VkfTrack(valueType: .number, keyframes: [fallback.keyframes[0], key(2000, .number(1), .hold)])

private func fast(_ run: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
    let started = Date()
    run()
    XCTAssertLessThan(Date().timeIntervalSince(started) * 1000, 1000, file: file, line: line)
}
private func limitCode(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let e as KeyframeEngineError { return e.isLimitError ? e.code : "other:\(e.code)" } catch { return "\(error)" }
}

final class VkfEngineLimitsTests: XCTestCase {
    // describe("engine frame budget")
    func testIs24HoursAt120fps() {
        XCTAssertEqual(VKF_MAX_MATERIALIZED_FRAMES, 10_368_000)
    }

    func testNativeModuleRejectsOversizedSamplesAndSlicesWithLimitExceeded() throws {
        let native = try KeyframeRuntime()
        fast { XCTAssertEqual(limitCode { _ = try native.sample(rgba, firstFrame: 0, count: 100_000_000) }, "limit-exceeded") }
        fast { XCTAssertEqual(limitCode { _ = try native.slice(fallback, fromFrame: 0, untilFrameExclusive: 1_000_000_001) }, "limit-exceeded") }
        XCTAssertEqual(try native.sample(rgba, firstFrame: 0, count: 100).count, 400)
    }

    // describe("module engine")
    func testModuleEngineThrowsLimitErrorForSampleCountsAboveTheBudget() throws {
        let engine = try KeyframeRuntime()
        fast { XCTAssertEqual(limitCode { _ = try engine.sample(rgba, firstFrame: 0, count: Int(VKF_MAX_MATERIALIZED_FRAMES) + 1) }, "limit-exceeded") }
        fast { XCTAssertEqual(limitCode { _ = try engine.sample(rgba, firstFrame: 0, count: 100_000_000) }, "limit-exceeded") }
        XCTAssertEqual(try engine.sample(rgba, firstFrame: 0, count: 10).count, 40)
    }

    func testModuleEngineThrowsLimitErrorWhenASliceWouldGenerateMoreKeysThanTheBudget() throws {
        let engine = try KeyframeRuntime()
        var thrown: Error?
        fast { do { _ = try engine.slice(fallback, fromFrame: 0, untilFrameExclusive: 1_000_000_001) } catch { thrown = error } }
        let limit = try XCTUnwrap(thrown as? KeyframeEngineError)
        XCTAssertTrue(limit.isLimitError)
        XCTAssertEqual(limit.code, "limit-exceeded")
        XCTAssertEqual(try engine.slice(shortFallback, fromFrame: 0, untilFrameExclusive: 1001).count, 1001)
    }

    func testModuleEngineBakeTrackSamplesFailsFastForAKeyBeyondTheBudget() throws {
        let engine = try KeyframeRuntime()
        let far = VkfTrack(valueType: .rgba, keyframes: [rgba.keyframes[0], key(50_000_000, white, .hold)])
        fast { XCTAssertEqual(limitCode { _ = try bakeTrackSamples(engine, far, frameCount: 100) }, "limit-exceeded") }
    }

    // Swift-only: bakeTrackSamples over the real engine (vec2 adds angles; nil where the engine gives NaN).
    func testBakeTrackSamplesOverTheRealEngine() throws {
        let engine = try KeyframeRuntime()
        let v = VkfTrack(valueType: .vec2, keyframes: [key(0, .vec2(Vec2Value(x: 0, y: 0)), .linear), key(2, .vec2(Vec2Value(x: 2, y: 4)), .hold)])
        let baked = try bakeTrackSamples(engine, v, frameCount: 4)
        XCTAssertEqual(baked.samples, [0, 0, 1, 2, 2, 4, 2, 4])
        XCTAssertEqual(baked.angles?.count, 4)
        XCTAssertEqual(baked.angles, try (0..<4).map { f -> Double? in let a = try engine.tangentAngle(v, frame: Double(f)); return a.isNaN ? nil : a })
        XCTAssertEqual(jsJSONStringify(try bakeTrackSamples(engine, rgba, frameCount: 0).jsonValue).hasPrefix(#"{"valueType":"rgba","samples":[0,0,0,1,"#), true)
        let replay = VkfBakedEngine(version: engine.version, lookup: { $0 == v ? baked : nil })
        for f in 0..<6 { XCTAssertEqual(try replay.evaluate(v, frame: Double(f)), try engine.evaluate(v, frame: Double(f)), "frame \(f)") }
    }
}
