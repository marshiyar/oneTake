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
// Golden-message tests: for track errors left to the engine, the validation message is
// what the toast shows ("Parameter track <id>: <engine message>"). Real KeyframeRuntime; nothing is stubbed.
import XCTest
import OneTakeKeyframes
@testable import MpvfxShared

final class EngineTrackShapeMessageTests: XCTestCase {
    var e: KeyframeRuntime!
    override func setUpWithError() throws { e = try KeyframeRuntime() }

    func issues(valueType: String, keyframes: String) throws -> [NativeProjectDocumentValidationIssue] {
        let text = """
        {"schemaVersion":1,"id":"project:demo","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":300}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v","kind":"video","clips":[
          {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":90,"sourceInFrame":0,"effects":[],
           "parameterTracks":[{"schemaVersion":1,"id":"t","parameterId":"opacity","valueType":"\(valueType)",
             "frameRate":{"numerator":30,"denominator":1},"keyframes":\(keyframes)}]}]}]}}
        """
        do { _ = try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: e); XCTFail("expected rejection"); return [] }
        catch let err as NativeProjectDocumentValidationError { return err.issues }
    }
    /// The real engine's own error for a track it is handed directly.
    func engineMessage(_ track: KeyframeTrack) -> KeyframeEngineError? {
        do { try e.validate(track); return nil } catch { return error as? KeyframeEngineError }
    }

    func testUnknownValueTypeUsesBindingText() throws {
        let found = try issues(valueType: "colour", keyframes: #"[{"id":"k","frame":0,"value":1,"outgoing":{"type":"linear"}}]"#)
        // vkf_node.cpp parseValueType: raise("invalid-value", "Unknown track valueType \"" + s + "\"")
        XCTAssertEqual(found.map(\.message), [#"Parameter track t: Unknown track valueType "colour""#])
        XCTAssertEqual(found.map(\.path), ["sequence.tracks[0].clips[0].parameterTracks[0]"])
    }

    func testMalformedFrameUsesEngineMessage() throws {
        let found = try issues(valueType: "number", keyframes: #"[{"id":"k","frame":1.5,"value":1,"outgoing":{"type":"linear"}}]"#)
        let engine = try XCTUnwrap(engineMessage(KeyframeTrack(valueType: .number, keyframes: [.init(frame: 1.5, value: .number(1), outgoing: .linear)])))
        XCTAssertEqual(engine.code, "invalid-keyframe-frame")
        XCTAssertEqual(found.map(\.message), ["Parameter track t: \(engine.message)"])
        XCTAssertEqual(engine.message, "Keyframe frame must be an integer project frame") // same text as vkf_node.cpp parseKey
    }

    func testMalformedValueUsesEngineMessage() throws {
        let found = try issues(valueType: "number", keyframes: #"[{"id":"k","frame":0,"value":"high","outgoing":{"type":"linear"}}]"#)
        // The binding reads a non-number as NaN (numberOrNaN); the core rejects it with its own message.
        let engine = try XCTUnwrap(engineMessage(KeyframeTrack(valueType: .number, keyframes: [.init(frame: 0, value: .number(.nan), outgoing: .linear)])))
        XCTAssertEqual(engine.code, "invalid-value")
        XCTAssertFalse(engine.message.isEmpty)
        XCTAssertEqual(found.map(\.message), ["Parameter track t: \(engine.message)"])
    }

    func testMalformedInterpolationUsesBindingAndEngineText() throws {
        // Unknown type string: checked in the binding before the core (vkf_node.cpp parseKey).
        XCTAssertEqual(try issues(valueType: "number", keyframes: #"[{"id":"k","frame":0,"value":1,"outgoing":{"type":"spline"}}]"#).map(\.message),
                       [#"Parameter track t: Unknown interpolation "spline""#])
        // Non-numeric control point: read as NaN and rejected by the core with its own message.
        let found = try issues(valueType: "number", keyframes: #"[{"id":"k","frame":0,"value":1,"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":"a","y1":0,"x2":1,"y2":1}}},{"id":"k2","frame":10,"value":2,"outgoing":{"type":"linear"}}]"#)
        let engine = try XCTUnwrap(engineMessage(KeyframeTrack(valueType: .number, keyframes: [
            .init(frame: 0, value: .number(1), outgoing: .cubicBezier(CubicBezierControlPoints(x1: .nan, y1: 0, x2: 1, y2: 1))),
            .init(frame: 10, value: .number(2), outgoing: .linear)])))
        XCTAssertEqual(engine.code, "invalid-interpolation")
        XCTAssertEqual(found.map(\.message), ["Parameter track t: \(engine.message)"])
    }
}
