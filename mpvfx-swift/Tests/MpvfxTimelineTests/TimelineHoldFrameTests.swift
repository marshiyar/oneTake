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
import MpvfxCanvas
import MpvfxShared

/// ⇧H / ⌥⇧H on the timeline: the frame of the video clip under the playhead held for the Settings length, one
/// undo step, refused on a locked track with the locked-track message.
final class TimelineHoldFrameTests: XCTestCase {
    static let json = """
    {"schemaVersion":1,"mediaEngine":"native","id":"hold","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":36,"background":"#000000"},
     "assets":[{"id":"cam","kind":"video","name":"cam","source":"cam.mov","durationFrames":300}],
     "sequence":{"id":"seq","name":"Main","tracks":[{"id":"v1","kind":"video","clips":[
       {"id":"a","assetId":"cam","startFrame":0,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
    """

    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: Self.json)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 20), editor: e)
        c.playback.seek(120.0 / 30)
        return (c, e)
    }

    func clipEnd(_ e: TimelineEditor) -> Double { e.document.sequence.tracks[0].clips.map { $0.startFrame + $0.durationFrames }.max() ?? 0 }

    func testShiftHInsertsAHoldOfTheSettingsLengthAsOneUndoStep() throws {
        let (c, e) = try make()
        c.holdSeconds = 2
        XCTAssertTrue(c.keyDown(EditorKey(.char("H"), shift: true)))
        let hold = try XCTUnwrap(e.document.sequence.tracks[0].clips.first { $0.holdSourceFrame != nil })
        XCTAssertEqual([hold.startFrame, hold.durationFrames, hold.holdSourceFrame?.sourceFrame], [120, 60, 120])
        XCTAssertEqual(c.view.selection, [hold.id], "the hold is selected")
        XCTAssertEqual(clipEnd(e), 299)
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Hold frame")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, try TimelineEditor(json: Self.json).document)
    }

    func testOptionShiftHOverwritesAndKeepsTheLength() throws {
        let (c, e) = try make()
        XCTAssertTrue(c.keyDown(EditorKey(.char("h"), shift: true, alt: true)))
        XCTAssertEqual(clipEnd(e), 240)
        XCTAssertEqual(e.undoLabel, "Overwrite with hold frame")
    }

    func testALockedTrackRefusesWithTheLockedTrackMessage() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setTrackLocked("v1", true))
        var refused: [String] = []
        c.onEditRefused = { refused.append($0) }
        let before = e.document
        XCTAssertFalse(c.keyDown(EditorKey(.char("H"), shift: true)))
        XCTAssertEqual(refused, ["Track is locked"])
        XCTAssertEqual(e.document, before)
    }

    func testNoVideoClipUnderThePlayheadIsRefused() throws {
        let (c, _) = try make()
        c.playback.seek(250.0 / 30)
        var refused: [String] = []
        c.onEditRefused = { refused.append($0) }
        XCTAssertFalse(c.holdFrameAtPlayhead(overwrite: false))
        XCTAssertEqual(refused, ["Move the playhead onto a video clip to hold its frame"])
    }

    func testHoldLengthIsWholeFramesRoundedHalfToEven() throws {
        let (_, e) = try make()
        XCTAssertEqual(e.holdFrames(seconds: 2), 60)
        XCTAssertEqual(e.holdFrames(seconds: 0.05), 2, "1.5 frames round to 2")
        XCTAssertEqual(e.holdFrames(seconds: 0.001), 1, "at least one frame")
        XCTAssertNil(e.holdFrames(seconds: 0)); XCTAssertNil(e.holdFrames(seconds: .nan)); XCTAssertNil(e.holdFrames(seconds: -1))
    }
}
