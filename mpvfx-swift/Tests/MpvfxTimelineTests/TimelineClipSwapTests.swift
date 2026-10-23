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

/// Clip swap on drop (a native addition): a single clip dropped onto a busy row trades places with what it
/// overlaps; Option/Alt held keeps the original placement, live mid-drag; fallbacks, selections, locks, kinds, undo.
final class TimelineClipSwapTests: XCTestCase {
    // 30 fps, 100 px/s. Each spec is one track (top row first): [(clip id, startFrame, durationFrames)].
    func make(_ tracks: [[(String, Int, Int)]], audioTrack: Int? = nil) throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineTrackMoveTests.json(tracks, audioTrack: audioTrack))
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(TimelineLayout.contentOrigin + TimelineZoom.minFitSpan * 100 + 2, 400); c.setZoom(pixelsPerSecond: 100)
        c.snapEnabled = false
        return (c, e)
    }
    func rowY(_ c: TimelineController, _ r: Int) -> Double { c.view.rowTop(r) + c.view.trackHeight / 2 }
    func x(_ c: TimelineController, _ seconds: Double) -> Double { c.view.x(for: seconds) }
    func layout(_ e: TimelineEditor) -> [[String]] { e.tracks.map { $0.clips.map(\.id) } }
    func start(_ e: TimelineEditor, _ id: String) -> Double? { e.clip(id)?.clip.startFrame }

    /// Press on a clip at (fromSeconds, fromRow) and drag to (toX, toY) without releasing.
    func press(_ c: TimelineController, from: (Double, Int), toX: Double, toY: Double) {
        c.pointerDown(x: x(c, from.0), y: rowY(c, from.1))
        c.pointerMove(x: x(c, from.0) + 10, y: rowY(c, from.1))
        c.pointerMove(x: toX, y: toY)
    }
    func drag(_ c: TimelineController, from: (Double, Int), toX: Double, toY: Double, alt: Bool = false) {
        c.dragSwapDisabled = alt; defer { c.dragSwapDisabled = false }
        press(c, from: from, toX: toX, toY: toY); c.pointerUp(x: toX, y: toY)
    }
    func displaced(_ c: TimelineController) -> [String]? { c.view.displacedDrop?.clipIds }

    // MARK: Swap

    func testDropOntoABusyRowSwapsTheTwoClipsAsOneUndoStep() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        let before = e.document
        press(c, from: (1, 0), toX: x(c, 1) + 100, toY: rowY(c, 1))   // A to 1s..6s on B's row
        XCTAssertEqual(c.view.dropTarget, .row(1))
        XCTAssertEqual(displaced(c), ["B"]); XCTAssertEqual(c.view.displacedDrop?.target, .row(0), "B's slot is A's origin row")
        c.pointerUp(x: x(c, 1) + 100, y: rowY(c, 1))
        XCTAssertEqual(layout(e), [["B"], ["A"]])
        XCTAssertEqual(start(e, "A"), 30, "A takes B's row at the drop time")
        XCTAssertEqual(start(e, "B"), 0, "B keeps its time")
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Swap clips")
        XCTAssertEqual(c.view.selection, ["A"])
        // Preview/export stacking follows the rows: B is on the top row now, so it draws over A.
        let layers = nativeTrackStackingLayers(e.document.sequence.tracks)
        let rowOf = { (id: String) in e.document.sequence.tracks.firstIndex { $0.clips.contains { $0.id == id } }! }
        XCTAssertGreaterThan(layers[rowOf("B")], layers[rowOf("A")])
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before, "one undo restores both clips")
        XCTAssertTrue(e.redo()); XCTAssertEqual(layout(e), [["B"], ["A"]]); XCTAssertEqual(e.redoStack.count, 0)
    }

    func testSwapAcrossNonAdjacentRowsLeavesTheRowsBetween() throws {
        let (c, e) = try make([[("A", 0, 150)], [("M", 600, 60)], [("B", 60, 60)]])
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 2))
        XCTAssertEqual(layout(e), [["B"], ["M"], ["A"]])
        XCTAssertEqual(start(e, "B"), 60)
    }

    func testEveryOverlappedClipIsDisplacedTogether() throws {
        let (c, e) = try make([[("A", 0, 300)], [("B", 0, 90), ("C", 150, 90), ("D", 600, 30)]])
        press(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertEqual(displaced(c).map(Set.init), ["B", "C"])
        c.pointerUp(x: x(c, 1), y: rowY(c, 1))
        XCTAssertEqual(layout(e), [["B", "C"], ["A", "D"]], "D does not overlap A and stays")
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Swap clips")
    }

    // MARK: Fallback when B does not fit A's row

    func testDisplacedClipThatDoesNotFitTakesTheNearestFreeRow() throws {
        // B (0..10s) collides with X on A's row; row 2 is free for 0..10s.
        let (c, e) = try make([[("A", 0, 150), ("X", 200, 100)], [("B", 0, 300)], [("C", 400, 60)]])
        press(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertEqual(c.view.displacedDrop?.target, .row(2))
        c.pointerUp(x: x(c, 1), y: rowY(c, 1))
        XCTAssertEqual(layout(e), [["X"], ["A"], ["B", "C"]])
        XCTAssertEqual(start(e, "B"), 0); XCTAssertEqual(start(e, "A"), 0)
        XCTAssertEqual(e.undoLabel, "Swap clips")
    }

    func testDisplacedClipWithNoFreeRowGetsANewTrackBelowTheAimedRow() throws {
        let (c, e) = try make([[("A", 0, 150), ("X", 200, 100)], [("B", 0, 300)], [("C", 100, 60)]])
        let before = e.document
        press(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertEqual(c.view.displacedDrop?.target, .insert(2))
        c.pointerUp(x: x(c, 1), y: rowY(c, 1))
        XCTAssertEqual(layout(e), [["X"], ["A"], ["B"], ["C"]])
        XCTAssertEqual(e.tracks[2].kind, "video")
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Swap clips")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before, "the new track and both moves undo together")
    }

    // MARK: Option/Alt

    func testOptionHeldKeepsTheOriginalPlacement() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)], [("C", 0, 150)]])
        let before = e.document
        drag(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1), alt: true)
        XCTAssertEqual(e.document, before, "own row is the nearest free one: nothing moves")
        drag(c, from: (1, 0), toX: x(c, 1) + 600, toY: rowY(c, 1), alt: true)
        XCTAssertEqual(layout(e), [["B", "A"], ["C"]], "a free span on the aimed row is a plain move")
        XCTAssertEqual(e.undoLabel, "Move clip")
    }

    func testTogglingOptionMidDragUpdatesTheLandingLive() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        var redraws = 0; c.needsDisplay = { redraws += 1 }
        // A to 2s..7s on B's row: with the swap, B's slot is on row 0 at 0..5s; without, A's own row at 2s.
        press(c, from: (1, 0), toX: x(c, 3), toY: rowY(c, 1))
        #if os(Linux)   // CairoImageTarget is the Linux canvas backend; the pixel checks run there only
        func render() -> (r: UInt8, g: UInt8, b: UInt8) {
            let t = CairoImageTarget(width: 1266, height: 400); c.view.draw(t.canvas, size: CanvasSize(1266, 400))
            let p = t.pixel(Int(x(c, 0.5)), Int(rowY(c, 0))); return (p.r, p.g, p.b)
        }
        #endif
        XCTAssertEqual(c.view.dropTarget, .row(1)); XCTAssertEqual(displaced(c), ["B"])
        #if os(Linux)
        let swapPixel = render()
        #endif
        let n = redraws
        c.dragSwapDisabled = true   // Option pressed, pointer still
        XCTAssertGreaterThan(redraws, n, "the modifier alone redraws the preview")
        XCTAssertEqual(c.view.dropTarget, .row(0)); XCTAssertNil(c.view.displacedDrop)
        #if os(Linux)
        let plainPixel = render()
        XCTAssertGreaterThan(Int(swapPixel.g) - Int(swapPixel.r), Int(plainPixel.g) - Int(plainPixel.r) + 4,
                             "the mint second slot shows where B goes only while swapping")
        #endif
        c.dragSwapDisabled = false  // released again
        XCTAssertEqual(c.view.dropTarget, .row(1)); XCTAssertEqual(displaced(c), ["B"])
        c.dragSwapDisabled = true; c.dragSwapDisabled = false
        c.pointerUp(x: x(c, 3), y: rowY(c, 1))
        XCTAssertEqual(layout(e), [["B"], ["A"]]); XCTAssertEqual(start(e, "A"), 60)
        XCTAssertEqual(e.undoStack.count, 1)
        // Option held at release: the original placement (A slides on its own row).
        XCTAssertTrue(e.undo())
        press(c, from: (1, 0), toX: x(c, 3), toY: rowY(c, 1)); c.dragSwapDisabled = true
        c.pointerUp(x: x(c, 3), y: rowY(c, 1)); c.dragSwapDisabled = false
        XCTAssertEqual(layout(e), [["A"], ["B"]]); XCTAssertEqual(start(e, "A"), 60); XCTAssertEqual(e.undoLabel, "Move clip")
    }

    // MARK: Selections, locks, kinds, own row

    func testMultiSelectionNeverSwaps() throws {
        let (c, e) = try make([[("A", 0, 150), ("X", 300, 60)], [("B", 0, 150)]])
        let before = e.document
        c.view.selection = ["A", "X"]
        press(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertNil(c.view.displacedDrop)
        c.pointerUp(x: x(c, 1), y: rowY(c, 1))
        XCTAssertEqual(e.document, before, "the rigid formation would land on B: nothing moves")
        // A free span still moves the formation as before.
        c.view.selection = ["A", "X"]
        drag(c, from: (1, 0), toX: x(c, 1) + 600, toY: rowY(c, 1))
        XCTAssertEqual(layout(e), [["B", "A", "X"]]); XCTAssertEqual(e.undoLabel, "Move clips")
    }

    func testLockedRowsRefuseTheSwap() throws {
        let (c, e) = try make([[("A", 0, 150)], [("B", 0, 150)], [("C", 0, 150)]])
        XCTAssertTrue(e.setTrackLocked("track:1", true))
        let before = e.document
        press(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertNil(c.view.displacedDrop); XCTAssertEqual(c.view.dropTarget, .row(0))
        c.pointerUp(x: x(c, 1), y: rowY(c, 1))
        XCTAssertEqual(e.document, before, "a locked clip is never displaced")
        // A locked row never receives displaced clips: B' cannot fall back onto the locked row, so it gets a new track.
        let (c2, e2) = try make([[("A", 0, 150), ("X", 200, 100)], [("B", 0, 300)], [("L", 900, 30)]])
        XCTAssertTrue(e2.setTrackLocked("track:2", true))
        drag(c2, from: (1, 0), toX: x(c2, 1), toY: rowY(c2, 1))
        XCTAssertEqual(layout(e2), [["X"], ["A"], ["B"], ["L"]])
        XCTAssertEqual(e2.tracks[3].locked, true)
    }

    func testIncompatibleKindsDoNotSwap() throws {
        let (c, e) = try make([[("V", 0, 150)], [("M", 0, 150)]], audioTrack: 1)
        let before = e.document
        press(c, from: (1, 0), toX: x(c, 1), toY: rowY(c, 1))
        XCTAssertNil(c.view.displacedDrop, "a video clip does not swap onto an audio row")
        c.pointerUp(x: x(c, 1), y: rowY(c, 1))
        XCTAssertEqual(e.document, before)
    }

    func testOwnRowAndBoundaryDropsNeverSwap() throws {
        let (c, e) = try make([[("A", 0, 150), ("B", 300, 150)], [("C", 0, 150)]])
        press(c, from: (1, 0), toX: x(c, 1) + 900, toY: rowY(c, 0))   // A onto B on its own row
        XCTAssertNil(c.view.displacedDrop)
        c.pointerUp(x: x(c, 1) + 900, y: rowY(c, 0))
        XCTAssertNotEqual(e.undoLabel, "Swap clips")
        let (c2, e2) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        drag(c2, from: (1, 0), toX: x(c2, 1), toY: c2.view.boundaryTop(2) + 6)   // past the bottom: a new track
        XCTAssertEqual(layout(e2), [["B"], ["A"]]); XCTAssertEqual(e2.undoLabel, "Move clip to new track")
    }

    // MARK: Pure plan

    func testPlanMoveSwapFlag() throws {
        let (_, e) = try make([[("A", 0, 150)], [("B", 0, 150)]])
        let rows = e.tracks.map(\.id)
        let on = e.planMove(clipIds: ["A"], grabbed: "A", deltaFrames: 0, rows: rows, desiredRow: 1, insertRow: nil, preferInsertAbove: false, swap: true)
        XCTAssertEqual(on.displaced, ["B"]); XCTAssertEqual(on.displacedTarget, .row(0)); XCTAssertEqual(on.target, .row(1)); XCTAssertTrue(on.isSwap)
        let off = e.planMove(clipIds: ["A"], grabbed: "A", deltaFrames: 0, rows: rows, desiredRow: 1, insertRow: nil, preferInsertAbove: false)
        XCTAssertFalse(off.isSwap); XCTAssertEqual(off.target, .row(0))
    }
}
