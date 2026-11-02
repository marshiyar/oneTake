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
// Issue #322 A2: ⌥⌘G opens the menu for the selection, ⌥ and an arrow move a picture in picture, ⌥⌘[ and ⌥⌘] swap the
// cells, each one undo step; with no layout applied ⌥⌘[ and ⌥⌘] stay the scene-split threshold.
import Foundation
import MpvfxCanvas
import MpvfxPlayer
import MpvfxShared
import MpvfxTimeline
import XCTest

@testable import MpvfxDesktop

final class LayoutMenuSessionTests: XCTestCase {
    private func session() throws -> EditorSession {
        let session = try EditorSession(projectPath: nil, demo: true)
        session.audio?.stop()
        return session
    }

    private func left(_ s: EditorSession, _ id: String) -> Double? {
        guard case .number(let n)? = s.editor.clip(id)?.clip.staticParameters?["layout.left"] else { return nil }
        return n
    }

    func testTheShortcutOpensTheMenuForTheSelectionAndReturnArrangesInOneUndoStep() throws {
        let s = try session()
        XCTAssertTrue(s.layoutKey(EditorKey(.char("g"), alt: true, meta: true)))
        XCTAssertNil(s.player.view.layoutMenu, "nothing is selected: a toast, no menu")
        s.player.view.selectedIds = ["clip:a", "clip:b"]
        XCTAssertTrue(s.layoutKey(EditorKey(.char("g"), alt: true, meta: true)))
        XCTAssertEqual(s.player.view.layoutMenu?.clipCount, 2)
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.layoutKey(EditorKey(.enter)))
        XCTAssertNil(s.player.view.layoutMenu)
        XCTAssertEqual(s.editor.undoStack.count, depth + 1)
        XCTAssertEqual(s.editor.undoLabel, "Arrange layout")
        XCTAssertEqual(s.lastLayout?.layout, .sideBySide)
        XCTAssertEqual(left(s, "clip:a"), 0)
        XCTAssertNotEqual(left(s, "clip:b"), 0)
    }

    func testOptionCmdBracketsSwapTheCellsOfTheLastLayoutAsOneUndoStep() throws {
        let s = try session()
        s.player.view.selectedIds = ["clip:a", "clip:b"]
        _ = s.layoutKey(EditorKey(.char("g"), alt: true, meta: true))
        _ = s.layoutKey(EditorKey(.enter))
        let a = left(s, "clip:a"), b = left(s, "clip:b")
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.layoutKey(EditorKey(.char("]"), alt: true, meta: true)))
        XCTAssertEqual(left(s, "clip:a"), b)
        XCTAssertEqual(left(s, "clip:b"), a)
        XCTAssertEqual(s.editor.undoStack.count, depth + 1)
        XCTAssertTrue(s.layoutKey(EditorKey(.char("["), alt: true, meta: true)))
        XCTAssertEqual(left(s, "clip:a"), a)
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(left(s, "clip:a"), b)
    }

    func testWithoutALayoutTheBracketsAreNotTakenAndTheArrowsAreNotEither() throws {
        let s = try session()
        s.player.view.selectedIds = ["clip:a", "clip:b"]
        XCTAssertFalse(s.layoutKey(EditorKey(.char("]"), alt: true, meta: true)), "left to the scene-split threshold")
        XCTAssertFalse(s.layoutKey(EditorKey(.left, alt: true)))
        s.player.view.selectedIds = []
        XCTAssertFalse(s.layoutKey(EditorKey(.char("g"), meta: true)), "without Option it is not this shortcut")
    }

    func testOptionArrowsMoveThePictureInPictureToThatSide() throws {
        let s = try session()
        s.player.view.selectedIds = ["clip:a", "clip:b"]
        XCTAssertTrue(s.applyLayout(.pictureInPicture, options: NativeGridOptions()))
        XCTAssertEqual(s.lastLayout?.options.corner, .bottomRight)
        let before = left(s, "clip:b")
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.layoutKey(EditorKey(.left, alt: true)))
        XCTAssertEqual(s.lastLayout?.options.corner, .bottomLeft)
        XCTAssertEqual(left(s, "clip:b"), 0)
        XCTAssertNotEqual(before, 0)
        XCTAssertEqual(s.editor.undoStack.count, depth + 1)
        XCTAssertTrue(s.layoutKey(EditorKey(.left, alt: true)), "already on the left")
        XCTAssertEqual(s.editor.undoStack.count, depth + 1, "no new undo step")
        s.player.view.selectedIds = ["clip:a"]
        XCTAssertFalse(s.layoutKey(EditorKey(.up, alt: true)), "the selection is no longer the arranged clips")
    }
}
