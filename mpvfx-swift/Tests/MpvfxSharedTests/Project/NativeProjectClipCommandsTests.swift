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
// Clip commands. Cases that trim or split a clip with parameter tracks
// call the engine's slice and run against KeyframeRuntime in MpvfxSharedEngineTests (EngineProjectClipCommandsTests).
import XCTest
@testable import MpvfxShared

let clipCommandsFixtureJSON = """
{"schemaVersion":1,"id":"project:move","revision":4,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#111111"},
 "assets":[{"id":"asset:video","kind":"video","name":"video.mov","durationFrames":900},{"id":"asset:audio","kind":"audio","name":"audio.wav","durationFrames":900}],
 "sequence":{"id":"sequence:main","name":"Main","tracks":[
  {"id":"track:v1","kind":"video","lane":{"authoredTrack":7,"displayTrack":1},"clips":[
   {"id":"clip:first","assetId":"asset:video","startFrame":0,"durationFrames":120,"sourceInFrame":12,"muted":false,"staticParameters":{"transform.rotation":12},
    "effects":[{"id":"effect:grade","effectId":"grade","enabled":true,"parameters":{"lift":0.1}}],
    "parameterTracks":[{"schemaVersion":1,"id":"parameter:first:rotation","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30,"denominator":1},
      "keyframes":[{"id":"rotation:0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"rotation:90","frame":90,"value":-180,"outgoing":{"type":"linear"}}]}]},
   {"id":"clip:second","assetId":"asset:video","startFrame":120,"durationFrames":120,"sourceInFrame":132,"muted":true,"effects":[],"parameterTracks":[]}]},
  {"id":"track:v2","kind":"video","lane":{"authoredTrack":19,"displayTrack":3},"clips":[]},
  {"id":"track:a1","kind":"audio","lane":{"authoredTrack":4,"displayTrack":5},"clips":[
   {"id":"clip:audio","assetId":"asset:audio","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
"""
let firstClipAddress = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:first")
func clipAddress(_ id: String) -> NativeProjectClipAddress { var a = firstClipAddress; a.clipId = id; return a }
func findClip(_ d: NativeProjectDocument, _ id: String) -> NativeProjectClip? { d.sequence.tracks.flatMap(\.clips).first { $0.id == id } }
func mutateClip(_ d: inout NativeProjectDocument, _ id: String, _ f: (inout NativeProjectClip) -> Void) {
    for t in d.sequence.tracks.indices { for c in d.sequence.tracks[t].clips.indices where d.sequence.tracks[t].clips[c].id == id { f(&d.sequence.tracks[t].clips[c]) } }
}

