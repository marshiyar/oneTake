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
import MpvfxCanvas
import MpvfxPlayer
import MpvfxShared
import MpvfxTimeline
import XCTest

@testable import MpvfxDesktop

final class LayoutMenuSessionTests: XCTestCase {
    private var dir: URL?

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func session() throws -> EditorSession {
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        dir = fresh
        let session = try EditorSession(projectPath: nil, demo: true)
        session.audio?.stop()
        _ = session.installShell(userData: fresh.path) {}
        session.playback.seek(1)   // frame 30: inside clip:a (0 to 180) and clip:logo (15 to 105)
        return session
    }

    private func select(_ s: EditorSession, _ ids: [String]) {
        s.timeline.view.selection = Set(ids)
        s.syncStage()
    }

    private func left(_ s: EditorSession, _ id: String) -> Double? {
        guard case .number(let n)? = s.editor.clip(id)?.clip.staticParameters?["layout.left"] else { return nil }
        return n
    }

    func testTheShortcutOpensTheMenuForTheSelectionAndReturnArrangesInOneUndoStep() throws {
        let s = try session()
        XCTAssertTrue(s.layoutKey(EditorKey(.char("g"), alt: true, meta: true)))
        XCTAssertNil(s.player.view.layoutMenu, "nothing is selected: a toast, no menu")
        select(s, ["clip:a", "clip:logo"])
        XCTAssertTrue(s.layoutKey(EditorKey(.char("g"), alt: true, meta: true)))
        XCTAssertEqual(s.player.view.layoutMenu?.clipCount, 2)
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.layoutKey(EditorKey(.enter)))
        XCTAssertNil(s.player.view.layoutMenu)
        XCTAssertEqual(s.editor.undoStack.count, depth + 1)
        XCTAssertEqual(s.editor.undoLabel, "Arrange layout")
        let last = try XCTUnwrap(s.lastLayout)
        XCTAssertEqual(last.layout, .sideBySide)
        XCTAssertEqual(Set(last.ids), ["clip:a", "clip:logo"])
        XCTAssertEqual(left(s, last.ids[0]), 0, "the first clip takes the first cell")
        XCTAssertNotEqual(left(s, last.ids[1]), 0)
    }

    func testOptionCmdBracketsSwapTheCellsOfTheLastLayoutAsOneUndoStep() throws {
        let s = try session()
        select(s, ["clip:a", "clip:logo"])
        _ = s.layoutKey(EditorKey(.char("g"), alt: true, meta: true))
        _ = s.layoutKey(EditorKey(.enter))
        let ids = try XCTUnwrap(s.lastLayout).ids
        let first = left(s, ids[0]), second = left(s, ids[1])
        XCTAssertNotEqual(first, second)
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.layoutKey(EditorKey(.char("]"), alt: true, meta: true)))
        XCTAssertEqual(left(s, ids[0]), second)
        XCTAssertEqual(left(s, ids[1]), first)
        XCTAssertEqual(s.editor.undoStack.count, depth + 1)
        XCTAssertTrue(s.layoutKey(EditorKey(.char("["), alt: true, meta: true)))
        XCTAssertEqual(left(s, ids[0]), first)
        XCTAssertEqual(s.editor.undoStack.count, depth + 2)
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(left(s, ids[0]), second)
    }

    func testWithoutALayoutTheBracketsAreNotTakenAndTheArrowsAreNotEither() throws {
        let s = try session()
        select(s, ["clip:a", "clip:logo"])
        XCTAssertFalse(s.layoutKey(EditorKey(.char("]"), alt: true, meta: true)), "left to the scene-split threshold")
        XCTAssertFalse(s.layoutKey(EditorKey(.left, alt: true)))
        XCTAssertFalse(s.layoutKey(EditorKey(.char("g"), meta: true)), "without Option it is not this shortcut")
    }

    func testOptionArrowsMoveThePictureInPictureToThatSide() throws {
        let s = try session()
        select(s, ["clip:a", "clip:logo"])
        XCTAssertTrue(s.applyLayout(.pictureInPicture, options: NativeGridOptions()), s.editor.lastFailure?.message ?? "no failure")
        let inset = try XCTUnwrap(s.lastLayout).ids[1]
        XCTAssertEqual(s.lastLayout?.options.corner, .bottomRight)
        XCTAssertNotEqual(left(s, inset), 0)
        let depth = s.editor.undoStack.count
        XCTAssertTrue(s.layoutKey(EditorKey(.left, alt: true)))
        XCTAssertEqual(s.lastLayout?.options.corner, .bottomLeft)
        XCTAssertEqual(left(s, inset), 0)
        XCTAssertEqual(s.editor.undoStack.count, depth + 1)
        XCTAssertTrue(s.layoutKey(EditorKey(.left, alt: true)), "already on the left")
        XCTAssertEqual(s.editor.undoStack.count, depth + 1, "no new undo step")
        select(s, ["clip:a"])
        XCTAssertFalse(s.layoutKey(EditorKey(.up, alt: true)), "the selection is no longer the arranged clips")
    }
}
