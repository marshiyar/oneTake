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
// Clip delete plans.
import XCTest
@testable import MpvfxShared

final class NativeTimelineDeletePlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J(#"""
        {"schemaVersion":1,"id":"project:delete","revision":12,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":3840,"height":2160,"background":"#101010"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":1000},{"id":"asset:b","kind":"video","name":"b.mov","durationFrames":1000},{"id":"asset:c","kind":"audio","name":"c.wav","durationFrames":1000}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"video-track","kind":"video","lane":{"authoredTrack":7,"displayTrack":0},"clips":[
           {"id":"clip:a","assetId":"asset:a","binding":{"sourceFile":"z.html","domId":"dom-a","hfId":"hf-a"},"startFrame":30,"durationFrames":120,"sourceInFrame":14,
            "playbackRate":{"numerator":2,"denominator":1},"muted":true,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:a","effectId":"grade","enabled":true,"parameters":{"mix":0.4}}],
            "parameterTracks":[{"schemaVersion":1,"id":"parameter:a","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},
             "keyframes":[{"id":"key:a0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:a1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]},
           {"id":"clip:b","assetId":"asset:b","binding":{"sourceFile":"z.html","selector":".clip-b","selectorIndex":1},"startFrame":200,"durationFrames":90,"sourceInFrame":20,
            "playbackRate":{"numerator":1,"denominator":2},"muted":false,"staticParameters":{"transform.position.x":44},"effects":[{"id":"fx:b","effectId":"blur","enabled":false}],"parameterTracks":[]}]},
          {"id":"audio-track","kind":"audio","lane":{"authoredTrack":12,"displayTrack":1},"clips":[
           {"id":"clip:c","assetId":"asset:c","binding":{"sourceFile":"a.html","domId":"dom-c"},"startFrame":10,"durationFrames":80,"sourceInFrame":4,
            "playbackRate":{"numerator":1,"denominator":1},"muted":false,"staticParameters":{"audio.volume":0.8},"effects":[{"id":"fx:c","effectId":"compressor","enabled":true}],"parameterTracks":[]}]}]}}
        """#), engine: engine)
    }
    let targetA = NativeTimelineDeleteTarget(.init(id: "dom-a", hfId: "hf-a", sourceFile: "z.html"))
    let targetB = NativeTimelineDeleteTarget(.init(sourceFile: "z.html", selector: ".clip-b", selectorIndex: 1))
    let targetC = NativeTimelineDeleteTarget(.init(id: "dom-c", sourceFile: "a.html"))
    func plan(_ d: NativeProjectDocument, _ t: [NativeTimelineDeleteTarget]) throws -> NativeTimelineDeletePlanResult { try planNativeTimelineDelete(d, targets: t, engine: engine) }

    func testDeletesAcrossTracksPreservingState() throws {
        let original = try project(); let untouched = original.sequence.tracks[0].clips[1]
        let r = try plan(original, [targetA, targetC]).value!
        XCTAssertEqual(r.sourceFiles, ["a.html", "z.html"])
        XCTAssertEqual(r.deletions, [
            .init(address: .init(sequenceId: "sequence:main", trackId: "video-track", clipId: "clip:a"), sourceFile: "z.html", binding: .init(sourceFile: "z.html", domId: "dom-a", hfId: "hf-a")),
            .init(address: .init(sequenceId: "sequence:main", trackId: "audio-track", clipId: "clip:c"), sourceFile: "a.html", binding: .init(sourceFile: "a.html", domId: "dom-c"))])
        XCTAssertEqual(r.document.sequence.tracks[0].clips, [untouched]); XCTAssertEqual(r.document.sequence.tracks[1].clips, [])
        XCTAssertEqual(r.document.assets, original.assets); XCTAssertEqual(r.document.canvas, original.canvas); XCTAssertEqual(r.document.revision, 12)
        XCTAssertEqual(original, try project())
    }

    func testCollectsOneSortedSource() throws {
        let r = try plan(try project(), [targetB, targetA]).value!
        XCTAssertEqual(r.sourceFiles, ["z.html"]); XCTAssertEqual(r.deletions.map(\.address.clipId), ["clip:b", "clip:a"])
    }

    func testRejectsDuplicateResolutions() throws {
        let original = try project()
        let r = try plan(original, [targetA, .init(.init(sourceFile: "z.html", attributes: ["data-studio-clip-id": "clip:a"]))])
        XCTAssertEqual(r.error?.code, .duplicateClip); XCTAssertEqual(r.error?.targetIndex, 1); XCTAssertEqual(original, try project())
    }

    func testRejectsAmbiguousIdentity() throws {
        var d = try project(); var copy = d.sequence.tracks[0].clips[0]; copy.binding = nil
        d.sequence.tracks[1].clips = [copy]
        XCTAssertEqual(try plan(d, [.init(.init(id: "clip:a", sourceFile: "z.html"))]).error?.code, .ambiguousClip)
    }

    func testDeletesBoundAndNativeOnlyTogether() throws {
        var unbound = try project(); unbound.sequence.tracks[0].clips[1].binding = nil
        let before = unbound
        let r = try plan(unbound, [targetA, .init(.init(attributes: ["data-studio-clip-id": "clip:b"]))]).value!
        XCTAssertEqual(r.sourceFiles, ["z.html"]); XCTAssertEqual(r.document.sequence.tracks[0].clips, [])
        XCTAssertEqual(r.document.sequence.tracks[1], unbound.sequence.tracks[1]); XCTAssertEqual(unbound, before)
    }

    func testRejectsRootLikeTargets() throws {
        for t in [NativeTimelineDeleteTarget(.init(id: "root", sourceFile: "z.html"), structuralRole: "composition-root"),
                  .init(.init(sourceFile: "z.html", selector: #"[data-composition-id="main"]"#)),
                  .init(.init(id: "root", sourceFile: "z.html", attributes: ["data-composition-id": "main"]))] {
            XCTAssertEqual(try plan(try project(), [t]).error?.code, .protectedRoot)
        }
    }

    func testRejectsDisagreeingSource() throws {
        // Exact selection resolution rejects the wrong source before planning a delete.
        XCTAssertEqual(try plan(try project(), [.init(.init(sourceFile: "wrong.html", attributes: ["data-studio-clip-id": "clip:a"]))]).error?.code, .clipNotFound)
    }

    func testRejectsEmptyTargetSet() throws { XCTAssertEqual(try plan(try project(), []).error?.code, .emptyTargetSet) }
}
