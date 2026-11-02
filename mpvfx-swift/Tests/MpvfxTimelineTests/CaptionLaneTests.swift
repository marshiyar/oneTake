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
import MpvfxCanvas
import MpvfxShared
@testable import MpvfxTimeline

/// The caption lane in the timeline view: one block per cue at its time, selection, move and trim clamps, the text
/// field, and the "+" that adds a cue at the playhead. Pixel positions come from the view itself (`x(for:)`,
/// `captionCueRect`, `captionLaneFrame`), never from guessed numbers. The demo project runs at 30 fps and is 11 s long.
final class CaptionLaneTests: XCTestCase {
    static let threeCues = [
        NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
        NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3000, text: "two"),
        NativeCaptionCue(id: "cue:3", startMs: 3500, endMs: 5000, text: "three"),
    ]

    /// The demo project, with a caption track of `cues` when given, wired to a view, a playback and a controller.
    func rig(cues: [NativeCaptionCue]?) throws
        -> (view: TimelineView, playback: PlaybackState, controller: TimelineController, editor: TimelineEditor) {
        var d = try TimelineEditor(json: TimelineEditor.demoJSON).document
        if let cues = cues { d.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues) }
        let editor = TimelineEditor(document: try parseNativeProjectDocument(d))
        let view = TimelineView(tracks: [], duration: 0), playback = PlaybackState(duration: 0)
        let controller = TimelineController(view: view, playback: playback, editor: editor)
        controller.viewport = CanvasSize(1200, 600)
        controller.relayout()
        return (view, playback, controller, editor)
    }

    /// The view rectangle of the cue `id`'s block.
    func cueRect(_ view: TimelineView, _ id: String) throws -> CanvasRect {
        let cue = try XCTUnwrap(view.captions.cues.first { $0.id == id })
        return try XCTUnwrap(view.captionCueRect(cue))
    }

    /// The middle of a rectangle, in view space.
    func mid(_ r: CanvasRect) -> (x: Double, y: Double) { (r.x + r.width / 2, r.y + r.height / 2) }

    /// A y inside the caption lane, in view space.
    func laneY(_ view: TimelineView) throws -> Double {
        let f = try XCTUnwrap(view.captionLaneFrame)
        return f.top - view.scrollY + f.height / 2
    }

    /// Two presses on the body of `id` inside the double-click interval: the field opens on the cue.
    func doubleClick(_ c: TimelineController, _ view: TimelineView, _ id: String) throws {
        let p = mid(try cueRect(view, id))
        var clock = 1.0
        c.captionState.now = { clock }
        c.pointerDown(x: p.x, y: p.y)
        c.pointerUp(x: p.x, y: p.y)
        clock += 0.2
        c.pointerDown(x: p.x, y: p.y)
    }

    // MARK: Drawing geometry

    func testCaptionTrackDrawsOneBlockPerCueAtItsTime() throws {
        let (view, _, _, _) = try rig(cues: Self.threeCues)
        XCTAssertTrue(view.captions.isShown)
        XCTAssertEqual(view.bands, [.track(0), .track(1), .track(2), .captions])
        XCTAssertEqual(view.captions.cues, Self.threeCues)
        XCTAssertEqual(view.displayedCaptionCues.map(\.text), ["one", "two", "three"])
        let lane = try XCTUnwrap(view.captionLaneFrame)
        for cue in Self.threeCues {
            let r = try XCTUnwrap(view.captionCueRect(cue), cue.id)
            XCTAssertEqual(r.x, view.x(for: Double(cue.startMs) / 1000), accuracy: 1e-9, cue.id)
            XCTAssertEqual(r.width, Double(cue.endMs - cue.startMs) / 1000 * view.pixelsPerSecond, accuracy: 1e-6, cue.id)
            XCTAssertEqual(r.y, lane.top - view.scrollY + 3, accuracy: 1e-9, cue.id)
        }
    }

    func testProjectWithoutCaptionsHasNoLane() throws {
        let (view, _, _, _) = try rig(cues: nil)
        XCTAssertFalse(view.captions.isShown)
        XCTAssertEqual(view.bands, [.track(0), .track(1), .track(2)])
        XCTAssertNil(view.captionLaneFrame)
        XCTAssertNil(view.captionAddButtonRect)
        XCTAssertTrue(view.displayedCaptionCues.isEmpty)
    }

    func testEmptyCaptionTrackShowsTheLaneWithNoBlocks() throws {
        let (view, _, _, _) = try rig(cues: [])
        XCTAssertTrue(view.captions.isShown)
        XCTAssertEqual(view.bands.last, TimelineBand.captions)
        XCTAssertNotNil(view.captionLaneFrame)
        XCTAssertNotNil(view.captionAddButtonRect)
        XCTAssertTrue(view.captions.cues.isEmpty)
        XCTAssertTrue(view.displayedCaptionCues.isEmpty)
    }

    // MARK: Selection and hit testing

    func testPressOnCueSelectsItAndPressOnEmptyClipAreaClearsIt() throws {
        let (view, _, c, _) = try rig(cues: Self.threeCues)
        let p = mid(try cueRect(view, "cue:2"))
        c.pointerDown(x: p.x, y: p.y)
        c.pointerUp(x: p.x, y: p.y)
        XCTAssertEqual(view.captions.selectedCueId, "cue:2")

        // Track 0 holds clip:logo from 0.5 s to 3.5 s only, so 9 s on that row is empty.
        let track0 = try XCTUnwrap(view.bandFrames().first { $0.band == .track(0) })
        let emptyY = track0.top - view.scrollY + 5
        c.pointerDown(x: view.x(for: 9), y: emptyY)
        c.pointerUp(x: view.x(for: 9), y: emptyY)
        XCTAssertNil(view.captions.selectedCueId)
    }

    func testLaneHitTestIsEmptyWithNoRow() throws {
        let (view, _, c, _) = try rig(cues: Self.threeCues)
        let y = try laneY(view)
        let cueMid = mid(try cueRect(view, "cue:1"))
        XCTAssertEqual(c.hitTest(x: view.x(for: 9), y: y), .empty(row: nil))
        XCTAssertEqual(c.hitTest(x: cueMid.x, y: y), .empty(row: nil), "a cue body is still the lane")
        XCTAssertEqual(c.hitTest(x: 10, y: y), .empty(row: nil), "the label column")
    }

    // MARK: Move

    func testDragPastNeighbourClampsWhileDraggingAndCommitsOneUndoStep() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        let before = editor.document
        let down = mid(try cueRect(view, "cue:2"))
        c.pointerDown(x: down.x, y: down.y)

        // One second to the right would start cue:2 at 3000 ms. cue:3 starts at 3500 ms, so the cue stops at 2500 ms (end 3500).
        let target = down.x + view.pixelsPerSecond
        c.pointerMove(x: target, y: down.y)
        XCTAssertEqual(view.captions.preview?.startMs, 2500)
        XCTAssertEqual(view.captions.preview?.endMs, 3500)
        XCTAssertEqual(editor.captionCues[1].startMs, 2000, "nothing is committed during the drag")
        XCTAssertTrue(editor.undoStack.isEmpty)

        c.pointerUp(x: target, y: down.y)
        XCTAssertNil(view.captions.preview)
        XCTAssertEqual(editor.captionCues[1], NativeCaptionCue(id: "cue:2", startMs: 2500, endMs: 3500, text: "two"))
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.undoLabel, "Move caption")

        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, before)
    }

    // MARK: Trim

    func testRightHandleStopsAtTheNextCueStart() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        let r1 = try cueRect(view, "cue:1")
        let grab = (x: r1.maxX - 2, y: r1.y + r1.height / 2)
        c.pointerDown(x: grab.x, y: grab.y)
        c.pointerMove(x: view.x(for: 4), y: grab.y)
        XCTAssertEqual(view.captions.preview?.endMs, 2000)
        XCTAssertEqual(editor.captionCues[0].endMs, 1000, "nothing is committed during the drag")
        c.pointerUp(x: view.x(for: 4), y: grab.y)
        XCTAssertEqual(editor.captionCues[0], NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 2000, text: "one"))
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.undoLabel, "Trim caption")
    }

    func testLeftHandleStopsAtThePreviousCueEnd() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        let r2 = try cueRect(view, "cue:2")
        let grab = (x: r2.x + 2, y: r2.y + r2.height / 2)
        c.pointerDown(x: grab.x, y: grab.y)
        c.pointerMove(x: view.x(for: 0), y: grab.y)
        XCTAssertEqual(view.captions.preview?.startMs, 1000)
        XCTAssertEqual(view.captions.preview?.endMs, 3000, "the other end stays put")
        c.pointerUp(x: view.x(for: 0), y: grab.y)
        XCTAssertEqual(editor.captionCues[1], NativeCaptionCue(id: "cue:2", startMs: 1000, endMs: 3000, text: "two"))
        XCTAssertEqual(editor.undoStack.count, 1)
    }

    func testHandleDraggedPastTheOtherEndClampsToOneFrame() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        XCTAssertEqual(editor.captionMinimumDurationMs, 34, "one frame at 30 fps, rounded up to whole milliseconds")
        let r1 = try cueRect(view, "cue:1")
        let grab = (x: r1.maxX - 2, y: r1.y + r1.height / 2)
        c.pointerDown(x: grab.x, y: grab.y)
        c.pointerMove(x: view.x(for: 0) - 5 * view.pixelsPerSecond, y: grab.y)
        XCTAssertEqual(view.captions.preview?.endMs, 34)
        c.pointerUp(x: view.x(for: 0) - 5 * view.pixelsPerSecond, y: grab.y)
        XCTAssertEqual(editor.captionCues[0].startMs, 0)
        XCTAssertEqual(editor.captionCues[0].endMs, 34)
        XCTAssertEqual(editor.undoStack.count, 1)
    }

    // MARK: Text field

    func testDoubleClickOpensTheFieldAndEnterSavesOneUndoStep() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        let p = mid(try cueRect(view, "cue:2"))
        var clock = 1.0
        c.captionState.now = { clock }
        c.pointerDown(x: p.x, y: p.y)
        c.pointerUp(x: p.x, y: p.y)
        XCTAssertNil(view.captions.edit, "one press only selects")

        clock += 0.2
        c.pointerDown(x: p.x, y: p.y)
        let edit = try XCTUnwrap(view.captions.edit)
        XCTAssertEqual(edit.cueId, "cue:2")
        XCTAssertEqual(edit.draft, "two")

        // The text is selected when the field opens, so the first character replaces it.
        for ch in "new" { c.keyDown(EditorKey(.char(ch))) }
        XCTAssertEqual(view.captions.edit?.draft, "new")
        XCTAssertTrue(editor.undoStack.isEmpty, "typing does not touch the document")

        c.keyDown(EditorKey(.enter))
        XCTAssertNil(view.captions.edit)
        XCTAssertEqual(editor.captionCues[1].text, "new")
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.undoLabel, "Edit caption")
    }

    func testPressesFarApartDoNotOpenTheField() throws {
        let (view, _, c, _) = try rig(cues: Self.threeCues)
        let p = mid(try cueRect(view, "cue:2"))
        var clock = 1.0
        c.captionState.now = { clock }
        c.pointerDown(x: p.x, y: p.y)
        c.pointerUp(x: p.x, y: p.y)
        clock += 0.5
        c.pointerDown(x: p.x, y: p.y)
        XCTAssertNil(view.captions.edit, "0.5 s is beyond the 0.4 s double-click interval")
    }

    func testEscapeCancelsTheFieldWithoutHistory() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        let before = editor.document
        try doubleClick(c, view, "cue:2")
        XCTAssertNotNil(view.captions.edit)
        c.keyDown(EditorKey(.char("x")))
        c.keyDown(EditorKey(.escape))
        XCTAssertNil(view.captions.edit)
        XCTAssertEqual(editor.document, before)
        XCTAssertTrue(editor.undoStack.isEmpty)
    }

    func testEnterOnAnEmptyDraftKeepsTheFieldOpenWithAReason() throws {
        let (view, _, c, editor) = try rig(cues: Self.threeCues)
        try doubleClick(c, view, "cue:2")
        c.keyDown(EditorKey(.backspace))
        XCTAssertEqual(view.captions.edit?.draft, "")
        c.keyDown(EditorKey(.enter))
        let edit = try XCTUnwrap(view.captions.edit)
        XCTAssertEqual(edit.problem, "Caption text must not be empty")
        XCTAssertTrue(editor.undoStack.isEmpty)
        XCTAssertEqual(editor.captionCues[1].text, "two")
    }

    // MARK: Add at the playhead

    func testAddAfterTheLastCueMakesATwoSecondCueAtThePlayhead() throws {
        let (view, playback, c, editor) = try rig(cues: Self.threeCues)
        playback.seek(5.5)
        XCTAssertTrue(c.addCaptionAtPlayhead())
        XCTAssertEqual(editor.captionCues.count, 4)
        XCTAssertEqual(editor.captionCues.last, NativeCaptionCue(id: "cue:manual-1", startMs: 5500, endMs: 7500, text: "Caption"))
        XCTAssertEqual(view.captions.selectedCueId, "cue:manual-1")
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.undoLabel, "Add caption")
    }

    func testAddInAGapStopsAtTheNextCue() throws {
        let (view, playback, c, editor) = try rig(cues: Self.threeCues)
        playback.seek(3.2)
        XCTAssertTrue(c.addCaptionAtPlayhead())
        XCTAssertEqual(editor.captionCues.count, 4)
        XCTAssertEqual(editor.captionCues[2], NativeCaptionCue(id: "cue:manual-1", startMs: 3200, endMs: 3500, text: "Caption"))
        XCTAssertEqual(view.captions.selectedCueId, "cue:manual-1")
        XCTAssertEqual(editor.undoStack.count, 1)
    }

    func testAddInsideACueRefusesWithANoticeAndNoHistory() throws {
        let (view, playback, c, editor) = try rig(cues: Self.threeCues)
        var notices: [String] = []
        editor.onNotice = { notices.append($0) }
        playback.seek(2.5)
        XCTAssertFalse(c.addCaptionAtPlayhead())
        XCTAssertEqual(editor.captionCues, Self.threeCues)
        XCTAssertTrue(editor.undoStack.isEmpty)
        XCTAssertEqual(notices, ["There is no room for a caption at the playhead"])
        XCTAssertNil(view.captions.selectedCueId)
    }

    func testPlusButtonAddsACueAtThePlayhead() throws {
        let (view, playback, c, editor) = try rig(cues: Self.threeCues)
        playback.seek(5.5)
        let add = try XCTUnwrap(view.captionAddButtonRect)
        let p = mid(add)
        c.pointerDown(x: p.x, y: p.y)
        XCTAssertEqual(editor.captionCues.last, NativeCaptionCue(id: "cue:manual-1", startMs: 5500, endMs: 7500, text: "Caption"))
        XCTAssertEqual(view.captions.selectedCueId, "cue:manual-1")
        XCTAssertEqual(editor.undoStack.count, 1)
    }
}
