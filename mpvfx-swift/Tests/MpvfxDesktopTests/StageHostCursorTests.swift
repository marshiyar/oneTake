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

    func testTheRouterAsksTheStageOnlyOverThePlayer() throws {
        let d = NSTemporaryDirectory() + "mpvfx-stage-cursor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: d) }
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        s.audio?.stop()
        let router = s.installShell(userData: d) {}
        router.resized(CanvasSize(1440, 900))
        router.stageCursor = { .move }
        let f = try XCTUnwrap(router.frames)
        let player = CanvasPoint(f.player.x + f.player.width / 2, f.player.y + f.player.height / 2)
        let timeline = CanvasPoint(f.timeline.x + f.timeline.width / 2, f.timeline.y + f.timeline.height / 2)
        XCTAssertEqual(router.cursor(at: player.x, player.y), .move, "over the player: the stage's cursor")
        XCTAssertEqual(router.cursor(at: timeline.x, timeline.y), .arrow, "elsewhere: the arrow")
    }
}
