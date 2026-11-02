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
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxShared
import MpvfxCanvas

/// Cut transitions on the timeline (issue #266): ⌘T and ⇧⌘T add them, the band is drawn over the cut and selected by a
/// click, its edges resize it (stopping at the media and never moving a clip), ⌥← / ⌥→ walk cut to cut, ⌥[ / ⌥]
/// change the length, Delete removes and Enter opens it; each edit is one undo step and a locked track refuses.
final class TimelineTransitionControllerTests: XCTestCase {
    /// v1: A [0,60), B [60,120), C [120,180), 30 frames of media before each in point; v2 is locked, with two touching
    /// clips. 100 px per second at 30 fps: one frame is 10/3 px, and the first row starts at x 264.
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"One","source":"a.mov","durationFrames":300},
               {"id":"a2","kind":"video","name":"Two","source":"b.mov","durationFrames":300},
               {"id":"a3","kind":"video","name":"Three","source":"c.mov","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[
      {"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"C","assetId":"a3","startFrame":120,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"v2","kind":"video","locked":true,"lane":{"authoredTrack":1,"displayTrack":1},"clips":[
       {"id":"L1","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"L2","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#
    static let px = 100.0 / 30
    func x(_ frame: Double) -> Double { 264 + frame * Self.px }
    /// Inside the first row's clip bar.
    var rowY: Double { TimelineLayout.rowTop(0) + 20 }

    func make() throws -> (TimelineController, TimelineEditor, notices: () -> [String]) {
        let e = try TimelineEditor(json: Self.json, engine: try KeyframeRuntime())
        var told: [String] = []
        e.onNotice = { told.append($0) }
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 30), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(pixelsPerSecond: 100); c.snapEnabled = false
        return (c, e, { told })
    }
    func transitions(_ e: TimelineEditor, _ track: String = "v1") -> [NativeCutTransition] {
        e.document.sequence.tracks.first { $0.id == track }?.cutTransitions ?? []
    }
    func command(_ ch: Character, shift: Bool = false) -> EditorKey { EditorKey(.char(ch), shift: shift, meta: true) }
    func option(_ code: EditorKey.Code, shift: Bool = false) -> EditorKey { EditorKey(code, shift: shift, alt: true) }
    func starts(_ e: TimelineEditor) -> [Double] { e.document.sequence.tracks.flatMap(\.clips).map(\.startFrame) }

    // MARK: Adding

    func testCommandTAddsACentredFifteenFrameDissolveAtTheNearestCutInOneUndoStep() throws {
        let (c, e, _) = try make()
        c.view.selection = ["A"]
        c.playback.seek(55 / 30)
        XCTAssertTrue(c.keyDown(command("t")))
        let t = try XCTUnwrap(transitions(e).first)
        XCTAssertEqual([t.fromClipId, t.toClipId], ["A", "B"], "frame 55 is nearest the cut at 60")
        XCTAssertEqual(t.kind, .dissolve)
        XCTAssertEqual(t.durationFrames, 15)
        XCTAssertEqual(t.alignment, .centre)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(c.view.selectedTransitionId, t.id, "the new band is selected")
        XCTAssertTrue(e.undo())
        XCTAssertTrue(transitions(e).isEmpty)
    }

    func testCommandTWithNothingSelectedUsesTheTopmostUnlockedVideoTrack() throws {
        let (c, e, _) = try make()
        c.playback.seek(118 / 30)
        XCTAssertTrue(c.keyDown(command("t")))
        XCTAssertEqual(transitions(e).map(\.toClipId), ["C"], "nearest cut of v1; v2 is locked")
        XCTAssertTrue(transitions(e, "v2").isEmpty)
    }

    func testShiftCommandTCoversEveryCutBetweenSelectedClipsInOneStep() throws {
        let (c, e, _) = try make()
        c.view.selection = ["A", "B", "C"]
        XCTAssertTrue(c.keyDown(command("t", shift: true)))
        XCTAssertEqual(transitions(e).map(\.toClipId), ["B", "C"])
        XCTAssertEqual(e.undoStack.count, 1, "two cuts, one undo step")
        XCTAssertTrue(e.undo())
        XCTAssertTrue(transitions(e).isEmpty)
    }

    func testTheDefaultLengthComesFromTheEditor() throws {
        let (c, e, _) = try make()
        e.defaultTransitionFrames = 24
        c.view.selection = ["A"]
        XCTAssertTrue(c.keyDown(command("t")))
        XCTAssertEqual(transitions(e).first?.durationFrames, 24)
    }

    func testALockedTrackRefusesEveryTransitionKeyWithItsMessage() throws {
        let (c, e, told) = try make()
        c.view.selection = ["L1"]
        c.playback.seek(2)
        XCTAssertTrue(c.keyDown(command("t")))
        XCTAssertTrue(transitions(e, "v2").isEmpty)
        XCTAssertTrue(e.undoStack.isEmpty)
        XCTAssertEqual(told(), ["Track is locked"])
    }

    func testACutThatAlreadyHasATransitionIsLeftAlone() throws {
        let (c, e, told) = try make()
        c.view.selection = ["A"]
        XCTAssertTrue(c.keyDown(command("t")))
        XCTAssertTrue(c.keyDown(command("t")))
        XCTAssertEqual(transitions(e).count, 1)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(told(), ["This cut already has a transition."])
    }

    // MARK: The band

    func testTheBandSitsAroundTheCutPerAlignmentAndIsHitOnItsBodyAndEdges() throws {
        let (c, e, _) = try make()
        let ab = try XCTUnwrap(e.allCuts.first { $0.fromClipId == "A" })
        XCTAssertTrue(e.applyTransition(.dissolve, to: ab, lengthFrames: 20).applied)
        c.view.selection = []
        c.view.tracks = e.tracks
        let model = try XCTUnwrap(c.view.tracks[0].transitions.first)
        XCTAssertEqual(model.start * 30, 50, accuracy: 1e-9)
        XCTAssertEqual(model.end * 30, 70, accuracy: 1e-9)
        let rect = c.view.transitionRect(row: 0, model)
        XCTAssertEqual(rect.x, x(50), accuracy: 0.01)
        XCTAssertEqual(rect.width, 20 * Self.px, accuracy: 0.01)
        guard case .transition(let id, 0, nil) = c.hitTest(x: x(60), y: rowY) else { return XCTFail("the middle of the band") }
        XCTAssertEqual(id, model.id)
        guard case .transition(_, 0, .start?) = c.hitTest(x: x(50) + 2, y: rowY) else { return XCTFail("its start edge") }
        guard case .transition(_, 0, .end?) = c.hitTest(x: x(70) - 2, y: rowY) else { return XCTFail("its end edge") }
        guard case .clip = c.hitTest(x: x(40), y: rowY) else { return XCTFail("outside the band is the clip") }
        XCTAssertTrue(e.applyTransition(.setAlignment(id: model.id, alignment: .endsAtCut)))
        c.view.tracks = e.tracks
        let ends = try XCTUnwrap(c.view.tracks[0].transitions.first)
        XCTAssertEqual([ends.start * 30, ends.end * 30], [40, 60], "all before the cut")
        XCTAssertTrue(e.applyTransition(.setAlignment(id: model.id, alignment: .startsAtCut)))
        c.view.tracks = e.tracks
        let starts = try XCTUnwrap(c.view.tracks[0].transitions.first)
        XCTAssertEqual([starts.start * 30, starts.end * 30], [60, 80], "all after the cut")
    }

    func testAClickSelectsTheBandAndAClickElsewhereDropsIt() throws {
        let (c, e, _) = try make()
        c.view.selection = ["A"]
        XCTAssertTrue(c.keyDown(command("t")))
        c.view.selectedTransitionId = nil
        c.pointerDown(x: x(60), y: rowY); c.pointerUp(x: x(60), y: rowY)
        XCTAssertEqual(c.view.selectedTransitionId, transitions(e).first?.id)
        c.pointerDown(x: x(100), y: rowY); c.pointerUp(x: x(100), y: rowY)
        XCTAssertNil(c.view.selectedTransitionId, "a click on a clip leaves the band")
    }

    // MARK: Resizing

    func testDraggingAnEdgeResizesFrameByFrameAndStopsAtTheMediaWithoutMovingAClip() throws {
        let (c, e, _) = try make()
        let ab = try XCTUnwrap(e.allCuts.first { $0.fromClipId == "A" })
        XCTAssertTrue(e.applyTransition(.dissolve, to: ab, lengthFrames: 20).applied)
        c.view.tracks = e.tracks
        let before = starts(e)
        let steps = e.undoStack.count
        // Grab the end edge (frame 70), drag to frame 75: a centred transition grows by twice the distance.
        c.pointerDown(x: x(70) - 2, y: rowY)
        c.pointerMove(x: x(75), y: rowY)
        XCTAssertEqual(c.view.transitionDrag?.frames, 30, "twice the 15 frames from the cut")
        c.pointerMove(x: x(76), y: rowY)
        XCTAssertEqual(c.view.transitionDrag?.frames, 32, "one more frame of drag, two more of length")
        c.pointerUp(x: x(76), y: rowY)
        XCTAssertEqual(transitions(e).first?.durationFrames, 32)
        XCTAssertEqual(e.undoStack.count, steps + 1, "one undo step")
        XCTAssertEqual(starts(e), before, "no clip moved")
        // Far past the media: B has 30 frames before its in point, so a centred dissolve holds at most 61.
        c.view.tracks = e.tracks
        c.pointerDown(x: x(76) - 2, y: rowY)
        c.pointerMove(x: x(170), y: rowY)
        XCTAssertEqual(c.view.transitionDrag?.frames, 61)
        XCTAssertEqual(c.view.transitionHint, "At most 61 frames: the clips have no more media for this transition")
        c.pointerUp(x: x(170), y: rowY)
        XCTAssertEqual(transitions(e).first?.durationFrames, 61)
        XCTAssertNil(c.view.transitionHint)
        XCTAssertNil(c.view.transitionDrag)
        XCTAssertEqual(starts(e), before, "still no clip moved")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(transitions(e).first?.durationFrames, 32)
    }

    func testDraggingTheEdgeInShortensButNeverBelowTwoFrames() throws {
        let (c, e, _) = try make()
        let ab = try XCTUnwrap(e.allCuts.first { $0.fromClipId == "A" })
        XCTAssertTrue(e.applyTransition(.dissolve, to: ab, lengthFrames: 20).applied)
        c.view.tracks = e.tracks
        c.pointerDown(x: x(70) - 2, y: rowY)
        c.pointerMove(x: x(60), y: rowY)
        XCTAssertEqual(c.view.transitionDrag?.frames, 2)
        c.pointerUp(x: x(60), y: rowY)
        XCTAssertEqual(transitions(e).first?.durationFrames, 2)
    }

    // MARK: Keyboard

    func testOptionArrowsWalkFromCutToCutAndMoveThePlayhead() throws {
        let (c, e, _) = try make()
        c.view.selection = ["A"]
        XCTAssertTrue(c.keyDown(option(.right)))
        XCTAssertEqual(c.view.selectedCut?.toClipId, "B")
        XCTAssertEqual(c.playback.currentTime * e.fps, 60, accuracy: 1e-6)
        XCTAssertTrue(c.keyDown(option(.right)))
        XCTAssertEqual(c.view.selectedCut?.toClipId, "C")
        XCTAssertTrue(c.keyDown(option(.right)))
        XCTAssertEqual(c.view.selectedCut?.toClipId, "C", "no cut after the last one: stays")
        XCTAssertTrue(c.keyDown(option(.left)))
        XCTAssertEqual(c.view.selectedCut?.toClipId, "B")
        XCTAssertTrue(e.undoStack.isEmpty, "walking edits nothing")
    }

    func testTheWholeTransitionCanBeMadeResizedOpenedAndRemovedFromTheKeyboard() throws {
        let (c, e, _) = try make()
        var opened: [String] = []
        c.onEditTransition = { opened.append($0) }
        c.view.selection = ["A"]
        XCTAssertTrue(c.keyDown(option(.right)))
        XCTAssertTrue(c.keyDown(command("t")))
        let id = try XCTUnwrap(transitions(e).first?.id)
        XCTAssertEqual(c.view.selectedTransitionId, id)
        XCTAssertTrue(c.keyDown(option(.char("]"))))
        XCTAssertEqual(transitions(e).first?.durationFrames, 16, "⌥] lengthens by a frame")
        XCTAssertTrue(c.keyDown(option(.char("]"), shift: true)))
        XCTAssertEqual(transitions(e).first?.durationFrames, 26, "⇧ makes it ten")
        XCTAssertTrue(c.keyDown(option(.char("["))))
        XCTAssertEqual(transitions(e).first?.durationFrames, 25, "⌥[ shortens by a frame")
        XCTAssertEqual(e.undoStack.count, 4, "the add and each length change is one undo step")
        XCTAssertTrue(c.keyDown(EditorKey(.enter)))
        XCTAssertEqual(opened, [id])
        XCTAssertTrue(c.keyDown(EditorKey(.delete)))
        XCTAssertTrue(transitions(e).isEmpty)
        XCTAssertNil(c.view.selectedTransitionId)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(transitions(e).first?.durationFrames, 25, "undo brings it back as it was")
    }

    func testDeleteWithNoTransitionSelectedStillDeletesTheSelectedClip() throws {
        let (c, e, _) = try make()
        c.view.selection = ["C"]
        XCTAssertTrue(c.keyDown(EditorKey(.delete)))
        XCTAssertNil(e.clip("C"))
    }
}
