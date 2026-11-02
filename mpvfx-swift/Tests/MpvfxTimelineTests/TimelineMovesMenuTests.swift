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
// Issue #274 A4: Copy moves, Paste moves and Remove moves in the clip menu; paste onto three selected clips is one undo step.
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxTimeline

internal final class TimelineMovesMenuTests: XCTestCase {
    private func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1200, 600)
        return (c, e)
    }

    private func item(_ c: TimelineController, _ action: TimelineClipMenu.Action) -> TimelineClipMenu.Item? {
        c.view.clipMenu?.itemRects().map(\.0).first { $0.action == action }
    }

    internal func testTheRowsFollowWhetherThereAreMovesToCopyOrPaste() throws {
        let (c, e) = try make()
        c.openClipMenu("natural", x: 10, y: 10)
        XCTAssertEqual(item(c, .copyMoves)?.label, "Copy moves")
        XCTAssertEqual(item(c, .copyMoves)?.enabled, false, "nothing to copy")
        XCTAssertEqual(item(c, .removeMoves)?.enabled, false)
        XCTAssertEqual(item(c, .pasteMoves)?.enabled, false, "nothing copied")
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .rise, frames: 6)))
        c.openClipMenu("natural", x: 10, y: 10)
        XCTAssertEqual(item(c, .copyMoves)?.enabled, true)
        XCTAssertEqual(item(c, .removeMoves)?.enabled, true)
        XCTAssertNil(item(c, .copyMoves)?.hint, "no chord: Option+Cmd+C and V are Copy and Paste grade")
    }

    internal func testPasteMovesOnThreeSelectedClipsIsOneUndoStepAndRemoveToo() throws {
        let (c, e) = try make()
        var source = NativeEdgeMove(kind: .grow, frames: 9)
        source.amount = 25
        XCTAssertTrue(e.setEdgeMove(clipIds: ["full"], .in, source))
        XCTAssertTrue(c.runClipMenu(.copyMoves, clipId: "full"))
        XCTAssertEqual(c.movesClipboard?.inMove, source)
        c.view.selection = ["natural", "placed", "legacy"]
        c.openClipMenu("placed", x: 10, y: 10)
        XCTAssertEqual(item(c, .pasteMoves)?.enabled, true)
        let depth = e.undoStack.count
        XCTAssertTrue(c.runClipMenu(.pasteMoves, clipId: "placed"))
        XCTAssertEqual(e.undoStack.count, depth + 1, "one undo step for the whole selection")
        for id in ["natural", "placed", "legacy"] { XCTAssertEqual(e.clipMoves(clipId: id)?.inMove, source, id) }
        XCTAssertTrue(c.runClipMenu(.removeMoves, clipId: "placed"))
        XCTAssertEqual(e.undoStack.count, depth + 2)
        for id in ["natural", "placed", "legacy"] { XCTAssertNil(e.clipMoves(clipId: id), id) }
        XCTAssertNotNil(e.clipMoves(clipId: "full"), "the unselected source keeps its moves")
        XCTAssertFalse(c.runClipMenu(.copyMoves, clipId: "natural"), "a clip with no moves copies nothing")
    }

    internal func testAudioClipsHaveNoMovesRows() throws {
        let entries = TimelineClipMenu.entries(kind: .audio, splitEnabled: true, thumbnails: false, muted: false, canReattach: false, canDetach: false)
        let actions = entries.compactMap { entry -> TimelineClipMenu.Action? in if case .item(let i) = entry { return i.action }; return nil }
        XCTAssertFalse(actions.contains(.copyMoves)); XCTAssertFalse(actions.contains(.pasteMoves))
    }
}
