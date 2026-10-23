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
import Foundation
import XCTest
import MpvfxCanvas
import OneTakeKeyframes
@testable import MpvfxTimeline

final class TimelineClipMenuOverflowTests: XCTestCase {
    func controller() throws -> TimelineController {
        let json = TimelineChunk6Tests.json
        let editor = try TimelineEditor(json: json, engine: KeyframeRuntime())
        let controller = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: editor)
        controller.viewport = CanvasSize(600, 300)
        controller.openClipMenu("clip:a", x: 580, y: 250)
        return controller
    }

    func testLongMenuFitsTheTimelinePaneAndHiddenRowsCannotBeClicked() throws {
        let c = try controller(), menu = try XCTUnwrap(c.view.clipMenu)
        XCTAssertGreaterThan(menu.contentHeight, 300)
        XCTAssertLessThanOrEqual(menu.rect.maxY, c.viewport.height)
        XCTAssertLessThanOrEqual(menu.rect.maxX, c.viewport.width)
        let row = try XCTUnwrap(menu.itemRects().first { $0.0.action == .delete }).1
        XCTAssertGreaterThan(row.y, menu.rect.maxY)
        XCTAssertNil(menu.item(atX: row.x + 10, y: row.y + 10), "an invisible overflow row is not a hit target")
    }

    func testWheelReachesDeleteWithoutScrollingTheTimeline() throws {
        let c = try controller()
        let beforeX = c.view.scrollX, beforeY = c.view.scrollY
        c.scroll(dx: 0, dy: 10000, x: 590, ctrl: false, shift: false)
        let menu = try XCTUnwrap(c.view.clipMenu)
        XCTAssertEqual(menu.scrollOffset, menu.maximumScroll)
        XCTAssertEqual(c.view.scrollX, beforeX)
        XCTAssertEqual(c.view.scrollY, beforeY)
        let row = try XCTUnwrap(menu.itemRects().first { $0.0.action == .delete }).1
        XCTAssertGreaterThanOrEqual(row.y, menu.rect.y)
        XCTAssertLessThanOrEqual(row.maxY, menu.rect.maxY)
        XCTAssertEqual(menu.item(atX: row.x + 10, y: row.y + 10)?.action, .delete)
    }

    func testKeyboardNavigationScrollsToDeleteAndActivatesIt() throws {
        let c = try controller()
        XCTAssertTrue(c.keyDown(EditorKey(.end)))
        XCTAssertEqual(c.view.clipMenu?.hovered, .delete)
        XCTAssertGreaterThan(c.view.clipMenu?.scrollOffset ?? 0, 0)
        let menu = try XCTUnwrap(c.view.clipMenu)
        let row = try XCTUnwrap(menu.itemRects().first { $0.0.action == .delete }).1
        XCTAssertGreaterThanOrEqual(row.y, menu.rect.y)
        XCTAssertLessThanOrEqual(row.maxY, menu.rect.maxY)
        XCTAssertTrue(c.keyDown(EditorKey(.enter)))
        XCTAssertNil(c.view.clipMenu)
        XCTAssertNil(c.editor?.clip("clip:a"))
        XCTAssertTrue(c.editor?.canUndo ?? false)
    }

    func testKeyboardSkipsDisabledRowsAndEscapeClosesTheMenu() throws {
        let c = try controller()
        XCTAssertTrue(c.keyDown(EditorKey(.home)))
        XCTAssertEqual(c.view.clipMenu?.hovered, .cut, "Split is disabled at the clip's start")
        XCTAssertTrue(c.keyDown(EditorKey(.down)))
        XCTAssertEqual(c.view.clipMenu?.hovered, .copy)
        XCTAssertTrue(c.keyDown(EditorKey(.down)))
        XCTAssertEqual(c.view.clipMenu?.hovered, .copyGrade, "Paste is disabled with an empty clipboard")
        XCTAssertTrue(c.keyDown(EditorKey(.escape)))
        XCTAssertNil(c.view.clipMenu)
    }
}
