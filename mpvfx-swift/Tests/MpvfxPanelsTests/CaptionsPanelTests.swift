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
import MpvfxTimeline
@testable import MpvfxPanels
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import MpvfxTheme
import UniformTypeIdentifiers
#endif

/// The demo project with a caption track of `cues` (nil: no track at all), parsed like any loaded project. It runs at 30 fps.
private func captionedEditor(_ cues: [NativeCaptionCue]?) throws -> TimelineEditor {
    var d = try TimelineEditor(json: TimelineEditor.demoJSON).document
    if let cues { d.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues) }
    return TimelineEditor(document: try parseNativeProjectDocument(d))
}

/// The caption list's rows, keys, find and replace, pointer presses and the reading-rate badge. A frame at 30 fps is 33 ms
/// for a nudge (1000 / 30 rounded) and 34 ms as the shortest cue (rounded up).
final class CaptionsPanelTests: XCTestCase {
    static let threeCues = [
        NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
        NativeCaptionCue(id: "cue:2", startMs: 1000, endMs: 3000, text: "hello brave world"),
        NativeCaptionCue(id: "cue:3", startMs: 3500, endMs: 4000, text: "three"),
    ]

    private func make(_ cues: [NativeCaptionCue] = CaptionsPanelTests.threeCues) throws -> (CaptionsPanel, TimelineEditor) {
        let e = try captionedEditor(cues), p = CaptionsPanel()
        p.editor = e
        layOut(p)
        return (p, e)
    }

    /// Draws once so the row list has its viewport (rows are hit-tested and revealed against it).
    private func layOut(_ p: CaptionsPanel) {
        p.draw(PanelMeasureCanvas(), size: CanvasSize(360, 400))
    }

    // MARK: Empty state

