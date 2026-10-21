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
@testable import MpvfxTimeline
import MpvfxShared
import OneTakeKeyframes

/// Clip edits and cut transitions (issue #265, A7): moving a clip away, deleting one or splitting inside the range
/// removes the transition, a trim shortens it, each in the same undo step as the clip edit, with a notice; undo
/// restores the transition exactly and redo removes it again.
final class TimelineCutTransitionTests: XCTestCase {
    /// "Interview 1" [0, 60) and "Interview 2" [60, 120) on one track, a centred 30-frame dissolve on the cut
    /// (frames 45…75).
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"Interview 1","source":"a.mov","durationFrames":300},
               {"id":"a2","kind":"video","name":"Interview 2","source":"b.mov","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}],
      "transitions":[{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30,"alignment":"centre"}]}]}}
    """#

    func editor() throws -> TimelineEditor { try TimelineEditor(json: Self.json, engine: try KeyframeRuntime()) }
    func address(_ id: String) -> NativeProjectClipAddress { .init(sequenceId: "s", trackId: "v1", clipId: id) }
    func transitions(_ e: TimelineEditor) -> [NativeCutTransition]? { e.document.sequence.tracks.first?.transitions }

    /// Runs `edit`, checks the notice and the transitions after it, then undo restores the original exactly and redo
    /// brings the edited state back.
    func assertUndoable(_ edit: (TimelineEditor) -> Bool, notice: String, after: [NativeCutTransition]?,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let e = try editor()
        var told: [String] = []
        e.onNotice = { told.append($0) }
        let original = try XCTUnwrap(transitions(e))
        XCTAssertTrue(edit(e), "\(e.lastFailure.map { "\($0)" } ?? "")", file: file, line: line)
        XCTAssertEqual(transitions(e), after, file: file, line: line)
        XCTAssertEqual(told, [notice], file: file, line: line)
        XCTAssertEqual(e.undoStack.count, 1, "one undo step", file: file, line: line)
        let edited = e.document
        XCTAssertTrue(e.undo(), file: file, line: line)
        XCTAssertEqual(transitions(e), original, "undo restores the transition exactly", file: file, line: line)
        XCTAssertTrue(e.redo(), file: file, line: line)
        XCTAssertEqual(e.document, edited, file: file, line: line)
    }

    let removed = #"Removed the transition between "Interview 1" and "Interview 2": its clips no longer meet at that cut."#

    func testA7MovingAClipAwayRemovesTheTransition() throws {
        try assertUndoable({ $0.apply(.move(address: self.address("B"), destination: .init(trackId: "v1", startFrame: 200))) },
                           notice: removed, after: nil)
    }

    func testA7DeletingAClipRemovesTheTransition() throws {
        try assertUndoable({ $0.apply(.delete(address: self.address("A"))) }, notice: removed, after: nil)
    }

    func testA7SplittingInsideTheRangeRemovesTheTransition() throws {
        try assertUndoable({ $0.apply(.split(address: self.address("B"), splitFrame: 70)) }, notice: removed, after: nil)
        try assertUndoable({ $0.apply(.split(address: self.address("A"), splitFrame: 50)) }, notice: removed, after: nil)
    }

    func testA7SplittingBeforeTheRangeKeepsTheTransitionOnTheCut() throws {
        let e = try editor()
        XCTAssertTrue(e.apply(.split(address: address("A"), splitFrame: 20)))
        let t = try XCTUnwrap(transitions(e)?.first)
        XCTAssertEqual(t.fromClipId, nativeSplitClipId("A", splitFrame: 20), "the right part now meets B")
        XCTAssertEqual(t.durationFrames, 30)
        XCTAssertNil(e.lastNotice)
        XCTAssertNotNil(nativeCutTransitionSpans(e.document)["B"]?.incoming, "still drawn")
    }

    func testA7ATrimThatLeavesTooLittleShortensTheTransition() throws {
        var shorter = try XCTUnwrap(try editor().document.sequence.tracks.first?.transitions)
        shorter[0].durationFrames = 20
        try assertUndoable({ $0.apply(.trimIn(address: self.address("A"), startFrame: 40)) },
                           notice: #"Shortened the transition between "Interview 1" and "Interview 2" by 10 frames to fit the media."#,
                           after: shorter)
    }

    func testTransitionEditsAreOneUndoStepAndRefusedOnALockedTrack() throws {
        let e = try editor()
        XCTAssertTrue(e.applyTransition(.setLength(id: "t1", durationFrames: 20)))
        XCTAssertEqual(e.undoLabel, "Change transition length")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(transitions(e)?.first?.durationFrames, 30)
        var locked = e.document
        locked.sequence.tracks[0].locked = true
        e.loadDocument(locked)
        XCTAssertFalse(e.applyTransition(.remove(id: "t1")))
        XCTAssertEqual(e.lastFailure?.message, "Track is locked")
    }
}
