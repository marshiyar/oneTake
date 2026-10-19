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
import OneTakeKeyframes

/// Keyframe diamonds on the timeline (TimelineClipDiamonds / useTimelineKeyframeHandlers / keyframeDrag /
/// nudgeSelectedKeyframes / deleteSelectedKeyframes): click select, ⇧ multi-select, marquee, drag-to-retime with
/// the neighbour and clip clamps, one undo step per drag, and the diamond winning over the clip drag.
final class TimelineKeyframeSelectionTests: XCTestCase {
    /// Demo document: clip:a is 0..180 frames (30 fps) on row 1, keyed (position) at 0, 2 and 4 s.
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 400)
        c.snapEnabled = false
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        c.view.expandedClips = []   // diamonds on the clip bar unless a test expands the lanes
        c.playback.seek(5); c.syncFromPlayback()
        return (c, e)
    }

    func barY(_ c: TimelineController) -> Double { c.view.rowTop(1) + c.view.trackHeight / 2 }
    func x(_ c: TimelineController, _ t: Double) -> Double { c.view.x(for: t) }
    func frames(_ e: TimelineEditor) -> [Double] {
        Array(Set(e.clip("clip:a")!.clip.parameterTracks.flatMap { $0.keyframes.map(\.frame) })).sorted()
    }
    func selectedFrames(_ c: TimelineController) -> [Double] { Array(Set(c.view.selectedKeyframes.map(\.frame))).sorted() }
    func click(_ c: TimelineController, _ px: Double, _ py: Double, shift: Bool = false) {
        c.pointerDown(x: px, y: py, shift: shift); c.pointerUp(x: px, y: py)
    }
    func drag(_ c: TimelineController, from: Double, to: Double, y: Double, shift: Bool = false) {
        c.pointerDown(x: from, y: y, shift: shift)
        c.pointerMove(x: from + 5, y: y)
        c.pointerMove(x: to, y: y)
        c.pointerUp(x: to, y: y)
    }

    func testPlainClickSelectsTheKeyframeItsClipAndSeeks() throws {
        let (c, e) = try make()
        XCTAssertEqual(c.view.keyframeHit(x: x(c, 2), y: barY(c))?.frame, 60)
        let undoCount = e.undoStack.count
        click(c, x(c, 2) + 3, barY(c))
        XCTAssertEqual(selectedFrames(c), [60])
        XCTAssertTrue(c.view.selectedKeyframes.allSatisfy { $0.clipId == "clip:a" })
        XCTAssertEqual(c.view.selection, ["clip:a"])
        XCTAssertEqual(c.playback.currentTime, 2, accuracy: 1e-9, "clicking a diamond seeks the playhead to it")
        XCTAssertEqual(e.undoStack.count, undoCount, "a click edits nothing")
        // Another plain click replaces the selection.
        click(c, x(c, 4), barY(c))
        XCTAssertEqual(selectedFrames(c), [120])
        // A click on empty space clears it.
        click(c, x(c, 11.5), c.view.rowTop(0) + c.view.trackHeight / 2)
        XCTAssertTrue(c.view.selectedKeyframes.isEmpty)
    }

    func testShiftClickTogglesAMultiSelection() throws {
        let (c, _) = try make()
        click(c, x(c, 2), barY(c))
        click(c, x(c, 4), barY(c), shift: true)
        XCTAssertEqual(selectedFrames(c), [60, 120])
        click(c, x(c, 0) + 2, barY(c), shift: true)
        XCTAssertEqual(selectedFrames(c), [0, 60, 120])
        click(c, x(c, 4), barY(c), shift: true)
        XCTAssertEqual(selectedFrames(c), [0, 60], "⇧-click on a selected key removes it")
    }

    func testMarqueeSelectsTheKeysItCovers() throws {
        let (c, _) = try make()
        let y0 = c.view.rowTop(0) + c.view.trackHeight / 2
        c.pointerDown(x: x(c, 4.6), y: y0)
        c.pointerMove(x: x(c, 3.8), y: barY(c) + 4)
        XCTAssertEqual(selectedFrames(c), [120])
        XCTAssertEqual(c.view.selection, [], "a box holding keys leaves the clip selection alone")
        c.pointerUp(x: x(c, 3.8), y: barY(c) + 4)
        XCTAssertEqual(selectedFrames(c), [120])
    }

    func testDragRetimesOneKeyframeAsOneUndoStep() throws {
        let (c, e) = try make()
        let before = e.document, undoCount = e.undoStack.count
        c.pointerDown(x: x(c, 2), y: barY(c))
        c.pointerMove(x: x(c, 2) + 5, y: barY(c))
        c.pointerMove(x: x(c, 3), y: barY(c))
        XCTAssertEqual(c.view.keyframeDrag?.deltaFrames, 30, "the diamond follows the pointer before release")
        XCTAssertEqual(frames(e), [0, 60, 120], "nothing is written until release")
        XCTAssertEqual(c.view.diamondFrames(c.view.tracks[1].clips[0], group: nil), [0, 90, 120])
        c.pointerUp(x: x(c, 3), y: barY(c))
        XCTAssertEqual(frames(e), [0, 90, 120])
        XCTAssertEqual(e.undoStack.count, undoCount + 1); XCTAssertEqual(e.undoLabel, "Move keyframe")
        XCTAssertEqual(selectedFrames(c), [90], "the selection follows the moved key")
        XCTAssertNil(c.view.keyframeDrag)
        XCTAssertEqual(e.clip("clip:a")?.clip.startFrame, 0, "the clip did not move")
        XCTAssertTrue(e.undo()); XCTAssertEqual(frames(e), [0, 60, 120])
        XCTAssertEqual(e.document.sequence, before.sequence, "one undo restores the authored frames")
        XCTAssertTrue(e.redo()); XCTAssertEqual(frames(e), [0, 90, 120])
    }

    func testDragIsClampedToNeighboursAndTheClip() throws {
        let (c, e) = try make()
        drag(c, from: x(c, 2), to: x(c, 5.5), y: barY(c))
        XCTAssertEqual(frames(e), [0, 119, 120], "stops one frame before the next key, never on it")
        drag(c, from: x(c, 4), to: x(c, 9), y: barY(c))
        XCTAssertEqual(frames(e), [0, 119, 179], "stops on the clip's last frame")
        drag(c, from: x(c, 0) + 1, to: x(c, 0) - 80, y: barY(c))
        XCTAssertEqual(frames(e), [0, 119, 179], "the first key cannot leave the clip start")
        drag(c, from: x(c, 119.0 / 30), to: x(c, 4.5), y: barY(c))
        XCTAssertEqual(frames(e), [0, 135, 179], "free again between its new neighbours")
        let undo = e.undoStack.count
        drag(c, from: x(c, 0) + 1, to: x(c, 0) - 40, y: barY(c))
        XCTAssertEqual(e.undoStack.count, undo, "a clamped no-op drag records nothing")
    }

    func testDraggingASelectedKeyMovesTheWholeSelection() throws {
        let (c, e) = try make()
        click(c, x(c, 2), barY(c)); click(c, x(c, 4), barY(c), shift: true)
        drag(c, from: x(c, 2), to: x(c, 2.5), y: barY(c))
        XCTAssertEqual(frames(e), [0, 75, 135])
        XCTAssertEqual(selectedFrames(c), [75, 135])
        drag(c, from: x(c, 2.5), to: x(c, 8), y: barY(c))
        XCTAssertEqual(frames(e), [0, 119, 179], "the group stops where its last key meets the clip end")
        XCTAssertTrue(e.undo()); XCTAssertEqual(frames(e), [0, 75, 135], "each group drag is one undo step")
    }

    func testDragSnapsToThePlayheadWhenSnappingIsOn() throws {
        let (c, e) = try make()
        c.snapEnabled = true
        c.playback.seek(3); c.syncFromPlayback()
        drag(c, from: x(c, 2), to: x(c, 3) + 4, y: barY(c))
        XCTAssertEqual(frames(e), [0, 90, 120])
    }

    func testKeyframeDragWinsOverClipDragAndTrim() throws {
        let (c, e) = try make()
        // Clip already selected: the key at frame 0 sits inside the start trim handle.
        c.view.selection = ["clip:a"]
        drag(c, from: x(c, 0) + 2, to: x(c, 1) + 2, y: barY(c))
        XCTAssertEqual(e.clip("clip:a")?.clip.startFrame, 0, "no trim"); XCTAssertEqual(e.clip("clip:a")?.clip.durationFrames, 180)
        XCTAssertEqual(frames(e), [30, 60, 120])
        // Mid-clip diamond: retime, no clip move; between diamonds the body still moves the clip.
        drag(c, from: x(c, 4), to: x(c, 4.5), y: barY(c))
        XCTAssertEqual(e.clip("clip:a")?.clip.startFrame, 0)
        XCTAssertEqual(frames(e), [30, 60, 135])
        drag(c, from: x(c, 3), to: x(c, 3) + 60, y: barY(c))
        XCTAssertNotEqual(e.clip("clip:a")?.clip.startFrame, 0, "the clip body away from diamonds still drags the clip")
    }

    func testLaneDiamondsSelectAndDrag() throws {
        let (c, e) = try make()
        c.view.expandedClips = ["clip:a"]
        let laneY = c.view.rowTop(1) + c.view.trackHeight + TimelineLayout.laneHeight / 2
        let hit = try XCTUnwrap(c.view.keyframeHit(x: x(c, 2), y: laneY))
        XCTAssertEqual(hit.lane, 0); XCTAssertEqual(hit.frame, 60)
        click(c, x(c, 2), laneY)
        XCTAssertEqual(selectedFrames(c), [60])
        XCTAssertTrue(c.view.isDiamondSelected(c.view.tracks[1].clips[0], group: nil, frame: 60), "the clip-bar diamond shows the same key selected")
        drag(c, from: x(c, 2), to: x(c, 1), y: laneY)
        XCTAssertEqual(frames(e), [0, 30, 120])
    }

    func testDeleteAndNudgeActOnSelectedKeysNotTheClip() throws {
        let (c, e) = try make()
        click(c, x(c, 2), barY(c))
        XCTAssertTrue(c.keyDown(EditorKey(.char("."))))
        XCTAssertEqual(frames(e), [0, 61, 120]); XCTAssertEqual(e.undoLabel, "Nudge keyframes")
        XCTAssertTrue(c.keyDown(EditorKey(.char(","), shift: true)))
        XCTAssertEqual(frames(e), [0, 51, 120])
        XCTAssertTrue(c.keyDown(EditorKey(.delete)))
        XCTAssertEqual(frames(e), [0, 120]); XCTAssertEqual(e.undoLabel, "Delete keyframes")
        XCTAssertNotNil(e.clip("clip:a"), "Delete removed the keys, not the clip")
        XCTAssertTrue(c.view.selectedKeyframes.isEmpty)
    }
}
