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
import MpvfxPlayer
@testable import MpvfxDesktop

/// The host cursor for the preview stage: each stage shape maps to a system cursor, a resize arrow follows the
/// handle's on-screen direction, and the router asks the stage only over the player.
final class StageHostCursorTests: XCTestCase {
    func testStageShapesMapToSystemCursors() {
        XCTAssertEqual(EditorShellRouter.Cursor(stage: .arrow), .arrow)
        XCTAssertEqual(EditorShellRouter.Cursor(stage: .rotate), .arrow, "no system rotate cursor: the stage draws its glyph")
        XCTAssertEqual(EditorShellRouter.Cursor(stage: .move), .move)
        XCTAssertEqual(EditorShellRouter.Cursor(stage: .anchor), .crosshair)
        XCTAssertEqual(EditorShellRouter.Cursor(stage: .notAllowed), .notAllowed)
    }

    func testResizeArrowsFollowTheHandleDirectionOnScreen() {
        let cases: [(Double, EditorShellRouter.Cursor)] = [
            (0, .columnResize), (180, .columnResize), (-180, .columnResize), (20, .columnResize),
            (45, .resizeNWSE), (90, .rowResize), (135, .resizeNESW), (-45, .resizeNESW),
            (90 + 90, .columnResize), (45 + 90, .resizeNESW), (360 + 91, .rowResize), (.nan, .columnResize),
        ]
        for (degrees, want) in cases {
            XCTAssertEqual(EditorShellRouter.Cursor(stage: .resize(degrees: degrees)), want, "\(degrees)°")
        }
    }

    func testEveryCursorHasAGdkNameAndAWindowsId() {
        let all: [EditorShellRouter.Cursor] = [.arrow, .columnResize, .rowResize, .move, .resizeNWSE, .resizeNESW, .crosshair, .notAllowed]
        XCTAssertEqual(Set(all.map(\.cssName)).count, all.count)
        XCTAssertEqual(Set(all.map(\.windowsCursorId)).count, all.count)
        XCTAssertEqual(EditorShellRouter.Cursor.move.cssName, "move")
        XCTAssertEqual(EditorShellRouter.Cursor.resizeNWSE.windowsCursorId, 32642)
    }

    func testWin32RefreshPreservesFrameAndOtherWindowCursorsUnlessCaptured() {
        func allows(_ x: Double, _ y: Double, ownWindow: Bool = true, captured: Bool = false) -> Bool {
            HostCursorRefreshPolicy.shouldRefresh(ownsCapture: captured, ownsWindow: ownWindow,
                                                  x: x, y: y, width: 300, height: 200)
        }
        XCTAssertTrue(allows(0, 0))
        XCTAssertTrue(allows(299, 199))
        for (x, y) in [(40.0, -20.0), (-1, 40), (300, 40), (40, 200)] {
            XCTAssertFalse(allows(x, y), "title bar and resize borders keep their native cursor")
            XCTAssertTrue(allows(x, y, ownWindow: false, captured: true), "capture owns the cursor outside the client")
        }
        XCTAssertFalse(allows(40, 40, ownWindow: false))
    }

    var dirs: [String] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) } }

    func makeRouter() throws -> (EditorSession, EditorShellRouter, EditorShellFrames) {
        let d = NSTemporaryDirectory() + "mpvfx-stage-cursor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        s.audio?.stop()
        let router = s.installShell(userData: d) {}
        router.resized(CanvasSize(1440, 900))
        router.stageCursor = { .move }
        let t = CairoImageTarget(width: 1440, height: 900)   // a draw lays out the dock's hit areas
        router.draw(t.canvas, size: CanvasSize(1440, 900))
        return (s, router, try XCTUnwrap(router.frames))
    }

    /// Codex review on #340: a drag the player holds crossing a seam kept showing the seam's resize arrow.
    func testAPlayerDragOverASeamKeepsTheStageCursor() throws {
        let (_, router, f) = try makeRouter()
        let seam = try XCTUnwrap(router.dock.geometry.splitters.first { $0.axis == .row && $0.index == 0 }).hit
        let seamPoint = CanvasPoint(seam.x + seam.width / 2, f.player.y + f.player.height / 2)
        XCTAssertEqual(router.cursor(at: seamPoint.x, seamPoint.y), .columnResize, "hovering the seam: resize arrow")
        router.pointerDown(x: f.player.x + 40, y: f.player.y + 40, shift: false)
        XCTAssertEqual(router.cursor(at: seamPoint.x, seamPoint.y), .move, "the player holds the pointer: its cursor")
        router.pointerUp(x: seamPoint.x, y: seamPoint.y)
        XCTAssertEqual(router.cursor(at: seamPoint.x, seamPoint.y), .columnResize)
    }

    /// Codex review on #340: with Settings open the stage and seam cursors showed through the card.
    func testTheSettingsCardShowsTheArrowOverEverything() throws {
        let (s, router, f) = try makeRouter()
        let seam = try XCTUnwrap(router.dock.geometry.splitters.first { $0.axis == .row && $0.index == 0 }).hit
        s.showSettings()
        XCTAssertEqual(router.cursor(at: f.player.x + f.player.width / 2, f.player.y + f.player.height / 2), .arrow)
        XCTAssertEqual(router.cursor(at: seam.x + seam.width / 2, f.player.y + 10), .arrow)
    }

    func testTheRouterAsksTheStageOnlyOverThePlayer() throws {
        let (_, router, f) = try makeRouter()
        let player = CanvasPoint(f.player.x + f.player.width / 2, f.player.y + f.player.height / 2)
        let timeline = CanvasPoint(f.timeline.x + f.timeline.width / 2, f.timeline.y + f.timeline.height / 2)
        XCTAssertEqual(router.cursor(at: player.x, player.y), .move, "over the player: the stage's cursor")
        XCTAssertEqual(router.cursor(at: timeline.x, timeline.y), .arrow, "elsewhere: the arrow")
    }
}