    func testWithoutACaptionTrackTheListSaysWhereToAddOneAndNothingIsEditable() throws {
        let e = try captionedEditor(nil), p = CaptionsPanel()
        p.editor = e
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(360, 400))
        XCTAssertTrue(c.drawnStrings.contains("No captions"))
        XCTAssertTrue(c.drawnStrings.contains(where: { $0.hasPrefix("Add a caption track by importing an SRT file") }))
        XCTAssertEqual(p.rows.count, 0)
        XCTAssertFalse(p.keyDown(.init(.enter)))
        XCTAssertFalse(p.keyDown(.init(.char("j"), meta: true)))
        XCTAssertFalse(p.keyDown(.init(.enter, meta: true)))
        XCTAssertFalse(p.keyDown(.init(.char("["), alt: true)))
        XCTAssertTrue(p.keyDown(.init(.down)), "Down on an empty list is a no-op")
        XCTAssertNil(p.selectedID)
        XCTAssertEqual(e.undoStack.count, 0)
    }

    func testRowsShowTheInAndOutTimesAndTheTextAndClockFormatsHours() throws {
        let (p, _) = try make()
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(360, 400))
        XCTAssertTrue(c.drawnStrings.contains("0:00:01.000  →  0:00:03.000"))
        XCTAssertTrue(c.drawnStrings.contains("hello brave world"))
        XCTAssertEqual(CaptionsPanel.clock(3_600_001), "1:00:00.001")
    }

    // MARK: Up and down, and Enter

    func testDownAndUpMoveSelectionAndJumpToEachCueStartWithClampingAtBothEnds() throws {
        let (p, e) = try make()
        var jumps: [Double] = []
        p.onJump = { jumps.append($0) }
        XCTAssertTrue(p.keyDown(.init(.down))); XCTAssertEqual(p.selectedID, "cue:1")
        XCTAssertTrue(p.keyDown(.init(.down))); XCTAssertEqual(p.selectedID, "cue:2")
        XCTAssertTrue(p.keyDown(.init(.down))); XCTAssertEqual(p.selectedID, "cue:3")
        XCTAssertEqual(jumps, [0, 1, 3.5])
        XCTAssertTrue(p.keyDown(.init(.down)), "Down on the last cue is handled")
        XCTAssertEqual(p.selectedID, "cue:3", "Down on the last cue stays on it")
        XCTAssertEqual(jumps, [0, 1, 3.5, 3.5], "and still puts the playhead on it")
        XCTAssertTrue(p.keyDown(.init(.up))); XCTAssertEqual(p.selectedID, "cue:2")
        XCTAssertTrue(p.keyDown(.init(.up))); XCTAssertEqual(p.selectedID, "cue:1")
        XCTAssertTrue(p.keyDown(.init(.up)), "Up on the first cue is handled")
        XCTAssertEqual(p.selectedID, "cue:1", "Up on the first cue stays on it")
        XCTAssertEqual(jumps, [0, 1, 3.5, 3.5, 1, 0, 0])
        XCTAssertEqual(e.undoStack.count, 0)
    }

    func testEnterBeginsEditingWithTheCueTextAndCaretAtTheEnd() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertEqual(p.editingID, "cue:2")
        XCTAssertEqual(p.draft, "hello brave world")
        XCTAssertEqual(p.caret, 17)
        XCTAssertTrue(p.keyDown(.init(.escape)))
        XCTAssertTrue(p.keyDown(.init(.function(2))), "F2 also begins editing")
        XCTAssertEqual(p.editingID, "cue:2")
        XCTAssertEqual(p.caret, 17)
        XCTAssertEqual(e.undoStack.count, 0)
    }

    func testTypingAndCaretKeysEditTheDraftAtTheCaretAndStoreNothingUntilEnter() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertTrue(p.keyDown(.init(.home))); XCTAssertEqual(p.caret, 0)
        XCTAssertTrue(p.keyDown(.init(.char("X")))); XCTAssertEqual(p.draft, "Xhello brave world"); XCTAssertEqual(p.caret, 1)
        XCTAssertTrue(p.keyDown(.init(.right))); XCTAssertEqual(p.caret, 2)
        XCTAssertTrue(p.keyDown(.init(.left))); XCTAssertTrue(p.keyDown(.init(.left))); XCTAssertEqual(p.caret, 0)
        XCTAssertTrue(p.keyDown(.init(.left))); XCTAssertEqual(p.caret, 0, "Left stops at the start")
        XCTAssertTrue(p.keyDown(.init(.end))); XCTAssertEqual(p.caret, 18)
        XCTAssertTrue(p.keyDown(.init(.right))); XCTAssertEqual(p.caret, 18, "Right stops at the end")
        XCTAssertTrue(p.keyDown(.init(.backspace)))
        XCTAssertEqual(p.draft, "Xhello brave worl"); XCTAssertEqual(p.caret, 17)
        XCTAssertTrue(p.keyDown(.init(.home)))
        XCTAssertTrue(p.keyDown(.init(.space)))
        XCTAssertEqual(p.draft, " Xhello brave worl"); XCTAssertEqual(p.caret, 1)
        XCTAssertTrue(p.keyDown(.init(.delete)))
        XCTAssertEqual(p.draft, " hello brave worl"); XCTAssertEqual(p.caret, 1)
        XCTAssertEqual(p.editingID, "cue:2")
        XCTAssertEqual(e.captionCues[1].text, "hello brave world", "nothing is stored until Enter")
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertTrue(p.keyDown(.init(.escape)))
    }

    func testShiftEnterAddsALineBreakAndKeepsEditingOpen() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertTrue(p.keyDown(.init(.end)))
        XCTAssertTrue(p.keyDown(.init(.enter, shift: true)))
        XCTAssertEqual(p.draft, "one\n")
        XCTAssertEqual(p.caret, 4)
        XCTAssertEqual(p.editingID, "cue:1")
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertTrue(p.keyDown(.init(.escape)))
    }

    func testEnterCommitsTheDraftAsOneUndoStepAndUndoRestoresIt() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertTrue(p.keyDown(.init(.char("!"))))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertNil(p.editingID)
        XCTAssertEqual(e.captionCues[0].text, "one!")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Edit caption")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.captionCues[0].text, "one")
    }

    func testEscCancelsEditingAndLeavesNoHistory() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertTrue(p.keyDown(.init(.char("z"))))
        XCTAssertTrue(p.keyDown(.init(.char("z"))))
        XCTAssertEqual(p.draft, "onezz")
        XCTAssertTrue(p.keyDown(.init(.escape)))
        XCTAssertNil(p.editingID)
        XCTAssertEqual(e.captionCues[0].text, "one")
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertFalse(e.canUndo)
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertEqual(p.draft, "one", "the next edit starts from the stored text")
        XCTAssertTrue(p.keyDown(.init(.escape)))
    }

    func testCommittingAnEmptyDraftKeepsEditingOpenAndRecordsNothing() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        for _ in 0..<3 { XCTAssertTrue(p.keyDown(.init(.backspace))) }
        XCTAssertEqual(p.draft, "")
        XCTAssertEqual(p.caret, 0)
        XCTAssertTrue(p.keyDown(.init(.enter)), "Enter is handled")
        XCTAssertEqual(p.editingID, "cue:1", "editing stays open")
        XCTAssertFalse(p.commitEditing())
        XCTAssertEqual(e.captionCues[0].text, "one")
        XCTAssertEqual(e.undoStack.count, 0)
    }

    // MARK: Nudge

    func testAltBracketsNudgeTheInAndOutPointOneFrameAsOneUndoStepEach() throws {
        let (p, e) = try make()
        for _ in 0..<3 { XCTAssertTrue(p.keyDown(.init(.down))) }   // cue:3, 3500-4000
        XCTAssertTrue(p.keyDown(.init(.char("["), alt: true)))
        XCTAssertEqual(e.captionCues[2].startMs, 3467, "the in point one frame (33 ms) earlier")
        XCTAssertTrue(p.keyDown(.init(.char("["), shift: true, alt: true)))
        XCTAssertEqual(e.captionCues[2].startMs, 3500, "Alt+Shift+[ moves the in point one frame later")
        XCTAssertTrue(p.keyDown(.init(.char("]"), alt: true)))
        XCTAssertEqual(e.captionCues[2].endMs, 4033, "the out point one frame later")
        XCTAssertTrue(p.keyDown(.init(.char("]"), shift: true, alt: true)))
        XCTAssertEqual(e.captionCues[2].endMs, 4000, "Alt+Shift+] moves the out point one frame earlier")
        XCTAssertEqual(e.undoStack.count, 4, "each nudge is one undo step")
        XCTAssertEqual(e.undoLabel, "Nudge caption")
        for _ in 0..<4 { XCTAssertTrue(e.undo()) }
        XCTAssertEqual(e.captionCues, Self.threeCues)
    }

    func testNudgesClampAgainstTheNeighbourCuesAndRecordNothingWhenTheyDoNotMove() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.down)))   // cue:2 starts exactly where cue:1 ends
        XCTAssertFalse(p.keyDown(.init(.char("["), alt: true)), "the in point is already against cue:1")
        XCTAssertEqual(e.captionCues[1].startMs, 1000)
        XCTAssertTrue(p.keyDown(.init(.up)))     // cue:1 ends exactly where cue:2 starts
        XCTAssertFalse(p.keyDown(.init(.char("]"), alt: true)), "the out point is already against cue:2")
        XCTAssertEqual(e.captionCues[0].endMs, 1000)
        XCTAssertEqual(e.undoStack.count, 0, "a clamped nudge that moves nothing records nothing")
    }

    // MARK: Split and join

    func testCmdEnterWhileEditingSplitsAtCaretAndPlayheadInOneUndoStep() throws {
        let (p, e) = try make()
        p.playheadMs = { 2000 }
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertTrue(p.keyDown(.init(.home)))
        for _ in 0..<5 { XCTAssertTrue(p.keyDown(.init(.right))) }
        XCTAssertEqual(p.caret, 5)
        XCTAssertTrue(p.keyDown(.init(.enter, meta: true)))
        XCTAssertEqual(e.captionCues.count, 4)
        XCTAssertEqual(e.captionCues[0], Self.threeCues[0])
        XCTAssertEqual(e.captionCues[1], NativeCaptionCue(id: "cue:2", startMs: 1000, endMs: 2000, text: "hello"))
        XCTAssertEqual(e.captionCues[2], NativeCaptionCue(id: "cue:split-1", startMs: 2000, endMs: 3000, text: "brave world"))
        XCTAssertEqual(e.captionCues[1].endMs, e.captionCues[2].startMs, "the two halves stay contiguous")
        XCTAssertEqual(e.captionCues[3], Self.threeCues[2])
        XCTAssertEqual(p.selectedID, "cue:split-1", "the selection moves to the new cue")
        XCTAssertNil(p.editingID)
        XCTAssertEqual(e.undoStack.count, 1, "text, split and cut are one undo step")
        XCTAssertEqual(e.undoLabel, "Split caption")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.captionCues, Self.threeCues)
    }

    func testCmdEnterWithoutAnEditBreaksAtTheSpaceNearestThePlayheadShare() throws {
        let (p, e) = try make()
        p.playheadMs = { 2000 }
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.down)))   // cue:2, 1000-3000, playhead at its midpoint
        XCTAssertTrue(p.keyDown(.init(.enter, meta: true)))
        // The midpoint of 17 characters is 8.5, nearest to the space at index 11 ("hello brave" | "world").
        XCTAssertEqual(e.captionCues[1], NativeCaptionCue(id: "cue:2", startMs: 1000, endMs: 2000, text: "hello brave"))
        XCTAssertEqual(e.captionCues[2], NativeCaptionCue(id: "cue:split-1", startMs: 2000, endMs: 3000, text: "world"))
        XCTAssertEqual(p.selectedID, "cue:split-1")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Split caption")
    }

    func testCmdJJoinsTheSelectedCueWithTheNextInOneUndoStep() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.down)))
        XCTAssertTrue(p.keyDown(.init(.char("j"), meta: true)))
        XCTAssertEqual(e.captionCues.count, 2)
        XCTAssertEqual(e.captionCues[0], NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 3000, text: "one hello brave world"))
        XCTAssertEqual(e.captionCues[1], Self.threeCues[2])
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Join captions")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.captionCues, Self.threeCues)
    }

    func testCmdJOnTheLastCueDoesNothingAndRecordsNothing() throws {
        let (p, e) = try make()
        for _ in 0..<3 { XCTAssertTrue(p.keyDown(.init(.down))) }
        XCTAssertEqual(p.selectedID, "cue:3")
        XCTAssertFalse(p.keyDown(.init(.char("j"), meta: true)))
        XCTAssertEqual(e.captionCues, Self.threeCues)
        XCTAssertEqual(e.undoStack.count, 0)
    }

    // MARK: Find and replace

    func testCmdFOpensFindTypingFillsTheFieldAndBackspaceEditsIt() throws {
        let (p, _) = try make()
        XCTAssertTrue(p.keyDown(.init(.char("f"), meta: true)))
        XCTAssertTrue(p.findOpen)
        XCTAssertFalse(p.replaceOpen)
        XCTAssertEqual(p.findField, 0)
        XCTAssertTrue(p.keyDown(.init(.char("o"))))
        XCTAssertTrue(p.keyDown(.init(.char("x"))))
        XCTAssertEqual(p.findText, "ox")
        XCTAssertEqual(p.matches.map { $0.cueId }, [])
        XCTAssertTrue(p.keyDown(.init(.backspace)))
        XCTAssertEqual(p.findText, "o")
        XCTAssertEqual(p.matches.map { $0.cueId }, ["cue:1", "cue:2"])
        XCTAssertEqual(p.matches.map { $0.count }, [1, 2], "one o in 'one', two in 'hello brave world'")
    }

    func testFindNextSelectsTheNextMatchAndWrapsRoundTheCues() throws {
        let (p, _) = try make()
        var jumps: [Double] = []
        p.onJump = { jumps.append($0) }
        XCTAssertTrue(p.keyDown(.init(.char("f"), meta: true)))
        XCTAssertTrue(p.keyDown(.init(.char("o"))))
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertEqual(p.selectedID, "cue:1")
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertEqual(p.selectedID, "cue:2")
        XCTAssertTrue(p.keyDown(.init(.enter)))
        XCTAssertEqual(p.selectedID, "cue:1", "after the last match the search wraps to the first")
        XCTAssertEqual(jumps, [0, 1, 0])
        XCTAssertNil(p.editingID, "Enter in find does not begin editing")
    }

    func testAltCTogglesCaseSensitiveFindAndIsNotTyped() throws {
        let (p, _) = try make()
        XCTAssertTrue(p.keyDown(.init(.char("f"), meta: true)))
        XCTAssertTrue(p.keyDown(.init(.char("O"))))
        XCTAssertEqual(p.matches.map { $0.cueId }, ["cue:1", "cue:2"], "find ignores case by default")
        XCTAssertTrue(p.keyDown(.init(.char("c"), alt: true)))
        XCTAssertTrue(p.caseSensitive)
        XCTAssertEqual(p.matches.count, 0, "no cue has a capital O")
        XCTAssertFalse(p.findNext())
        XCTAssertEqual(p.findText, "O", "Alt+C is a key, not text")
        XCTAssertTrue(p.keyDown(.init(.char("c"), alt: true)))
        XCTAssertFalse(p.caseSensitive)
    }

    func testEscClosesFindAndTypingNoLongerReachesIt() throws {
        let (p, _) = try make()
        XCTAssertTrue(p.keyDown(.init(.char("f"), meta: true)))
        XCTAssertTrue(p.keyDown(.init(.char("o"))))
        XCTAssertTrue(p.keyDown(.init(.escape)))
        XCTAssertFalse(p.findOpen)
        XCTAssertEqual(p.matches.count, 0)
        XCTAssertFalse(p.keyDown(.init(.char("x"))), "a plain letter is not handled once find is closed")
        XCTAssertEqual(p.findText, "o")
    }

    func testCmdAltFOpensReplaceTabSwitchesFieldAndReplaceAllIsOneUndoStep() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.char("f"), alt: true, meta: true)))
        XCTAssertTrue(p.findOpen)
        XCTAssertTrue(p.replaceOpen)
        XCTAssertTrue(p.keyDown(.init(.char("o"))))
        XCTAssertTrue(p.keyDown(.init(.tab)))
        XCTAssertEqual(p.findField, 1)
        XCTAssertTrue(p.keyDown(.init(.char("0"))))
        XCTAssertEqual(p.replaceText, "0")
        XCTAssertEqual(p.findText, "o")
        XCTAssertTrue(p.keyDown(.init(.enter, alt: true, meta: true)))
        XCTAssertEqual(p.status, "Replaced 3 in 2 cues")
        XCTAssertEqual(e.captionCues.map { $0.text }, ["0ne", "hell0 brave w0rld", "three"])
        XCTAssertEqual(e.undoStack.count, 1, "replace all is one undo step")
        XCTAssertEqual(e.undoLabel, "Replace in captions")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.captionCues.map { $0.text }, ["one", "hello brave world", "three"])
    }

    func testReplaceAllWithNoMatchChangesNothingAndSaysSo() throws {
        let (p, e) = try make()
        XCTAssertTrue(p.keyDown(.init(.char("f"), alt: true, meta: true)))
        for ch in "zz" { XCTAssertTrue(p.keyDown(.init(.char(ch)))) }
        XCTAssertFalse(p.keyDown(.init(.enter, alt: true, meta: true)))
        XCTAssertEqual(p.status, "No cue to change")
        XCTAssertEqual(e.undoStack.count, 0)
    }

    // MARK: Pointer

    func testPointerDownOnARowSelectsAndJumpsAndOutsideTheRowsDoesNothing() throws {
        let (p, e) = try make()
        var jumps: [Double] = []
        p.onJump = { jumps.append($0) }
        p.now = { 10 }
        let second = p.list.rect(of: 1)
        XCTAssertTrue(p.pointerDown(.init(25, second.y + 10), shift: false))
        XCTAssertEqual(p.selectedID, "cue:2")
        XCTAssertEqual(jumps, [1])
        XCTAssertNil(p.editingID)
        XCTAssertFalse(p.pointerDown(.init(25, 390), shift: false), "below the last row is not a row")
        XCTAssertEqual(jumps, [1])
        XCTAssertEqual(e.undoStack.count, 0)
    }

    func testSecondPressOnTheSameRowWithinHalfASecondBeginsEditing() throws {
        let (p, _) = try make()
        var jumps: [Double] = []
        p.onJump = { jumps.append($0) }
        var time = 10.0
        p.now = { time }
        let row = p.list.rect(of: 1)
        XCTAssertTrue(p.pointerDown(.init(25, row.y + 10), shift: false))
        time += 0.2
        XCTAssertTrue(p.pointerDown(.init(25, row.y + 10), shift: false))
        XCTAssertEqual(p.editingID, "cue:2")
        XCTAssertEqual(p.draft, "hello brave world")
        XCTAssertEqual(jumps, [1], "the second press edits instead of jumping again")
    }

    func testAPressAfterHalfASecondOnlySelectsAgain() throws {
        let (p, _) = try make()
        var jumps: [Double] = []
        p.onJump = { jumps.append($0) }
        var time = 10.0
        p.now = { time }
        let row = p.list.rect(of: 1)
        XCTAssertTrue(p.pointerDown(.init(25, row.y + 10), shift: false))
        time += 0.5
        XCTAssertTrue(p.pointerDown(.init(25, row.y + 10), shift: false))
        XCTAssertNil(p.editingID)
        XCTAssertEqual(jumps, [1, 1])
    }

    // MARK: Reading rate

    func testRowsReadFasterThanTheReadingRateLimitAreFlagged() throws {
        let fast = NativeCaptionCue(id: "cue:fast", startMs: 0, endMs: 500, text: "hello brave world")
        let (p, _) = try make([fast, Self.threeCues[1], Self.threeCues[2]])
        XCTAssertEqual(p.readingRateLimit, NATIVE_CAPTION_READING_RATE_DEFAULT)
        XCTAssertEqual(nativeCaptionReadingRate(fast), 34, accuracy: 1e-9, "17 characters over half a second")
        XCTAssertTrue(nativeCaptionExceedsReadingRate(fast, limit: p.readingRateLimit))
        XCTAssertFalse(nativeCaptionExceedsReadingRate(Self.threeCues[1], limit: p.readingRateLimit), "17 characters over 2 s is 8.5")
        p.readingRateLimit = 40
        XCTAssertFalse(nativeCaptionExceedsReadingRate(fast, limit: p.readingRateLimit), "no badge above a raised limit")
    }
}

