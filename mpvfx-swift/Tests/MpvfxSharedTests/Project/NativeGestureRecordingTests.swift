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
// Gesture recording. Cases that evaluate tracks run against KeyframeRuntime in
// MpvfxSharedEngineTests (EngineGestureRecordingTests). The velocity-fitter case ("applies the real velocity
// fitter's incoming ease ...") is not covered here: the velocity fitter belongs to the stage's gesture commit
// (see docs/IMPLEMENTATION_NOTES.md).
import XCTest
@testable import MpvfxShared

let gestureProjectJSON = #"{"schemaVersion":1,"id":"project","revision":0,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":100,"height":100,"background":"\#u{23}000000"},"assets":[{"id":"asset","kind":"image","name":"card","durationFrames":300}],"sequence":{"id":"sequence","name":"Main","tracks":[{"id":"track","kind":"video","clips":[{"id":"clip","assetId":"asset","startFrame":30,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}"#
let gestureRequest = NativeGestureRecordingRequest(selectedElement: .init(attributes: ["data-studio-clip-id": "clip"]), playheadSeconds: 2,
                                                   selectionBounds: .init(width: 100, height: 100))
let gestureKeys: [NativeRecordedKeyframe] = [
    .init(percentage: 0, properties: ["x": .number(0), "y": .number(10), "opacity": .number(1)]),
    .init(percentage: 50, properties: ["x": .number(50), "y": .number(20), "opacity": .number(0.5)]),
    .init(percentage: 100, properties: ["x": .number(100), "y": .number(30), "opacity": .number(0)])]
func gestureTracks(_ d: NativeProjectDocument) -> [NativeParameterTrack] { d.sequence.tracks[0].clips[0].parameterTracks }

final class NativeGestureRecordingTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func project() throws -> NativeProjectDocument { try parseNativeProjectDocument(J(gestureProjectJSON), engine: engine) }

    func testEaseParserMatchesTheRecordedFormat() throws {
        XCTAssertEqual(try nativeRecordedInterpolation(nil), .linear)
        XCTAssertEqual(try nativeRecordedInterpolation("none"), .linear)
        XCTAssertEqual(try nativeRecordedInterpolation(""), .linear)
        XCTAssertEqual(try nativeRecordedInterpolation("custom(M0,0 C0.333,0 0.667,0.667 1,1)"),
                       .cubicBezier(.init(x1: 0.333, y1: 0, x2: 0.667, y2: 0.667)))
        XCTAssertThrowsError(try nativeRecordedInterpolation("power2.out"))
        XCTAssertThrowsError(try nativeRecordedInterpolation("custom(M0,0 C0.3,0 0.6,1 1,1) "))
    }
    func testReplacesKeysWithinRecordingOnly() throws {
        var before = try project()
        func track(_ pid: String) throws -> NativeParameterTrack {
            try createNativeParameterTrack(.init(id: pid, parameterId: pid, valueType: .number, frameRate: .init(numerator: 30, denominator: 1),
                keyframes: [0.0, 40, 90].map { .init(id: jsNumberString($0), frame: $0, value: .number($0), outgoing: .linear) }), engine: engine)
        }
        before.sequence.tracks[0].clips[0].parameterTracks += [try track("transform.position.x"), try track("transform.rotation")]
        let after = try applyNativeGestureRecording(before, gestureRequest, duration: 1, keys: gestureKeys, engine: engine)
        XCTAssertEqual(gestureTracks(after).first { $0.parameterId == "transform.position.x" }!.keyframes.map(\.frame), [0, 30, 45, 60, 90])
        XCTAssertEqual(gestureTracks(after).first { $0.parameterId == "transform.rotation" }, gestureTracks(before)[1])
    }
    func testLastSampleWinsOnSameFrame() throws {
        let after = try applyNativeGestureRecording(try project(), gestureRequest, duration: 1, keys: [
            .init(percentage: 0, properties: ["x": .number(0)], ease: "custom(M0,0 C0.333,0 0.667,1 1,1)"),
            .init(percentage: 0.1, properties: ["x": .number(20)]), .init(percentage: 100, properties: ["x": .number(100)])], engine: engine)
        let k = gestureTracks(after)[0].keyframes[0]
        XCTAssertEqual(k.frame, 30); XCTAssertEqual(k.value, .number(20)); XCTAssertEqual(k.outgoing, .linear)
    }
    func testRejectsUnsupportedPropertiesWithoutChangingInput() throws {
        let before = try project()
        XCTAssertThrowsError(try applyNativeGestureRecording(before, gestureRequest, duration: 1,
                             keys: [gestureKeys[0], .init(percentage: 100, properties: ["color": .string("red")])], engine: engine)) {
            XCTAssertTrue(($0 as! NativeGestureRecordingError).message.contains("not supported"), "\($0)")
        }
        XCTAssertEqual(gestureTracks(before).count, 0)
    }
}
