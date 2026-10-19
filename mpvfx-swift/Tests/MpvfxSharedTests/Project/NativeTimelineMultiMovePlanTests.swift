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
// Multi-clip move plans.
import XCTest
@testable import MpvfxShared

final class NativeTimelineMultiMovePlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J(##"""
        {"schemaVersion":1,"id":"project:multi-move","revision":4,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#111111"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900},{"id":"asset:b","kind":"video","name":"b.mov","durationFrames":900},{"id":"asset:audio","kind":"audio","name":"voice.wav","durationFrames":900}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"opaque-video-source","kind":"video","lane":{"authoredTrack":7,"displayTrack":0},"clips":[
           {"id":"clip:a","assetId":"asset:a","binding":{"sourceFile":"a.html","domId":"dom-a","hfId":"hf-a"},"startFrame":30,"durationFrames":120,"sourceInFrame":12,
            "playbackRate":{"numerator":2,"denominator":1},"muted":true,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:a","effectId":"blur","enabled":true}],
            "parameterTracks":[{"schemaVersion":1,"id":"parameter:a","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},
             "keyframes":[{"id":"key:a0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:a1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]},
           {"id":"clip:b","assetId":"asset:b","binding":{"sourceFile":"b.html","selector":".clip-b","selectorIndex":0},"startFrame":180,"durationFrames":90,"sourceInFrame":20,
            "playbackRate":{"numerator":1,"denominator":2},"muted":false,"staticParameters":{"transform.position.x":40},"effects":[{"id":"fx:b","effectId":"grade","enabled":false}],"parameterTracks":[]}]},
          {"id":"opaque-video-destination","kind":"video","lane":{"authoredTrack":19,"displayTrack":1},"clips":[]},
          {"id":"opaque-audio-destination","kind":"audio","lane":{"authoredTrack":23,"displayTrack":2},"clips":[]}]}}
        """##), engine: engine)
    }
    let elementA = NativeSelectedElementReference(id: "dom-a", hfId: "hf-a", sourceFile: "a.html")
    let elementB = NativeSelectedElementReference(sourceFile: "b.html", selector: ".clip-b", selectorIndex: 0)
    func plan(_ d: NativeProjectDocument, _ c: [NativeTimelineMultiMoveChange]) throws -> NativeTimelineMultiMovePlanResult { try planNativeTimelineMultiMove(d, changes: c, engine: engine) }

    func testMovesEveryBindingInOneCommand() throws {
        let original = try document()
        let r = try plan(original, [.init(element: elementA, requestedStartSeconds: (75.99 * 1001) / 30000),
                                    .init(element: elementB, requestedStartSeconds: (240.4 * 1001) / 30000, destinationAuthoredTrack: 19)]).value!
        XCTAssertEqual(r.moves.map(\.address), [.init(sequenceId: "sequence:main", trackId: "opaque-video-source", clipId: "clip:a"),
                                                .init(sequenceId: "sequence:main", trackId: "opaque-video-source", clipId: "clip:b")])
        XCTAssertEqual(r.moves.map(\.sourceFile), ["a.html", "b.html"]); XCTAssertEqual(r.moves.map(\.startFrame), [75, 240])
        XCTAssertEqual(r.moves.map(\.compatibilityStartSeconds), [(75.0 * 1001) / 30000, (240.0 * 1001) / 30000])
        XCTAssertEqual(r.moves.map(\.destination), [.init(trackId: "opaque-video-source", authoredTrack: 7, displayTrack: 0),
                                                    .init(trackId: "opaque-video-destination", authoredTrack: 19, displayTrack: 1)])
        XCTAssertEqual(r.sourceFiles, ["a.html", "b.html"])
        let a = r.document.sequence.tracks[0].clips.first { $0.id == "clip:a" }!, b = r.document.sequence.tracks[1].clips.first { $0.id == "clip:b" }!
        XCTAssertEqual([a.startFrame, a.sourceInFrame], [75, 12]); XCTAssertEqual(a.playbackRate, .init(numerator: 2, denominator: 1)); XCTAssertTrue(a.muted)
        XCTAssertEqual(a.staticParameters, ["opacity": .number(0.75)]); XCTAssertEqual(a.effects.map(\.id), ["fx:a"]); XCTAssertEqual(a.parameterTracks[0].keyframes.count, 2)
        XCTAssertEqual([b.startFrame, b.sourceInFrame], [240, 20]); XCTAssertEqual(b.playbackRate, .init(numerator: 1, denominator: 2)); XCTAssertFalse(b.muted)
        XCTAssertEqual(b.staticParameters, ["transform.position.x": .number(40)]); XCTAssertEqual(b.effects, [.init(id: "fx:b", effectId: "grade", enabled: false, parameters: nil)])
        XCTAssertEqual(original, try document())
    }

    func testRejectsDuplicateResolvedClips() throws {
        let original = try document()
        let r = try plan(original, [.init(element: elementA, requestedStartSeconds: 2),
                                    .init(element: .init(sourceFile: "a.html", attributes: ["data-studio-clip-id": "clip:a"]), requestedStartSeconds: 3)])
        XCTAssertEqual(r.error?.code, .duplicateClip); XCTAssertEqual(original, try document())
    }

    func testRejectsAmbiguousIdentity() throws {
        var d = try document(); var copy = d.sequence.tracks[0].clips[0]; copy.binding = nil; d.sequence.tracks[1].clips = [copy]
        XCTAssertEqual(try plan(d, [.init(element: .init(id: "clip:a", sourceFile: "a.html"), requestedStartSeconds: 2)]).error?.code, .ambiguousClip)
    }

    func testMovesNativeOnlyClip() throws {
        var d = try document(); d.sequence.tracks[0].clips[0].binding = nil
        let r = try plan(d, [.init(element: .init(attributes: ["data-studio-clip-id": "clip:a"]), requestedStartSeconds: 2)]).value!
        XCTAssertEqual(r.sourceFiles, []); XCTAssertNil(r.moves[0].sourceFile); XCTAssertNil(r.moves[0].binding); XCTAssertEqual(r.moves[0].startFrame, 59)
    }

    func testCreatesOneEmptyDestinationTrack() throws {
        let original = try document()
        let r = try plan(original, [elementA, elementB].enumerated().map { .init(element: $1, requestedStartSeconds: 2 + Double($0) * 6, destinationAuthoredTrack: 99) }).value!
        let dest = r.document.sequence.tracks.filter { $0.lane?.authoredTrack == 99 }
        XCTAssertEqual(dest.count, 1); XCTAssertEqual(dest[0].clips.count, 2); XCTAssertEqual(original, try document())
    }

    func testRejectsInvalidAuthoredLane() throws {
        let original = try document()
        XCTAssertEqual(try plan(original, [.init(element: elementA, requestedStartSeconds: 2, destinationAuthoredTrack: -1)]).error?.code, .unmappedLane)
        XCTAssertEqual(original, try document())
    }

    func testRejectsInvalidStarts() throws {
        for s in [Double.nan, .infinity, -0.01] {
            let original = try document()
            XCTAssertEqual(try plan(original, [.init(element: elementA, requestedStartSeconds: s)]).error?.code, .invalidStart)
            XCTAssertEqual(original.sequence.tracks[0].clips[0].startFrame, 30)
        }
    }

    func testRejectsEmptyGesture() throws { XCTAssertEqual(try plan(try document(), []).error?.code, .emptyChangeSet) }

    func testVisualMediaIntoAudioTrackKeepsRows() throws {
        let original = try document()
        let r = try plan(original, [.init(element: elementA, requestedStartSeconds: 2, destinationAuthoredTrack: 23)]).value!
        XCTAssertEqual(r.document.sequence.tracks.map(\.id), original.sequence.tracks.map(\.id))
        XCTAssertEqual(r.document.sequence.tracks.map(\.lane), original.sequence.tracks.map(\.lane))
        XCTAssertEqual(r.document.sequence.tracks.first { $0.lane?.authoredTrack == 23 }?.kind, .mixed)
    }
}
