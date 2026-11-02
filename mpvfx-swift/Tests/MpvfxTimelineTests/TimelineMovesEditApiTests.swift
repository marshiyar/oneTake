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
// Issue #274 A3, A4: the move setters are one undo step however many clips they reach; Copy, Paste and Remove moves from
// the clip menu act on the whole selection.
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxTimeline

internal final class TimelineMovesEditApiTests: XCTestCase {
    private func editor() throws -> TimelineEditor { try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime()) }
    private let three: Set<String> = ["natural", "placed", "legacy"]

    internal func testSettingAnInIsOneUndoStepForAnyNumberOfClipsAndRemovingItIsToo() throws {
        let e = try editor()
        let depth = e.undoStack.count
        let slide = NativeEdgeMove(kind: .slide, frames: 10)
        XCTAssertTrue(e.setEdgeMove(clipIds: three, .in, slide))
        XCTAssertEqual(e.undoStack.count, depth + 1)
        XCTAssertEqual(e.undoLabel, "Set move")
        for id in three { XCTAssertEqual(e.clipMoves(clipId: id)?.inMove, slide, id) }
        XCTAssertNil(e.clipMoves(clipId: "full"))
        XCTAssertFalse(e.setEdgeMove(clipIds: three, .in, slide), "the same move is no edit")
        XCTAssertTrue(e.setEdgeMove(clipIds: three, .in, nil))
        for id in three { XCTAssertNil(e.clipMoves(clipId: id), "an empty moves object is not stored: \(id)") }
        XCTAssertEqual(e.undoStack.count, depth + 2)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.clipMoves(clipId: "placed")?.inMove, slide)
    }

    internal func testALoopAndAnOutShareTheClipAndSurviveReopening() throws {
        let e = try editor()
        var out = NativeEdgeMove(kind: .grow, frames: 8)
        out.amount = 30; out.ease = .linear
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .out, out))
        XCTAssertTrue(e.setLoopMove(clipIds: ["natural"], NativeLoopMove(kind: .pulse, periodFrames: 10)))
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(reopened.clipMoves(clipId: "natural")?.outMove, out)
        XCTAssertEqual(reopened.clipMoves(clipId: "natural")?.loop?.kind, .pulse)
    }

    internal func testMovesLongerThanTheClipAreRefusedAndNothingIsRecorded() throws {
        let e = try editor()   // 30-frame clips
        let depth = e.undoStack.count
        XCTAssertTrue(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .rise, frames: 20)))
        XCTAssertFalse(e.setEdgeMove(clipIds: ["natural"], .out, NativeEdgeMove(kind: .drop, frames: 20)), "20 + 20 frames in a 30-frame clip")
        XCTAssertNil(e.clipMoves(clipId: "natural")?.outMove)
        XCTAssertEqual(e.undoStack.count, depth + 1)
        XCTAssertFalse(e.setLoopMove(clipIds: ["natural"], NativeLoopMove(kind: .float, periodFrames: 3)), "an odd period")
    }

    internal func testLockedTracksAreSkipped() throws {
        let e = try editor()
        XCTAssertTrue(e.setTrackLocked("v1", true))
        XCTAssertFalse(e.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .rise, frames: 5)))
        XCTAssertNil(e.clipMoves(clipId: "natural"))
    }

    internal func testPastingFitsTheMovesToEachClipAndAnEmptyPasteRemovesThem() throws {
        let e = try editor()
        let source = NativeClipMoves(in: NativeEdgeMove(kind: .slide, frames: 20), out: NativeEdgeMove(kind: .spin, frames: 20))
        let depth = e.undoStack.count
        XCTAssertTrue(e.setClipMoves(clipIds: three, source))
        XCTAssertEqual(e.undoStack.count, depth + 1, "one undo step for three clips")
        XCTAssertEqual(e.undoLabel, "Paste moves")
        let pasted = try XCTUnwrap(e.clipMoves(clipId: "legacy"))
        XCTAssertEqual((pasted.inMove?.frames ?? 0) + (pasted.outMove?.frames ?? 0), 30, "20 + 20 shrink to fit 30 frames")
        XCTAssertTrue(e.setClipMoves(clipIds: three, nil))
        XCTAssertEqual(e.undoLabel, "Remove moves")
        for id in three { XCTAssertNil(e.clipMoves(clipId: id), id) }
        XCTAssertTrue(e.undo())
        XCTAssertNotNil(e.clipMoves(clipId: "natural"))
    }

    internal func testMovesFromANewerVersionAreLeftAlone() throws {
        let e = try editor()
        var d = e.document
        let future = try NativeJSONValue.parse(#"{"v":2,"in":{"kind":"future","frames":4}}"#).decode(NativeClipMoves.self)
        d.sequence.tracks[0].clips[0].moves = future
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(d, engine: e.engine), engine: e.engine)
        XCTAssertFalse(reopened.setEdgeMove(clipIds: ["natural"], .in, NativeEdgeMove(kind: .rise, frames: 5)))
        XCTAssertFalse(reopened.setClipMoves(clipIds: ["natural"], nil))
        XCTAssertEqual(reopened.clipMoves(clipId: "natural"), future)
        XCTAssertNil(reopened.copyMoves(clipId: "natural"), "unreadable moves are not copied")
    }
}
