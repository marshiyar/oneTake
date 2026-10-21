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

/// Clip drags across rows (timelineClipDragPreview / timelineCollision / timelineClipDragCommit): lane changes,
/// new tracks at row boundaries and past the edges, no overlap on a row, rigid multi-selection, locks, undo.
final class TimelineTrackMoveTests: XCTestCase {
    // 30 fps, 100 px/s. Each spec is one track (top row first): [(clip id, startFrame, durationFrames)].
    static func json(_ tracks: [[(String, Int, Int)]], audioTrack: Int? = nil) -> String {
        let t = tracks.enumerated().map { i, clips -> String in
            let kind = i == audioTrack ? "audio" : "video"
            let c = clips.map { #"{"id":"\#($0.0)","assetId":"\#(kind == "audio" ? "asset:m" : "asset:v")","startFrame":\#($0.1),"durationFrames":\#($0.2),"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}"# }
            return #"{"id":"track:\#(i)","kind":"\#(kind)","lane":{"authoredTrack":\#(tracks.count - i),"displayTrack":\#(i)},"clips":[\#(c.joined(separator: ","))]}"#
        }
        return #"""
        {"schemaVersion":1,"id":"project:move","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#111111"},
         "assets":[{"id":"asset:v","kind":"video","name":"v.mp4","durationFrames":3000},{"id":"asset:m","kind":"audio","name":"m.wav","durationFrames":3000}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[\#(t.joined(separator: ","))]}}
        """#
    }

    func make(_ tracks: [[(String, Int, Int)]], audioTrack: Int? = nil) throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: Self.json(tracks, audioTrack: audioTrack))
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 400); c.setZoom(pixelsPerSecond: 100)
        c.snapEnabled = false
        return (c, e)
    }

    func rowY(_ c: TimelineController, _ r: Int) -> Double { c.view.rowTop(r) + c.view.trackHeight / 2 }
    func x(_ c: TimelineController, _ seconds: Double) -> Double { c.view.x(for: seconds) }

    /// Track id (display order) holding each clip, and its start frame.
    func layout(_ e: TimelineEditor) -> [[String]] { e.tracks.map { $0.clips.map(\.id) } }
    func start(_ e: TimelineEditor, _ id: String) -> Double? { e.clip(id)?.clip.startFrame }

    /// Press on a clip at (fromSeconds, fromRow), drag to (toSeconds, toY), release.
    /// `alt`: Option/Alt held for the whole drag (the original placement, no swap onto a busy row).
    func drag(_ c: TimelineController, from: (Double, Int), toX: Double, toY: Double, shift: Bool = false, alt: Bool = false) {
        c.dragSwapDisabled = alt; defer { c.dragSwapDisabled = false }
        c.pointerDown(x: x(c, from.0), y: rowY(c, from.1), shift: shift)
        c.pointerMove(x: x(c, from.0) + 10, y: rowY(c, from.1))
        c.pointerMove(x: toX, y: toY)
        c.pointerUp(x: toX, y: toY)
    }

    // MARK: Lane changes

    func testMoveToAnotherRowOnAFreeSpanAndEmptyRowGoes() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        let before = e.document
        drag(c, from: (1, 0), toX: x(c, 1) + 600, toY: rowY(c, 1))   // A to 6s..11s on row 1
        XCTAssertEqual(layout(e), [["B", "A"]], "A joins B's row; the row it left is removed")
        XCTAssertEqual(start(e, "A"), 180)
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Move clip")
        XCTAssertEqual(c.view.selection, ["A"])
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before, "one undo step restores both rows")
        XCTAssertTrue(e.redo()); XCTAssertEqual(layout(e), [["B", "A"]])
    }

    func testDropOnAnOccupiedSpanTakesTheNearestFreeRowAbove() throws {
        // Option held (no swap): aimed row 2 is taken for 0..5s; row 1 above it is free there, so A lands on row 1.
        let (c, e) = try make([[("A", 0, 150)], [("B", 300, 60)], [("C", 0, 150)]])
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 2), alt: true)
        XCTAssertEqual(layout(e), [["A", "B"], ["C"]])
        XCTAssertEqual(start(e, "A"), 0, "clips placed across one another on different rows")
    }

    func testOverlappingDropOntoTheOnlyOtherRowStaysPut() throws {
        // Option held (no swap): both rows hold a clip for 0..5s; the dragged clip's own row is the nearest free one
        // (resolvePlacement).
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        let before = e.document
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1), alt: true)
        XCTAssertEqual(e.document, before); XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testEveryRowTakenOpensANewTrackBesideTheAimedRow() throws {
        let (c, e) = try make([[("A", 0, 150), ("X", 150, 150)], [("B", 0, 300)]])
        // Option held (no swap): A to 5s..10s aimed at row 1 (lower half): row 1 has B, row 0 has X -> new row below row 1.
        c.dragSwapDisabled = true
        c.pointerDown(x: x(c, 1), y: rowY(c, 0)); c.pointerMove(x: x(c, 1) + 10, y: rowY(c, 0))
        c.pointerMove(x: x(c, 6), y: rowY(c, 1) + 10)
        XCTAssertEqual(c.view.dropTarget, .insert(2))
        c.pointerUp(x: x(c, 6), y: rowY(c, 1) + 10)
        XCTAssertEqual(layout(e), [["X"], ["B"], ["A"]])
        XCTAssertEqual(start(e, "A"), 150)
        XCTAssertEqual(e.undoLabel, "Move clip to new track")
    }

    // MARK: New tracks past the edges and at boundaries

    func testDropAboveTheTopRowCreatesATrackOnTop() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        let before = e.document
        c.pointerDown(x: x(c, 1), y: rowY(c, 1)); c.pointerMove(x: x(c, 1) + 10, y: rowY(c, 1))
        c.pointerMove(x: x(c, 1), y: c.view.rowTop(0) - 6)
        XCTAssertEqual(c.view.dropTarget, .insert(0))
        if case .move(let ids, _, _, _)? = c.view.drag, let b = c.view.tracks[1].clips.first {
            XCTAssertEqual(ids, ["B"])
            XCTAssertEqual(c.view.clipRect(track: 1, b).y, c.view.rowTop(0) - 6 - c.view.trackHeight / 2 + TimelineLayout.clipY, accuracy: 0.5,
                           "the dragged clip follows the pointer")
        } else { XCTFail("no move preview") }
        c.pointerUp(x: x(c, 1), y: c.view.rowTop(0) - 6)
        XCTAssertEqual(layout(e), [["B"], ["A"]], "B on a new top row; its old row is removed")
        XCTAssertEqual(e.document.sequence.tracks.count, 2)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
    }

    func testDropBelowTheBottomRowCreatesATrackAtTheBottomAndSwapsRows() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        drag(c, from: (1, 0), toX: x(c, 1), toY: c.view.boundaryTop(2) + 6)
        XCTAssertEqual(layout(e), [["B"], ["A"]], "A and B swapped rows")
        // The picture follows: the top row (B) now draws over A.
        let layers = nativeTrackStackingLayers(e.document.sequence.tracks)
        let rowOf = { (id: String) in e.document.sequence.tracks.firstIndex { $0.clips.contains { $0.id == id } }! }
        XCTAssertGreaterThan(layers[rowOf("B")], layers[rowOf("A")])
    }

    func testBoundaryBetweenRowsInsertsATrackThere() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)], [("C", 0, 150)]])
        // The 3px band at the top edge of row 2 inserts between rows 1 and 2.
        drag(c, from: (1, 0), toX: x(c, 1), toY: c.view.rowTop(2) + 1)
        XCTAssertEqual(layout(e), [["B"], ["A"], ["C"]])
        XCTAssertEqual(e.tracks[1].kind, "video")
    }

    func testAudioClipGetsAnAudioTrack() throws {
        let (c, e) = try make([[("V", 0, 150)], [("M", 0, 150)]], audioTrack: 1)
        drag(c, from: (1, 1), toX: x(c, 1), toY: c.view.boundaryTop(2) + 6)
        XCTAssertEqual(e.tracks.map(\.kind), ["video", "audio"])
        XCTAssertEqual(layout(e), [["V"], ["M"]])
        XCTAssertTrue(e.tracks[1].id.hasPrefix("track:audio"))
    }

    // MARK: Split pieces

    func testSplitPiecesMoveToDifferentRows() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        XCTAssertTrue(e.split(["A"], atFrame: 75))
        let right = nativeSplitClipId("A", splitFrame: 75)
        XCTAssertEqual(layout(e), [["A", right], ["B"]])
        // Right piece (2.5s..5s) to row 1 at 6s; then the left piece onto a new bottom row.
        c.view.selection = []
        drag(c, from: (3.5, 0), toX: x(c, 3.5) + 350, toY: rowY(c, 1))
        XCTAssertEqual(layout(e), [["A"], ["B", right]])
        XCTAssertEqual(start(e, right), 180)
        c.view.selection = []
        drag(c, from: (1, 0), toX: x(c, 1), toY: c.view.boundaryTop(2) + 6)
        XCTAssertEqual(layout(e), [["B", right], ["A"]])
        XCTAssertEqual(e.undoStack.count, 3)
    }

    // MARK: Multi-selection

    func testSelectionMovesRigidlyAcrossRows() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 300, 60)], [("C", 600, 60)]])
        c.view.selection = ["A", "B"]
        drag(c, from: (1, 0), toX: x(c, 1) + 50, toY: rowY(c, 1))
        XCTAssertEqual(layout(e), [["A"], ["B", "C"]], "both clips go one row down; the emptied top row goes")
        XCTAssertEqual(start(e, "A"), 15); XCTAssertEqual(start(e, "B"), 315)
        XCTAssertEqual(e.undoLabel, "Move clips"); XCTAssertEqual(e.undoStack.count, 1)
    }

    func testSelectionThatWouldLeaveTheRowsOrCollideMovesNothing() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 300, 60)], [("C", 300, 60)]])
        let before = e.document
        c.view.selection = ["A", "B"]
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 2))   // B would leave the bottom row
        XCTAssertEqual(e.document, before)
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))   // B would land on C
        XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    // MARK: Locks

    func testLockedTracksRefuse() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 300, 60)], [("C", 600, 60)]])
        XCTAssertTrue(e.setTrackLocked("track:1", true))
        let before = e.document
        // A aimed at the locked row on a free span: never lands there (its own row is the nearest free one).
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertEqual(e.document, before)
        // B on the locked row does not move at all.
        drag(c, from: (3.2, 1), toX: x(c, 3.2) + 500, toY: rowY(c, 2))
        XCTAssertEqual(e.document, before)
        // A selection with a locked member moves nothing.
        c.view.selection = ["A", "B"]
        drag(c, from: (1, 0), toX: x(c, 1) + 100, toY: rowY(c, 0))
        XCTAssertEqual(e.document, before)
        // Past the locked row onto row 2 works.
        c.view.selection = []
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 2))
        XCTAssertEqual(layout(e), [["B"], ["A", "C"]])
        XCTAssertEqual(e.tracks[0].locked, true, "the locked row is kept")
    }

    // MARK: Pure rules

    func testInsertRowBands() {
        XCTAssertEqual(TimelineTrackDrop.insertRow(rowFloat: -0.2, rowCount: 2, band: 0.1), 0)
        XCTAssertEqual(TimelineTrackDrop.insertRow(rowFloat: 2.3, rowCount: 2, band: 0.1), 2)
        XCTAssertEqual(TimelineTrackDrop.insertRow(rowFloat: 1.05, rowCount: 2, band: 0.1), 1)
        XCTAssertEqual(TimelineTrackDrop.insertRow(rowFloat: 0.95, rowCount: 2, band: 0.1), 1)
        XCTAssertNil(TimelineTrackDrop.insertRow(rowFloat: 0.5, rowCount: 2, band: 0.1))
        XCTAssertEqual(TimelineTrackDrop.insertRow(rowFloat: 0.5, rowCount: 0, band: 0.1), 0)
    }

    func testPlacementPrefersUpThenDownThenInserts() {
        let p = { (free: Set<Int>, above: Bool) in
            TimelineTrackDrop.placement(rowCount: 4, desiredRow: 2, deliberateInsertRow: nil, preferInsertAbove: above) { free.contains($0) }
        }
        XCTAssertEqual(p([2], false), .row(2))
        XCTAssertEqual(p([0, 1, 3], false), .row(1))
        XCTAssertEqual(p([0, 3], false), .row(0))
        XCTAssertEqual(p([3], false), .row(3))
        XCTAssertEqual(p([], false), .insert(3))
        XCTAssertEqual(p([], true), .insert(2))
    }
}
