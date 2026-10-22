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
// Issue #273 A5: clip edits in the editor keep the moves' rules, each one undo step.
import XCTest
@testable import MpvfxTimeline
import MpvfxShared
import OneTakeKeyframes

final class TimelineMovesEditTests: XCTestCase {
    func editor() throws -> TimelineEditor {
        try TimelineEditor(json: """
        {"schemaVersion":1,"id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"i","kind":"image","name":"i.png","source":"i.png","durationFrames":1}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[
           {"id":"A","assetId":"i","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[],
            "moves":{"v":1,"in":{"kind":"rise","frames":20},"out":{"kind":"drop","frames":25},"loop":{"kind":"float","periodFrames":30}}}]}]}}
        """, engine: try KeyframeRuntime())
    }
    func clips(_ e: TimelineEditor) -> [NativeProjectClip] { e.document.sequence.tracks[0].clips }

    func testA5SplitKeepsInOnTheLeftAndOutOnTheRightAndOneUndoRestoresTheMoves() throws {
        let e = try editor()
        let before = e.document
        XCTAssertTrue(e.split(["A"], atFrame: 50))
        let (left, right) = (clips(e)[0], clips(e)[1])
        XCTAssertEqual(left.moves?.inMove, NativeEdgeMove(kind: .rise, frames: 20)); XCTAssertNil(left.moves?.outMove)
        XCTAssertEqual(right.moves?.outMove, NativeEdgeMove(kind: .drop, frames: 25)); XCTAssertNil(right.moves?.inMove)
        XCTAssertEqual(left.moves?.loop, NativeLoopMove(kind: .float, periodFrames: 30)); XCTAssertEqual(right.moves?.loop, left.moves?.loop)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before, "one undo step restores the clip and its moves exactly")
        XCTAssertTrue(e.redo())
        XCTAssertEqual(clips(e).count, 2)
    }

    func testARetimeThatMakesTheClipTooShortShrinksTheMovesInProportion() throws {
        let e = try editor()
        XCTAssertTrue(e.setPlaybackRate(clipId: "A", 4))
        let m = try XCTUnwrap(clips(e)[0].moves)
        XCTAssertEqual(clips(e)[0].durationFrames, 25)
        XCTAssertEqual(m.inMove?.frames, 11); XCTAssertEqual(m.outMove?.frames, 13, "20:25 over 25 frames, rounded down")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(clips(e)[0].moves?.inMove?.frames, 20)
    }
}
