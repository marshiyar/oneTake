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
import MpvfxShared
@testable import MpvfxTimeline

/// The caption lane's editor commands: each commits one undo step, clamps against neighbours and the one-frame minimum,
/// and leaves a document that still parses. The demo project runs at 30 fps, so one frame is 34 ms (1000 / 30 rounded up).
final class CaptionEditorTests: XCTestCase {
    static let threeCues = [
        NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
        NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3000, text: "two"),
        NativeCaptionCue(id: "cue:3", startMs: 5000, endMs: 6000, text: "three"),
    ]

    /// The demo project with a caption track of `cues`, validated like any loaded project.
    func captioned(_ cues: [NativeCaptionCue]) throws -> NativeProjectDocument {
        var d = try TimelineEditor(json: TimelineEditor.demoJSON).document
        d.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues)
        return try parseNativeProjectDocument(d)
    }

    func testProjectWithoutCaptionsHasNoCuesAndRejectsEveryCaptionEdit() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        XCTAssertNil(e.document.sequence.captions)
        XCTAssertTrue(e.captionCues.isEmpty)
        XCTAssertFalse(e.moveCaptionCue("cue:1", toStartMs: 100))
        XCTAssertFalse(e.trimCaptionCue("cue:1", edge: .end, toMs: 500))
        XCTAssertFalse(e.setCaptionText("cue:1", to: "x"))
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.fps, 30)
        XCTAssertEqual(e.captionMinimumDurationMs, 34)
    }

    func testMoveChangesOnlyThatCueAndOneUndoRestoresTheDocument() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertTrue(e.moveCaptionCue("cue:2", toStartMs: 2500))
        let after = e.document
        let moved = NativeCaptionCue(id: "cue:2", startMs: 2500, endMs: 3500, text: "two")
        XCTAssertEqual(e.captionCues, [Self.threeCues[0], moved, Self.threeCues[2]])
        var withoutCaptionsNow = after, withoutCaptionsBefore = before
        withoutCaptionsNow.sequence.captions = nil; withoutCaptionsBefore.sequence.captions = nil
        XCTAssertEqual(withoutCaptionsNow, withoutCaptionsBefore, "a caption move touches nothing but the caption track")
        XCTAssertEqual(e.undoLabel, "Move caption")
        XCTAssertEqual(e.undoStack.count, 1)

        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.captionCues, Self.threeCues)
        XCTAssertEqual(e.redoLabel, "Move caption")

        XCTAssertTrue(e.redo())
        XCTAssertEqual(e.document, after)
    }

    func testMoveAndTrimClampAgainstNeighboursAndStillParse() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        // cue:2 is 1000 ms long; cue:1 ends at 1000 and cue:3 starts at 5000.
        XCTAssertTrue(e.moveCaptionCue("cue:2", toStartMs: 100))
        XCTAssertEqual(e.captionCues[1].startMs, 1000)
        XCTAssertEqual(e.captionCues[1].endMs, 2000)
        XCTAssertNoThrow(try parseNativeProjectDocument(e.document, engine: nil))

        XCTAssertTrue(e.moveCaptionCue("cue:2", toStartMs: 9000))
        XCTAssertEqual(e.captionCues[1].startMs, 4000)
        XCTAssertEqual(e.captionCues[1].endMs, 5000)
        XCTAssertNoThrow(try parseNativeProjectDocument(e.document, engine: nil))

        let fresh = TimelineEditor(document: try captioned(Self.threeCues))
        XCTAssertTrue(fresh.trimCaptionCue("cue:2", edge: .end, toMs: 9000))
        XCTAssertEqual(fresh.captionCues[1].startMs, 2000)
        XCTAssertEqual(fresh.captionCues[1].endMs, 5000)
        XCTAssertTrue(fresh.trimCaptionCue("cue:2", edge: .start, toMs: 500))
        XCTAssertEqual(fresh.captionCues[1].startMs, 1000)
        XCTAssertEqual(fresh.captionCues[1].endMs, 5000)
        XCTAssertNoThrow(try parseNativeProjectDocument(fresh.document, engine: nil))
    }

    func testTrimBelowOneFrameClampsToTheMinimumInBothDirections() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        // Pulling the end of cue:2 (2000..3000) to 2010 stops one frame (34 ms) after its start.
        XCTAssertTrue(e.trimCaptionCue("cue:2", edge: .end, toMs: 2010))
        XCTAssertEqual(e.captionCues[1].startMs, 2000)
        XCTAssertEqual(e.captionCues[1].endMs, 2034)
        XCTAssertEqual(e.captionCues[1].endMs - e.captionCues[1].startMs, e.captionMinimumDurationMs)
        // Already at the minimum: a further trim moves nothing and records nothing.
        XCTAssertFalse(e.trimCaptionCue("cue:2", edge: .end, toMs: 1))
        XCTAssertEqual(e.undoStack.count, 1)

        let fresh = TimelineEditor(document: try captioned(Self.threeCues))
        // Pulling the start of cue:2 to 2999 stops one frame before its end at 3000.
        XCTAssertTrue(fresh.trimCaptionCue("cue:2", edge: .start, toMs: 2999))
        XCTAssertEqual(fresh.captionCues[1].startMs, 2966)
        XCTAssertEqual(fresh.captionCues[1].endMs, 3000)
        XCTAssertEqual(fresh.captionCues[1].endMs - fresh.captionCues[1].startMs, 34)
    }

    func testSetCaptionTextIsOneUndoStepAndRejectsUnstorableOrUnchangedText() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertFalse(e.setCaptionText("cue:2", to: ""))
        XCTAssertFalse(e.setCaptionText("cue:2", to: "a --> b"))
        XCTAssertFalse(e.setCaptionText("cue:2", to: "two"), "an unchanged text records nothing")
        XCTAssertFalse(e.setCaptionText("cue:9", to: "x"), "an unknown cue records nothing")
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.document, before)

        XCTAssertTrue(e.setCaptionText("cue:2", to: "two\r\nlines"))
        XCTAssertEqual(e.captionCues[1].text, "two\nlines", "line endings normalise to \\n")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Edit caption")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)
    }

    func testAddCaptionCueMakesATwoSecondCueThatOneUndoRemoves() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        // After cue:3 (ends 6000) nothing follows, so the new cue gets the full 2000 ms.
        XCTAssertEqual(e.addCaptionCue(atMs: 6500), "cue:manual-1")
        XCTAssertTrue(e.captionCues[3].id.hasPrefix("cue:manual-"))
        XCTAssertEqual(e.captionCues, Self.threeCues + [NativeCaptionCue(id: "cue:manual-1", startMs: 6500, endMs: 8500, text: "Caption")])
        XCTAssertEqual(e.undoLabel, "Add caption")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)
    }

    func testAddCaptionCueFillsAShortGapRefusesInsideACueAndNeedsAFrameOfRoom() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertNil(e.addCaptionCue(atMs: 2500), "2500 ms is inside cue:2")
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.document, before)

        // The gap from 3500 to cue:3 (5000) is 1500 ms, shorter than 2 s, so the cue fills it.
        XCTAssertEqual(e.addCaptionCue(atMs: 3500), "cue:manual-1")
        XCTAssertEqual(e.captionCues[2], NativeCaptionCue(id: "cue:manual-1", startMs: 3500, endMs: 5000, text: "Caption"))
        XCTAssertNil(e.addCaptionCue(atMs: 4000), "4000 ms is inside the new cue")
        XCTAssertEqual(e.addCaptionCue(atMs: 6500), "cue:manual-2", "ids skip the ones in use")

        // A gap of 10 ms holds less than one frame (34 ms): nothing is added.
        let tight = TimelineEditor(document: try captioned([
            NativeCaptionCue(id: "cue:a", startMs: 0, endMs: 1000, text: "a"),
            NativeCaptionCue(id: "cue:b", startMs: 1010, endMs: 2000, text: "b"),
        ]))
        let tightBefore = tight.document
        XCTAssertNil(tight.addCaptionCue(atMs: 1000))
        XCTAssertEqual(tight.document, tightBefore)
        XCTAssertFalse(tight.canUndo)
    }

    func testCaptionEditSurvivesARestartAndUndoesAfterReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-captions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTimelineHistoryStore(directory: dir)
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        e.onHistoryChange = { store.save(projectId: "project:captions", e.persistedHistory()) }
        let d0 = e.document
        XCTAssertTrue(e.setCaptionText("cue:2", to: "edited"))
        let d1 = e.document

        // "Restart": a fresh editor on the saved document.
        let e2 = TimelineEditor(document: e.document)
        let saved = try XCTUnwrap(store.load(projectId: "project:captions"))
        XCTAssertTrue(e2.restoreHistory(saved))
        XCTAssertEqual(e2.undoLabel, "Edit caption")
        XCTAssertEqual(e2.document, d1)
        XCTAssertEqual(e2.captionCues[1].text, "edited")
        XCTAssertTrue(e2.undo())
        XCTAssertEqual(e2.captionCues[1].text, "two")
        XCTAssertEqual(e2.document, d0)
        XCTAssertFalse(e2.canUndo)
    }
}