#if canImport(CoreGraphics)
/// The drawn panel in both appearances. The offscreen canvas is y-down, so pixel (x, y) is the point the panel draws at.
/// Snapshots go to MPVFX_SNAPSHOT_DIR when it is set.
final class CaptionsPanelDrawTests: XCTestCase {
    override func tearDown() {
        Theme.setMode(.dark)
        super.tearDown()
    }

    /// The first row reads at 34 characters a second, over the limit of 17, so it is badged; the others are not.
    static let cues = [
        NativeCaptionCue(id: "cue:fast", startMs: 0, endMs: 500, text: "hello brave world"),
        NativeCaptionCue(id: "cue:b", startMs: 1000, endMs: 2000, text: "one"),
        NativeCaptionCue(id: "cue:c", startMs: 2500, endMs: 3500, text: "three"),
    ]

    private func render(_ panel: CaptionsPanel, mode: ThemeMode) throws -> CoreGraphicsCanvas {
        Theme.setMode(mode)
        let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 360, height: 400))
        panel.draw(canvas, size: CanvasSize(360, 400))
        return canvas
    }

    /// The RGB of the pixel at (x, y) in the panel's top-left coordinates.
    private func rgb(_ c: CoreGraphicsCanvas, _ x: Int, _ y: Int) throws -> (r: Double, g: Double, b: Double) {
        let bytes = try XCTUnwrap(c.ctx.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * c.ctx.bytesPerRow + x * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255)
    }

    /// True when some pixel in `area` is within 3% of `color` on every channel.
    private func contains(_ c: CoreGraphicsCanvas, _ area: CanvasRect, _ color: ThemeColor) throws -> Bool {
        for y in Int(area.y)..<Int(area.maxY) {
            for x in Int(area.x)..<Int(area.maxX) {
                let p = try rgb(c, x, y)
                if abs(p.r - color.r) < 0.03, abs(p.g - color.g) < 0.03, abs(p.b - color.b) < 0.03 { return true }
            }
        }
        return false
    }

    private func writeSnapshot(_ canvas: CoreGraphicsCanvas, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        let image = try XCTUnwrap(canvas.ctx.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testDarkAndLightDrawTheBadgeOnTheFastRowOnlyAndTheBackgroundFollowsTheAppearance() throws {
        let panel = CaptionsPanel()
        panel.editor = try captionedEditor(Self.cues)
        var backgrounds: [ThemeMode: (r: Double, g: Double, b: Double)] = [:]
        for mode in [ThemeMode.dark, .light] {
            let canvas = try render(panel, mode: mode)
            let first = panel.list.rect(of: 0), second = panel.list.rect(of: 1)
            let red = ThemeTokens.red500Pair.now
            // The badge sits 8 to 62 px in from the row's right edge.
            let firstRight = CanvasRect(x: first.maxX - 80, y: first.y, width: 80, height: first.height)
            let secondRight = CanvasRect(x: second.maxX - 80, y: second.y, width: 80, height: second.height)
            let badged = try contains(canvas, firstRight, red)
            XCTAssertTrue(badged, "the fast row shows the red badge (\(mode.rawValue))")
            let unbadged = try contains(canvas, secondRight, red)
            XCTAssertFalse(unbadged, "a row read within the limit has no badge (\(mode.rawValue))")
            backgrounds[mode] = try rgb(canvas, 180, 390)
            try writeSnapshot(canvas, name: "captions-\(mode.rawValue).png")
        }
        let dark = try XCTUnwrap(backgrounds[.dark]), light = try XCTUnwrap(backgrounds[.light])
        XCTAssertGreaterThan(abs(dark.r - light.r) + abs(dark.g - light.g) + abs(dark.b - light.b), 0.1,
                             "the panel background differs between dark and light")
    }

    func testEmptyStateDrawsInBothAppearancesAndWithoutAnEditor() throws {
        let panel = CaptionsPanel()
        panel.editor = try captionedEditor(nil)
        for mode in [ThemeMode.dark, .light] { _ = try render(panel, mode: mode) }
        panel.editor = nil
        for mode in [ThemeMode.dark, .light] { _ = try render(panel, mode: mode) }
    }
}
#endif
