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
import MpvfxShared
@testable import MpvfxTimeline

final class TimelineSourceNavigationTests: XCTestCase {
    func testClipMenuAndKeyboardRouteBothSourceActionsWithoutEditing() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        var calls: [String] = []
        c.onRevealSource = { id, file in calls.append("\(id):\(file)") }
        let before = e.document, undo = e.undoStack.count
        XCTAssertTrue(c.runClipMenu(.revealSource, clipId: "clip:a"))
        XCTAssertTrue(c.runClipMenu(.showSourceFile, clipId: "clip:a"))
        c.view.selection = ["clip:a"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("f"), ctrl: true, alt: true)))
        XCTAssertTrue(c.keyDown(EditorKey(.char("f"), shift: true, alt: true, meta: true)))
        XCTAssertEqual(calls, ["clip:a:false", "clip:a:true", "clip:a:false", "clip:a:true"])
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.undoStack.count, undo)
        c.view.selection = []
        XCTAssertFalse(c.keyDown(EditorKey(.char("f"), ctrl: true, alt: true)))
    }

    func testMediaClipMenusOfferBothActions() {
        for kind: TimelineClipKind in [.video, .image, .audio] {
            let entries = TimelineClipMenu.entries(kind: kind, splitEnabled: true, thumbnails: true, muted: false, canReattach: false, canDetach: false)
            let actions = entries.compactMap { entry -> TimelineClipMenu.Action? in
                if case .item(let item) = entry { return item.action }; return nil
            }
            XCTAssertTrue(actions.contains(.revealSource))
            XCTAssertTrue(actions.contains(.showSourceFile))
        }
    }
}
