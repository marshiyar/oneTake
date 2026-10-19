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
// Clip move plans.
import XCTest
@testable import MpvfxShared

final class NativeTimelineClipMovePlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J(#"""
        {"schemaVersion":1,"id":"project:move","revision":7,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#101010"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"opaque-source-track","kind":"video","lane":{"authoredTrack":7,"displayTrack":2},"clips":[
           {"id":"clip:a","assetId":"asset:a","binding":{"sourceFile":"index.html","domId":"clip","hfId":"hf-clip"},"startFrame":30,"durationFrames":120,"sourceInFrame":12,
            "muted":false,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:1","effectId":"blur","enabled":true}],
            "parameterTracks":[{"schemaVersion":1,"id":"param:rotation","parameterId":"rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},
             "keyframes":[{"id":"key:0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:1","frame":60,"value":180,"outgoing":{"type":"linear"}}]}]}]},
          {"id":"target-without-lane-in-id","kind":"video","lane":{"authoredTrack":19,"displayTrack":3},"clips":[]},
          {"id":"audio-target-without-lane-in-id","kind":"audio","lane":{"authoredTrack":23,"displayTrack":4},"clips":[]}]}}
        """#), engine: engine)
    }
    // The selection reference does not model a domId; it is ignored.
    let element = NativeTimelineMoveElement(reference: .init(id: "timeline-row", hfId: "hf-clip", sourceFile: "index.html", selector: "#clip", selectorIndex: 0), currentTrack: 2)
    func plan(_ d: NativeProjectDocument, _ s: Double, _ t: Double, element e: NativeTimelineMoveElement? = nil) throws -> NativeTimelineClipMovePlanResult {
        try planNativeTimelineClipMove(.init(document: d, element: e ?? element, requestedStartSeconds: s, requestedTrack: t), engine: engine)
    }

    func testIntegerFrameIsCanonical() throws {
        let r = try plan(try document(), (75.99 * 1001) / 30000, 2).value!
        XCTAssertEqual(r.address, .init(sequenceId: "sequence:main", trackId: "opaque-source-track", clipId: "clip:a"))
        XCTAssertEqual(r.destination, .init(trackId: "opaque-source-track", authoredTrack: 7, displayTrack: 2))
        XCTAssertEqual(r.startFrame, 75); XCTAssertEqual(r.compatibilityStartSeconds, (75.0 * 1001) / 30000)
        let moved = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(moved.startFrame, 75); XCTAssertEqual(moved.sourceInFrame, 12); XCTAssertFalse(moved.muted)
        XCTAssertEqual(moved.staticParameters, ["opacity": .number(0.75)])
        XCTAssertEqual(moved.effects, [.init(id: "fx:1", effectId: "blur", enabled: true, parameters: nil)])
        XCTAssertEqual(moved.parameterTracks[0].keyframes.map(\.frame), [0, 60])
    }

    func testMovesToMappedAuthoredLane() throws {
        let original = try document(); var before = original.sequence.tracks[0].clips[0]
        let r = try plan(original, 3, 19).value!
        XCTAssertEqual(r.destination, .init(trackId: "target-without-lane-in-id", authoredTrack: 19, displayTrack: 3))
        XCTAssertEqual(r.document.sequence.tracks[0].clips, [])
        before.startFrame = 89
        XCTAssertEqual(r.document.sequence.tracks[1].clips[0], before)
    }

    func testVisualClipIntoAudioRowBecomesMixed() throws {
        let r = try plan(try document(), 3, 23).value!
        let t = r.document.sequence.tracks.first { $0.id == "audio-target-without-lane-in-id" }!
        XCTAssertEqual(t.kind, .mixed); XCTAssertEqual(t.lane?.authoredTrack, 23)
    }

    func testRejectsUnmappedLanes() throws {
        for lane in [3.0, 9] {
            let original = try document()
            let r = try plan(original, 3, lane)
            XCTAssertEqual(r.error?.code, .unsupportedLaneChange); XCTAssertTrue(r.error!.message.contains("mapped compatible native track"))
            XCTAssertEqual(original, try document())
        }
    }

    func testRejectsInvalidTimes() throws {
        for s in [Double.nan, .infinity, -0.01] {
            let original = try document()
            XCTAssertEqual(try plan(original, s, 2).error?.code, .invalidStart)
            XCTAssertEqual(original.sequence.tracks[0].clips[0].startFrame, 30)
        }
    }

    func testRejectsUnboundElement() throws {
        var e = element; e.reference.hfId = "other"; e.reference.selector = "#other"
        XCTAssertEqual(try plan(try document(), 2, 2, element: e).error?.code, .clipNotFound)
    }
}
