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
import MpvfxCanvas
import MpvfxTimeline
@testable import MpvfxPanels

final class HistoryPanelTests: XCTestCase {
    private func make() throws -> (HistoryPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let p = HistoryPanel()
        p.editor = editor
        p.timeText = { _ in "12:00:00" }
        return (p, editor)
    }

    private func edit(_ editor: TimelineEditor, _ label: String, hidden: Bool) {
        editor.withHistory(label) { _ = editor.setClipsHidden(["clip:a"], hidden) }
    }

    func testIsRegisteredUnderItsSavedId() {
        XCTAssertEqual(DockPanels.history, "history")
        XCTAssertEqual(DockRegistry.editor.title("history"), "History")
        XCTAssertTrue(DockRegistry.editor.isClosable("history"))
    }

    func testListsEveryEditOldestFirstWithTheCurrentStateMarked() throws {
        let (p, editor) = try make()
        XCTAssertEqual(p.rows.map(\.label), ["Original"])
        edit(editor, "Hide clip", hidden: true)
        edit(editor, "Show clip", hidden: false)
        XCTAssertEqual(p.rows.map(\.label), ["Original", "Hide clip", "Show clip"])
        XCTAssertEqual(p.rows.map(\.kind), [.initial, .done, .done])
        XCTAssertEqual(p.currentRow, 2)
        editor.undo()
        XCTAssertEqual(p.rows.map(\.kind), [.initial, .done, .undone])
        XCTAssertEqual(p.currentRow, 1)
    }

    func testClickingAnEntryStepsBackAndForwardInOneGesture() throws {
        let (p, editor) = try make()
        edit(editor, "Hide clip", hidden: true)
        edit(editor, "Show clip", hidden: false)
        edit(editor, "Hide again", hidden: true)
        var changes = 0
        editor.onChange = { changes += 1 }
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(300, 300))
        XCTAssertTrue(c.drawnStrings.contains("Hide again"))
        XCTAssertTrue(p.pointerDown(CanvasPoint(40, 13), shift: false), "row 0 is Original")
        XCTAssertEqual(p.currentRow, 0)
        XCTAssertFalse(editor.isClipHidden("clip:a"))
        XCTAssertEqual(editor.redoStack.count, 3, "the redo entries stay available")
        XCTAssertGreaterThan(changes, 0)
        XCTAssertTrue(p.jump(to: 3))
        XCTAssertEqual(p.currentRow, 3)
        XCTAssertTrue(editor.isClipHidden("clip:a"))
        XCTAssertTrue(editor.redoStack.isEmpty)
    }

    func testAJumpReportsTheChangeSoTheHostCanSave() throws {
        let (p, editor) = try make()
        edit(editor, "Hide clip", hidden: true)
        var jumps = 0
        p.onJump = { jumps += 1 }
        XCTAssertTrue(p.jump(to: 0))
        XCTAssertEqual(jumps, 1)
        XCTAssertTrue(p.jump(to: 0), "the current state is a no-op")
        XCTAssertFalse(p.jump(to: 7), "a row that does not exist")
        XCTAssertFalse(p.jump(to: -1))
    }

    func testEmptyHistoryShowsANote() throws {
        let (p, _) = try make()
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(300, 200))
        XCTAssertTrue(c.drawnStrings.contains("No edits yet"))
        XCTAssertFalse(p.pointerDown(CanvasPoint(10, 10), shift: false))
    }

    func testArrowKeysStepOneState() throws {
        let (p, editor) = try make()
        edit(editor, "Hide clip", hidden: true)
        XCTAssertTrue(p.keyDown(EditorKey(.up)))
        XCTAssertEqual(p.currentRow, 0)
        XCTAssertTrue(p.keyDown(EditorKey(.down)))
        XCTAssertEqual(p.currentRow, 1)
        XCTAssertFalse(p.keyDown(EditorKey(.char("x"))))
    }

    func testRowListScrollsAndFindsRows() {
        var l = PanelRowList(rowHeight: 20)
        l.layout(viewport: CanvasRect(x: 0, y: 0, width: 100, height: 100), count: 30)
        XCTAssertEqual(l.row(at: CanvasPoint(5, 25)), 1)
        XCTAssertTrue(l.scroll(by: 40))
        XCTAssertEqual(l.row(at: CanvasPoint(5, 25)), 3)
        XCTAssertTrue(l.scroll(by: 10_000))
        XCTAssertEqual(l.scrollY, 500)
        XCTAssertFalse(l.scroll(by: 5))
        l.reveal(0)
        XCTAssertEqual(l.scrollY, 0)
        XCTAssertNil(l.row(at: CanvasPoint(500, 5)))
    }
}
