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
// Property commands. The two successful collapse cases evaluate the track
// and run against KeyframeRuntime in MpvfxSharedEngineTests (EngineProjectPropertyCommandsTests).
import XCTest
@testable import MpvfxShared

let propertyProjectJSON = """
{"schemaVersion":1,"id":"project:property-commands","revision":0,"frameRate":{"numerator":30,"denominator":1},
 "canvas":{"width":1920,"height":1080,"background":"#000000"},
 "assets":[{"id":"asset:video","kind":"video","name":"clip.mov","durationFrames":120}],
 "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","clips":[
  {"id":"clip:one","assetId":"asset:video","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"staticParameters":{},"effects":[],
   "parameterTracks":[{"schemaVersion":1,"id":"parameter:rotation","parameterId":"transform.rotation","valueType":"number",
     "frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"key:0","frame":0,"value":0,"outgoing":{"type":"linear"}},
     {"id":"key:60","frame":60,"value":-180,"outgoing":{"type":"hold"}}]}]}]}]}}
"""
func propertyAddress(_ p: String = "transform.rotation") -> NativeProjectParameterAddress {
    .init(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:one", parameterId: p)
}

final class NativeProjectPropertyCommandsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func project() -> NativeProjectDocument { try! parseNativeProjectDocument(J(propertyProjectJSON), engine: engine) }
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectPropertyCommand) -> NativeProjectPropertyCommandResult {
        try! applyNativeProjectPropertyCommand(d, c, engine: engine)
    }
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectAtomicPropertyCommand) -> NativeProjectPropertyCommandResult { apply(d, .atomic(c)) }
    func assertRejected(_ r: NativeProjectPropertyCommandResult, _ before: NativeProjectDocument, _ code: NativeProjectKeyframeFailureCode,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.ok, file: file, line: line); XCTAssertEqual(r.document, before, file: file, line: line)
        XCTAssertEqual(r.failure?.code, code, file: file, line: line)
    }

    func testSetsStaticWithoutTouchingTracks() {
        let before = project()
        let r = apply(before, .setStatic(address: propertyAddress("visual.opacity"), value: .number(0.5)))
        XCTAssertTrue(r.ok)
        let clip = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.staticParameters, ["visual.opacity": .number(0.5)])
        XCTAssertEqual(clip.parameterTracks, before.sequence.tracks[0].clips[0].parameterTracks)
        XCTAssertEqual(before.sequence.tracks[0].clips[0].staticParameters, [:])
    }
    func testOffsetsNumericKeys() {
        let r = apply(project(), .offsetTrack(address: propertyAddress(), delta: -30))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.document.sequence.tracks[0].clips[0].parameterTracks[0].keyframes,
                       [.init(id: "key:0", frame: 0, value: .number(-30), outgoing: .linear), .init(id: "key:60", frame: 60, value: .number(-210), outgoing: .hold)])
    }
    func testRollsBackMixedBatch() {
        let before = project()
        assertRejected(apply(before, .batch([.setStatic(address: propertyAddress("visual.opacity"), value: .number(0.5)),
                                             .offsetTrack(address: propertyAddress("missing.parameter"), delta: 10)])), before, .missingParameter)
    }
    func testDelegatesKeyframeMutations() {
        let r = apply(project(), .batch([.keyframe(.updateValue(address: propertyAddress(), frame: 60, value: .number(-90))),
                                         .setStatic(address: propertyAddress("visual.opacity"), value: .number(0.75))]))
        XCTAssertTrue(r.ok)
        let clip = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.parameterTracks[0].keyframes[1].value, .number(-90))
        XCTAssertEqual(clip.staticParameters, ["visual.opacity": .number(0.75)])
    }
    func testRejectsNonFiniteOffset() {
        for delta in [Double.nan, .infinity] { let b = project(); assertRejected(apply(b, .offsetTrack(address: propertyAddress(), delta: delta)), b, .invalidValue) }
    }
    func testRejectsCollapseFrameOutOfRange() {
        for f in [-1.0, 120, 1.5] { let b = project(); assertRejected(apply(b, .collapseTrack(address: propertyAddress(), frame: f)), b, .invalidFrame) }
    }
    func testRejectsWrongAddress() {
        let b = project(); assertRejected(apply(b, .collapseTrack(address: propertyAddress("transform.missing"), frame: 30)), b, .missingParameter)
    }
    /// A non-finite static value is rejected by re-validation (parseNativeProjectDocument).
    func testRejectsNonFiniteStaticValue() {
        let b = project()
        let r = apply(b, .setStatic(address: propertyAddress("visual.opacity"), value: .number(.nan)))
        assertRejected(r, b, .invalidValue)
        XCTAssertTrue(r.failure!.message.contains("Static number must be finite"), r.failure!.message)
    }
}
