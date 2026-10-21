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

/// F9 easy ease on the timeline's selected keys (⇧F9 in only, ⌘⇧F9 / Ctrl+Shift+F9 out only), as After Effects binds
/// them: each one undo step; without selected keys the key is not taken.
final class TimelineEasyEaseKeyTests: XCTestCase {
    /// clip:a keyed (position) at clip frames 0, 60 and 120; the middle key selected.
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        c.view.selectedKeyframes = [ref(60)]
        return (c, e)
    }
    func ref(_ f: Double) -> TimelineKeyframeRef { TimelineKeyframeRef(clipId: "clip:a", parameterId: TimelineEditor.positionId, frame: f) }
    func points(_ e: TimelineEditor, _ f: Double) -> CubicBezierControlPoints? {
        if case .cubicBezier(let p)? = e.outgoing(ref(f)) { return p }
        return nil
    }

    func testF9EasesBothSidesOfTheSelectedKeys() throws {
        let (c, e) = try make()
        let undo = e.undoStack.count
        XCTAssertTrue(c.keyDown(EditorKey(.function(9))))
        XCTAssertEqual(try XCTUnwrap(points(e, 0)).y2, 1, "the in side (the previous key's curve) eases")
        XCTAssertEqual(try XCTUnwrap(points(e, 60)).y1, 0, "the out side eases")
        XCTAssertEqual(e.undoStack.count, undo + 1); XCTAssertEqual(e.undoLabel, "Easy ease")
    }

    func testShiftF9EasesInOnly() throws {
        let (c, e) = try make()
        XCTAssertTrue(c.keyDown(EditorKey(.function(9), shift: true)))
        XCTAssertNotNil(points(e, 0)); XCTAssertEqual(e.outgoing(ref(60)), .linear)
    }

    func testCommandShiftF9EasesOutOnly() throws {
        for k in [EditorKey(.function(9), shift: true, meta: true), EditorKey(.function(9), shift: true, ctrl: true)] {
            let (c, e) = try make()
            XCTAssertTrue(c.keyDown(k))
            XCTAssertEqual(e.outgoing(ref(0)), .linear); XCTAssertNotNil(points(e, 60))
        }
    }

    func testF9WithoutSelectedKeysIsNotTaken() throws {
        let (c, e) = try make()
        c.view.selectedKeyframes = []
        let before = e.document
        XCTAssertFalse(c.keyDown(EditorKey(.function(9))))
        XCTAssertFalse(c.keyDown(EditorKey(.function(8))), "other function keys are not bound")
        XCTAssertEqual(e.document, before)
    }
}
