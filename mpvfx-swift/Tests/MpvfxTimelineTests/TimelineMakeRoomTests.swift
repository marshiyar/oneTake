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
import XCTest
import MpvfxCanvas
import OneTakeKeyframes
@testable import MpvfxTimeline

/// The Make room for voice command on the timeline (issue #310): a clip menu row and ⌥⌘D, both only where the host answers.
final class TimelineMakeRoomTests: XCTestCase {
    func make() throws -> TimelineController {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1200, 600)
        return c
    }

    func testTheMenuRowAndTheKeyAppearOnlyWithAHost() throws {
        let c = try make()
        func rows() -> [TimelineClipMenu.Item] { c.view.clipMenu?.itemRects().map(\.0) ?? [] }
        c.openClipMenu("clip:music", x: 10, y: 10)
        XCTAssertFalse(rows().contains { $0.action == .makeRoomForVoice }, "no host, no row")
        XCTAssertFalse(c.keyDown(EditorKey(.char("d"), alt: true, meta: true)))
        var asked = 0
        c.onMakeRoomForVoice = { asked += 1 }
        c.openClipMenu("clip:music", x: 10, y: 10)
        XCTAssertEqual(rows().first { $0.action == .makeRoomForVoice }?.hint, "⌥⌘D")
        XCTAssertEqual(rows().first { $0.action == .makeRoomForVoice }?.label, "Make room for voice…")
        c.view.selection = []
        XCTAssertTrue(c.runClipMenu(.makeRoomForVoice, clipId: "clip:music"))
        XCTAssertEqual(asked, 1); XCTAssertEqual(c.view.selection, ["clip:music"], "the menu's clip is the voice")
        XCTAssertTrue(c.keyDown(EditorKey(.char("d"), alt: true, meta: true)))
        XCTAssertEqual(asked, 2)
        XCTAssertTrue(c.keyDown(EditorKey(.char("d"), meta: true)), "plain ⌘D still duplicates")
        XCTAssertEqual(asked, 2)
    }
}
