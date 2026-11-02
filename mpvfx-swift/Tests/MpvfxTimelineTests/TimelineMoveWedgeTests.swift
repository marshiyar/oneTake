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
// Issue #274 A3: the In and Out wedges at a clip's ends; dragging the inner edge sets the length a frame at a time and is
// one undo step; nothing is written until the button is released.
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxTimeline

internal final class TimelineMoveWedgeTests: XCTestCase {
    private func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1400, 600)
        return (c, e)
    }

    private func row(_ c: TimelineController, _ id: String) throws -> Int { try XCTUnwrap(c.clip(id)).row }
    private func handle(_ c: TimelineController, _ id: String, _ edge: NativeMoveEdge) throws -> CanvasRect {
        let (row, clip) = try XCTUnwrap(c.clip(id))
        return try XCTUnwrap(c.view.wedgeHandle(track: row, clip, edge))
    }

    internal func testAClipShowsAWedgeOnlyForTheMovesItHas() throws {
        let (c, e) = try make()
        let (r, plain) = try XCTUnwrap(c.clip("natural"))
        XCTAssertNil(c.view.wedgeHandle(track: r, plain, .in))
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .slide, frames: 9)))
        c.reload(from: e)
        let (_, moved) = try XCTUnwrap(c.clip("natural"))
        XCTAssertEqual(moved.moveInSeconds, 9 / e.fps, accuracy: 1e-9)
        XCTAssertEqual(moved.moveOutSeconds, 0)
        XCTAssertNotNil(c.view.wedgeHandle(track: r, moved, .in))
        XCTAssertNil(c.view.wedgeHandle(track: r, moved, .out))
    }

    internal func testDraggingTheInnerEdgeSetsTheLengthFrameByFrameAsOneUndoStep() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .slide, frames: 9)))
        c.reload(from: e)
        let depth = e.undoStack.count, before = e.document
        let grab = try handle(c, "natural", .in)
        c.pointerDown(x: grab.centerX, y: grab.centerY)
        XCTAssertEqual(c.view.wedgeDrag?.frames, 9)
        let (_, clip) = try XCTUnwrap(c.clip("natural"))
        for frames in [12, 15, 20] {
            c.pointerMove(x: c.view.x(for: clip.start + Double(frames) / e.fps), y: grab.centerY)
            XCTAssertEqual(c.view.wedgeDrag?.frames, frames)
            XCTAssertEqual(e.document, before, "nothing is written while dragging")
        }
        c.pointerUp(x: c.view.x(for: clip.start + 20 / e.fps), y: grab.centerY)
        XCTAssertNil(c.view.wedgeDrag)
        XCTAssertEqual(e.clipMoves(clipId: "natural")?.inMove?.frames, 20)
        XCTAssertEqual(e.undoStack.count, depth + 1, "one undo step for the whole drag")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.clipMoves(clipId: "natural")?.inMove?.frames, 9)
    }

    internal func testAnOutWedgeDragsFromTheClipsEndAndIsKeptWithinTheClip() throws {
        let (c, e) = try make()   // a 30-frame clip
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .rise, frames: 10)))
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .out, NativeEdgeMove(kind: .drop, frames: 6)))
        c.reload(from: e)
        let grab = try handle(c, "natural", .out)
        let (_, clip) = try XCTUnwrap(c.clip("natural"))
        c.pointerDown(x: grab.centerX, y: grab.centerY)
        c.pointerMove(x: c.view.x(for: clip.end - 12 / e.fps), y: grab.centerY)
        XCTAssertEqual(c.view.wedgeDrag?.frames, 12)
        c.pointerMove(x: c.view.x(for: clip.start), y: grab.centerY)
        XCTAssertEqual(c.view.wedgeDrag?.frames, 20, "the In keeps its 10 of the 30 frames")
        c.pointerMove(x: c.view.x(for: clip.end + 5), y: grab.centerY)
        XCTAssertEqual(c.view.wedgeDrag?.frames, 1, "at least one frame")
        c.pointerMove(x: c.view.x(for: clip.end - 8 / e.fps), y: grab.centerY)
        c.pointerUp(x: c.view.x(for: clip.end - 8 / e.fps), y: grab.centerY)
        XCTAssertEqual(e.clipMoves(clipId: "natural")?.outMove?.frames, 8)
        XCTAssertEqual(e.clipMoves(clipId: "natural")?.inMove?.frames, 10)
    }

    internal func testReleasingWithoutChangingTheLengthRecordsNothingAndALockedTrackHasNoHandle() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .slide, frames: 9)))
        c.reload(from: e)
        let depth = e.undoStack.count
        let grab = try handle(c, "natural", .in)
        c.pointerDown(x: grab.centerX, y: grab.centerY)
        c.pointerUp(x: grab.centerX, y: grab.centerY)
        XCTAssertEqual(e.undoStack.count, depth)
        XCTAssertTrue(e.setTrackLocked("v1", true))
        c.reload(from: e)
        let other = try handle(c, "natural", .in)
        c.pointerDown(x: other.centerX, y: other.centerY)
        XCTAssertNil(c.view.wedgeDrag, "a locked track's wedge cannot be grabbed")
    }
}
