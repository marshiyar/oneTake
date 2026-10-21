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
@testable import MpvfxShared

/// `planNativeTimelineHold`: insert and overwrite holds on one track, their edges and their refusals.
final class NativeTimelineHoldPlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    /// 30 fps; a 240-frame video clip at 0 (source from 0) and a second clip right after it on the same track.
    func document(locked: Bool = false) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J("""
        {"schemaVersion":1,"mediaEngine":"native","id":"hold","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"cam","kind":"video","name":"cam","source":"cam.mov","durationFrames":300},
                   {"id":"pic","kind":"image","name":"pic","source":"pic.png","durationFrames":1}],
         "sequence":{"id":"seq","name":"Main","tracks":[{"id":"v1","kind":"video","locked":\(locked),"clips":[
           {"id":"a","assetId":"cam","startFrame":0,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[],
            "crop":{"top":2,"right":0,"bottom":0,"left":3},"staticParameters":{"transform.rotation":12}},
           {"id":"b","assetId":"cam","startFrame":240,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]},
           {"id":"p","assetId":"pic","startFrame":300,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """), engine: engine)
    }

    func plan(_ d: NativeProjectDocument, clip: String = "a", at frame: Double, length: Double = 60,
              _ mode: NativeTimelineHoldMode = .insert) throws -> NativeTimelineHoldPlanResult {
        try planNativeTimelineHold(d, .init(address: .init(sequenceId: "seq", trackId: "v1", clipId: clip), frame: frame,
                                            lengthFrames: length, mode: mode), engine: engine)
    }

    func clips(_ r: NativeTimelineHoldPlanResult) throws -> [NativeProjectClip] {
        try r.get().document.sequence.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
    }

    /// (start, duration, source in, held frame) per clip, in timeline order.
    func spans(_ c: [NativeProjectClip]) -> [[Double?]] { c.map { [$0.startFrame, $0.durationFrames, $0.sourceInFrame, $0.holdSourceFrame?.sourceFrame] } }

    func testA1InsertHoldsFrame120For60FramesAndTheRestStartsWithFrame121() throws {
        let r = try plan(try document(), at: 120)
        XCTAssertEqual(spans(try clips(r)), [[0, 120, 0, nil], [120, 60, 120, 120], [180, 119, 121, nil], [299, 30, 0, nil], [359, 30, 0, nil]])
        let hold = try XCTUnwrap(try clips(r).first { $0.id == (try r.get().holdClipId) })
        XCTAssertEqual(hold.crop, NativeClipCrop(top: 2, left: 3), "the hold keeps the clip's crop")
        XCTAssertEqual(hold.staticParameters?["transform.rotation"], .number(12), "and its transform")
        XCTAssertEqual(hold.playbackRate, NativePlaybackRate(numerator: 1, denominator: 1))
    }

    func testA2OverwriteKeepsTheSequenceLength() throws {
        let d = try document()
        let end = { (c: [NativeProjectClip]) in c.map { $0.startFrame + $0.durationFrames }.max() }
        let r = try plan(d, at: 120, .overwrite)
        XCTAssertEqual(end(try clips(r)), end(d.sequence.tracks[0].clips))
        XCTAssertEqual(spans(try clips(r)), [[0, 120, 0, nil], [120, 60, 120, 120], [180, 60, 180, nil], [240, 30, 0, nil], [300, 30, 0, nil]])
    }

    func testOverwritePastTheClipTrimsAndRemovesWhatTheHoldCovers() throws {
        let r = try plan(try document(), at: 230, length: 80, .overwrite)
        // a: 0..<230, hold 230..<310 over the rest of a, all of b and the first 10 frames of p.
        XCTAssertEqual(spans(try clips(r)), [[0, 230, 0, nil], [230, 80, 230, 230], [310, 20, 0, nil]])
    }

    func testAtTheFirstAndLastFrameNothingIsCutBeforeOrAfterTheHold() throws {
        let first = try clips(try plan(try document(), at: 0))
        XCTAssertEqual(spans(first).prefix(2), [[0, 60, 0, 0], [60, 239, 1, nil]])
        let last = try clips(try plan(try document(), at: 239))
        XCTAssertEqual(spans(last).prefix(3), [[0, 239, 0, nil], [239, 60, 239, 239], [299, 30, 0, nil]])
    }

    func testRefusals() throws {
        func code(_ r: NativeTimelineHoldPlanResult) -> NativeTimelineHoldFailureCode? {
            if case .failure(let f) = r { return f.code }; return nil
        }
        XCTAssertEqual(code(try plan(try document(locked: true), at: 120)), .lockedTrack)
        XCTAssertEqual(code(try plan(try document(), at: 250)), .outsideClip)
        XCTAssertEqual(code(try plan(try document(), at: 120.5)), .outsideClip)
        XCTAssertEqual(code(try plan(try document(), at: 120, length: 0)), .invalidLength)
        XCTAssertEqual(code(try plan(try document(), at: 120, length: .nan)), .invalidLength)
        XCTAssertEqual(code(try plan(try document(), clip: "p", at: 310)), .notAVideoClip)
        XCTAssertEqual(code(try plan(try document(), clip: "zz", at: 10)), .clipNotFound)
        let held = try plan(try document(), at: 120).get()
        XCTAssertEqual(code(try plan(held.document, clip: held.holdClipId, at: 130)), .alreadyHeld)
    }

    func testAHoldCanBeExtendedAndSplitWithoutReadingMoreSource() throws {
        // Stretch a hold far past the source's 300 frames, and split it: neither reads more source.
        let p = try plan(try document(), at: 200).get()
        let a = NativeProjectClipAddress(sequenceId: "seq", trackId: "v1", clipId: p.holdClipId)
        let stretched = try applyNativeProjectClipCommand(p.document, .trimOut(address: a, endFrameExclusive: 200 + 500), engine: engine)
        XCTAssertTrue(stretched.ok, "\(String(describing: stretched.failure))")
        let split = try applyNativeProjectClipCommand(p.document, .split(address: a, splitFrame: 230), engine: engine)
        guard case .success(let doc, _) = split else { return XCTFail("\(String(describing: split.failure))") }
        let pieces = doc.sequence.tracks[0].clips.filter { $0.holdSourceFrame != nil }
        XCTAssertEqual(pieces.map(\.sourceInFrame), [200, 200], "both halves still hold frame 200")
    }
}