final class NativeProjectClipCommandsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func fixture() -> NativeProjectDocument { try! parseNativeProjectDocument(J(clipCommandsFixtureJSON), engine: engine) }
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectClipCommand) -> NativeProjectClipCommandResult { try! applyNativeProjectClipCommand(d, c, engine: engine) }
    func expectOk(_ d: NativeProjectDocument, _ c: NativeProjectClipCommand, file: StaticString = #filePath, line: UInt = #line) -> NativeProjectClipCommandResult {
        let r = apply(d, c); XCTAssertTrue(r.ok, "\(String(describing: r.failure))", file: file, line: line); return r
    }
    func serialize(_ d: NativeProjectDocument) -> String { try! serializeNativeProjectDocument(d, engine: engine) }
    func assertRejected(_ r: NativeProjectClipCommandResult, _ original: NativeProjectDocument, _ code: NativeProjectClipFailureCode,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.ok, file: file, line: line); XCTAssertEqual(r.document, original, file: file, line: line)
        XCTAssertEqual(r.failure?.code, code, file: file, line: line)
    }
    func track(_ d: NativeProjectDocument, _ id: String) -> NativeProjectTrack { d.sequence.tracks.first { $0.id == id }! }

    func testMovesOneClipPreservingLocalState() {
        let original = fixture()
        let before = findClip(original, "clip:first")!
        let r = expectOk(original, .move(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: 240)))
        let moved = findClip(r.document, "clip:first")!
        XCTAssertEqual(track(r.document, "track:v1").clips.count, 1)
        XCTAssertTrue(track(r.document, "track:v2").clips.contains(moved))
        XCTAssertEqual(track(r.document, "track:v2").lane, .init(authoredTrack: 19, displayTrack: 3))
        var a = moved, b = before; a.startFrame = 0; b.startFrame = 0
        XCTAssertEqual(a, b)
        XCTAssertEqual(moved.startFrame, 240); XCTAssertEqual(r.document.revision, original.revision)
        let undo = apply(r.document, r.inverse!)
        XCTAssertTrue(undo.ok); XCTAssertEqual(serialize(undo.document), serialize(original))
    }

    func testMultiClipMoveInDeterministicOrder() {
        var original = fixture()
        mutateClip(&original, "clip:first") { $0.binding = .init(sourceFile: "index.html", domId: "clip-first", hfId: "hf-clip-first", selector: "#clip-first", selectorIndex: 0) }
        let r = expectOk(original, .moveMany([.init(address: clipAddress("clip:second"), destination: .init(trackId: "track:v2", startFrame: 120)),
                                              .init(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: 240))]))
        XCTAssertEqual(track(r.document, "track:v2").clips.map { "\($0.id)@\(jsNumberString($0.startFrame))" }, ["clip:second@120", "clip:first@240"])
        XCTAssertEqual(track(r.document, "track:v1").clips, [])
        XCTAssertEqual(findClip(r.document, "clip:first")?.binding, findClip(original, "clip:first")?.binding)
        XCTAssertEqual(findClip(r.document, "clip:first")?.effects, findClip(original, "clip:first")?.effects)
        XCTAssertEqual(findClip(r.document, "clip:first")?.parameterTracks, findClip(original, "clip:first")?.parameterTracks)
    }

    func testRejectsBadMovesWithoutPartialDocument() {
        var seqMissing = firstClipAddress; seqMissing.sequenceId = "sequence:missing"
        var trackMissing = firstClipAddress; trackMissing.trackId = "track:missing"
        let cases: [(NativeProjectClipCommand, NativeProjectClipFailureCode)] = [
            (.move(address: seqMissing, destination: .init(trackId: "track:v2", startFrame: 1)), .missingSequence),
            (.move(address: firstClipAddress, destination: .init(trackId: "track:missing", startFrame: 1)), .missingDestinationTrack),
            (.move(address: trackMissing, destination: .init(trackId: "track:v2", startFrame: 1)), .missingSourceTrack),
            (.move(address: clipAddress("clip:missing"), destination: .init(trackId: "track:v2", startFrame: 1)), .missingClip),
            (.move(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: 1.5)), .invalidStartFrame),
            (.move(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: -1)), .invalidStartFrame)]
        for (c, code) in cases {
            let original = fixture(); assertRejected(apply(original, c), original, code)
            XCTAssertEqual(serialize(original), serialize(fixture()))
        }
    }

    func testRejectsDuplicateTargetsButAllowsSharedDestinationTime() {
        let original = fixture()
        assertRejected(apply(original, .moveMany([.init(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: 30)),
                                                  .init(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: 60))])), original, .duplicateTarget)
        let collision = apply(original, .moveMany([.init(address: firstClipAddress, destination: .init(trackId: "track:v2", startFrame: 30)),
                                                   .init(address: clipAddress("clip:second"), destination: .init(trackId: "track:v2", startFrame: 30))]))
        XCTAssertTrue(collision.ok)
        XCTAssertEqual(track(collision.document, "track:v2").clips.filter { $0.startFrame == 30 }.count, 2)
        XCTAssertEqual(serialize(original), serialize(fixture()))
    }

    func testRequiresExplicitRightBindingForBoundSplit() {
        var original = fixture()
        mutateClip(&original, "clip:first") { $0.binding = .init(sourceFile: "index.html", domId: "clip-first-left") }
        assertRejected(apply(original, .split(address: firstClipAddress, splitFrame: 60)), original, .missingSplitBinding)
    }

    func testDeletesSeveralClipsAtomically() {
        let r = expectOk(fixture(), .deleteMany([firstClipAddress, clipAddress("clip:second")]))
        XCTAssertEqual(track(r.document, "track:v1").clips, [])
        XCTAssertNotNil(findClip(r.document, "clip:audio"))
    }

    func testRejectsInvalidTrimSplitDelete() {
        let cases: [(NativeProjectClipCommand, NativeProjectClipFailureCode)] = [
            (.trimIn(address: firstClipAddress, startFrame: -1), .invalidTrim), (.trimOut(address: firstClipAddress, endFrameExclusive: 0), .invalidTrim),
            (.split(address: firstClipAddress, splitFrame: 120), .invalidSplit), (.deleteMany([firstClipAddress, firstClipAddress]), .duplicateTarget)]
        for (c, code) in cases { let o = fixture(); assertRejected(apply(o, c), o, code) }
    }

    func testRejectsGeneratedIdCollision() {
        var collision = fixture()
        let id = nativeSplitClipId("clip:first", splitFrame: 60)
        let i = collision.sequence.tracks.firstIndex { $0.id == "track:v2" }!
        collision.sequence.tracks[i].clips.append(try! J(#"{"id":"\#(id)","assetId":"asset:video","startFrame":500,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}"#).decode(NativeProjectClip.self))
        collision = try! parseNativeProjectDocument(collision, engine: engine)
        assertRejected(apply(collision, .split(address: firstClipAddress, splitFrame: 60)), collision, .generatedIdCollision)
    }

    func testExtendsTrimOutWithoutRetimingKeys() {
        let original = fixture()
        let r = expectOk(original, .trimOut(address: firstClipAddress, endFrameExclusive: 180))
        XCTAssertEqual(findClip(r.document, "clip:first")!.durationFrames, 180)
        XCTAssertEqual(findClip(r.document, "clip:first")!.parameterTracks, findClip(original, "clip:first")!.parameterTracks)
    }

    func testExtendsStillImageBeyondInitialDuration() {
        var original = fixture(); original.assets[0].kind = .image
        XCTAssertEqual(findClip(expectOk(original, .trimOut(address: firstClipAddress, endFrameExclusive: 1200)).document, "clip:first")!.durationFrames, 1200)
    }

    func testRejectsExtendingPastSource() {
        let r = apply(fixture(), .trimOut(address: firstClipAddress, endFrameExclusive: 1000))
        XCTAssertFalse(r.ok); XCTAssertEqual(r.failure?.code, .invalidTrim); XCTAssertTrue(r.failure!.message.contains("source"))
    }

    /// Overflow mapping (Swift-only): an Int64 overflow in sourceRangeFits is rejected like an out-of-range source end.
    func testTrimOutOverflowIsInvalidTrim() {
        var d = fixture()
        mutateClip(&d, "clip:first") { $0.playbackRate = .init(numerator: 1, denominator: jsMaxSafeInteger); $0.sourceInFraction = .init(numerator: 1, denominator: jsMaxSafeInteger) }
        // Not re-validated: validation itself rejects this range (see the document overflow test).
        let r = apply(d, .trimOut(address: firstClipAddress, endFrameExclusive: 180))
        assertRejected(r, d, .invalidTrim)
        XCTAssertEqual(r.failure?.message, "Cannot extend beyond the end of the source media")
    }

    /// Overflow mapping: advanceSourcePosition overflow during trim-in/split is a rejection, like other range errors.
    func testTrimInAndSplitOverflowAreRejections() {
        var d = fixture()
        mutateClip(&d, "clip:second") { $0.playbackRate = .init(numerator: jsMaxSafeInteger, denominator: 1) }
        let tooBig = try? parseNativeProjectDocument(d, engine: engine)
        // A rate this large overruns the asset at validation; check the command path directly on the unvalidated value instead.
        XCTAssertNil(tooBig)
        let r = apply(d, .trimIn(address: clipAddress("clip:second"), startFrame: 121))
        assertRejected(r, d, .invalidTrim)
        let s = apply(d, .split(address: clipAddress("clip:second"), splitFrame: 121))
        assertRejected(s, d, .invalidSplit)
    }
}
