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
// Keyframe types and frame rates (+ JSON/decoder golden extras).
import XCTest
@testable import MpvfxShared

final class NativeKeyframeTypesTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func key(_ id: String, _ frame: Double, _ value: NativeParameterValue, _ out: NativeInterpolation = .linear) -> NativeKeyframe {
        NativeKeyframe(id: id, frame: frame, value: value, outgoing: out)
    }

    func testCreatesVersionedTypedTrackOrderedByFrame() throws {
        let track = try createNativeParameterTrack(.init(id: "track:clip-1:rotation", parameterId: "transform.rotation", valueType: .number,
            frameRate: .init(numerator: 30_000, denominator: 1_001),
            keyframes: [key("key:end", 90, .number(-180)), key("key:start", 0, .number(0))]), engine: engine)
        XCTAssertEqual(track.schemaVersion, NATIVE_KEYFRAME_SCHEMA_VERSION)
        XCTAssertEqual(track.id, "track:clip-1:rotation")
        XCTAssertEqual(track.parameterId, "transform.rotation")
        XCTAssertEqual(track.valueType, .number)
        XCTAssertEqual(track.keyframes.map(\.id), ["key:start", "key:end"])
        XCTAssertEqual(engine.validateCalls.count, 1)
    }

    func testRejectsInvalidRationalFrameRates() {
        let cases: [(RationalFrameRate, String)] = [
            (.init(numerator: 0, denominator: 1), "numerator"), (.init(numerator: 30, denominator: 0), "denominator"),
            (.init(numerator: 29.97, denominator: 1), "integer"), (.init(numerator: 30, denominator: 1.5), "integer")]
        for (rate, expected) in cases {
            XCTAssertThrowsError(try validateRationalFrameRate(rate)) { XCTAssertTrue("\($0)".contains(expected), "\($0)") }
        }
    }

    func testRejectsDuplicateKeyframeIds() {
        XCTAssertThrowsError(try createNativeParameterTrack(.init(id: "track:opacity", parameterId: "transform.opacity", valueType: .number,
            frameRate: .init(numerator: 24, denominator: 1), keyframes: [key("same", 0, .number(0)), key("same", 12, .number(1))]), engine: engine)) {
            XCTAssertTrue($0 is NativeKeyframeValidationError)
        }
    }

    func testEngineTrackErrorIsMappedToValidationError() {
        engine.rejectWith = KeyframeEngineError(code: "duplicate-keyframe-frame", message: "msg")
        XCTAssertThrowsError(try createNativeParameterTrack(.init(id: "t", parameterId: "p", valueType: .number,
            frameRate: .init(numerator: 30, denominator: 1), keyframes: [key("a", 0, .number(0))]), engine: engine)) {
            XCTAssertEqual($0 as? NativeKeyframeValidationError, NativeKeyframeValidationError(code: .duplicateKeyframeFrame, message: "Parameter track t: msg"))
        }
        engine.rejectWith = KeyframeEngineError(code: "internal", message: "boom")
        XCTAssertThrowsError(try createNativeParameterTrack(.init(id: "t", parameterId: "p", valueType: .number,
            frameRate: .init(numerator: 30, denominator: 1), keyframes: [key("a", 0, .number(0))]), engine: engine)) {
            XCTAssertEqual($0 as? KeyframeEngineError, KeyframeEngineError(code: "internal", message: "boom"))
        }
    }

    // Engine-message cases live in Tests/MpvfxSharedEngineTests (EngineKeyframeTypesTests).

    func testTrackJSONRoundTripsWithoutAddingAbsentKeys() throws {
        let json = #"{"schemaVersion":1,"id":"t","parameterId":"p","valueType":"vec2","frameRate":{"numerator":30000,"denominator":1001},"keyframes":[{"id":"k","frame":0,"value":{"x":1,"y":2},"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.1,"y1":0,"x2":0.2,"y2":1}},"outgoingPath":{"type":"curve","curviness":1}}]}"#
        let track = try JSONDecoder().decode(NativeParameterTrack.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(track)
        XCTAssertEqual(track, try JSONDecoder().decode(NativeParameterTrack.self, from: encoded))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("autoRotate"))
    }
    func testJsMathRoundAndRemainderParity() {
        XCTAssertEqual(jsMathRound(-2.5), -2); XCTAssertEqual(jsMathRound(2.5), 3); XCTAssertEqual(jsMathRound(-0.4), 0)
        XCTAssertEqual(jsRemainder(-7, 3), -1); XCTAssertEqual(jsRemainder(7, -3), 1)
    }
}

final class NativeParameterValueDecodingTests: XCTestCase {
    func decode(_ s: String) throws -> NativeParameterValue { try JSONDecoder().decode(NativeParameterValue.self, from: Data(s.utf8)) }
    func testNumber() throws { XCTAssertEqual(try decode("1.5"), .number(1.5)) }
    func testVec2WinsOverRgbaWhenBothShapesPresent() throws {
        XCTAssertEqual(try decode(#"{"x":1,"y":2,"red":0,"green":0,"blue":0,"alpha":1}"#), .vec2(.init(x: 1, y: 2, spread: .init(extra: ["red": .number(0), "green": .number(0), "blue": .number(0), "alpha": .number(1)]))))
    }
    func testShortRgbaKeysAreNotRgba() throws {
        // {x,y,r,g,b,a}: r/g/b/a are not rgba keys; x,y make it vec2.
        XCTAssertEqual(try decode(#"{"x":1,"y":2,"r":3,"g":4,"b":5,"a":6}"#),
                       .vec2(.init(x: 1, y: 2, spread: .init(extra: ["r": .number(3), "g": .number(4), "b": .number(5), "a": .number(6)]))))
        XCTAssertThrowsError(try decode(#"{"r":3,"g":4,"b":5,"a":6}"#))
    }
    // Unknown keys are carried in `spread` (keyframe values keep them; parse validation keeps static values exact).
    func testExtraKeysAllowed() throws {
        XCTAssertEqual(try decode(#"{"red":1,"green":0.5,"blue":0,"alpha":1,"extra":"z"}"#),
                       .rgba(.init(red: 1, green: 0.5, blue: 0, alpha: 1, spread: .init(extra: ["extra": .string("z")]))))
    }
    func testFallsBackToRgbaWhenVec2IncompleteOrNonNumeric() throws {
        XCTAssertEqual(try decode(#"{"x":"1","y":2,"red":1,"green":1,"blue":1,"alpha":1}"#), .rgba(.init(red: 1, green: 1, blue: 1, alpha: 1, spread: .init(extra: ["x": .string("1"), "y": .number(2)]))))
    }
    func testRejectsStringsBooleansNullArrays() {
        for s in [#""1""#, "true", "null", "[1,2]", #"{"x":"1","y":"2"}"#, #"{"x":true,"y":0}"#] {
            XCTAssertThrowsError(try decode(s), s)
        }
    }
}
