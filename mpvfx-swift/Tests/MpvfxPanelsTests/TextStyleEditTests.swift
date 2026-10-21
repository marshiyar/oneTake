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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels

internal final class TextStyleEditTests: XCTestCase {
    private func editor() throws -> (TimelineEditor, [String]) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let ids = (0..<3).compactMap { editor.addTextClip(at: Double($0 * 6), content: "Words \($0)") }
        XCTAssertEqual(ids.count, 3)
        return (editor, ids)
    }
    internal func testSaveApplyEditUpdateAndDetachAreSingleUndoStepsAndSurviveReopen() throws {
        let (editor, ids) = try editor()
        let original = editor.document
        let count = editor.undoStack.count
        XCTAssertTrue(editor.saveTextStyle(clipId: ids[0], styleId: "style:title", name: "Title"))
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertTrue(editor.applyTextStyle(styleId: "style:title", clipIds: ids))
        XCTAssertEqual(editor.undoStack.count, count + 2)
        XCTAssertTrue(editor.setTextColor(clipId: ids[0], "#ff0000"))
        XCTAssertEqual(editor.clip(ids[0])?.1.textStyle?.overrides, ["color"])
        XCTAssertTrue(editor.setTextFontSize(clipId: ids[1], 80))
        XCTAssertTrue(editor.updateTextStyle(styleId: "style:title", fromClipId: ids[1]))
        XCTAssertEqual(editor.undoStack.count, count + 5)
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.fontSize, 80)
        XCTAssertEqual(editor.clipText(clipId: ids[2])?.fontSize, 80)
        XCTAssertEqual(editor.clipText(clipId: ids[0])?.color, "#ff0000")
        let resolved = ids.map { editor.clipText(clipId: $0) }
        XCTAssertTrue(editor.detachTextStyle(clipIds: ids))
        XCTAssertEqual(editor.undoStack.count, count + 6)
        XCTAssertEqual(ids.map { editor.clipText(clipId: $0) }, resolved)
        let saved = try serializeNativeProjectDocument(editor.document, engine: editor.engine)
        let reopened = try TimelineEditor(json: saved, engine: try KeyframeRuntime())
        XCTAssertEqual(ids.map { reopened.clipText(clipId: $0) }, resolved)
        for _ in 0..<6 { XCTAssertTrue(editor.undo()) }
        XCTAssertEqual(editor.document, original)
        for _ in 0..<6 { XCTAssertTrue(editor.redo()) }
        XCTAssertEqual(ids.map { editor.clipText(clipId: $0) }, resolved)
    }
    internal func testCrossProjectPasteDetachesResolvedSnapshotEvenWithCollidingStyleId() throws {
        let (source, sourceIds) = try editor()
        source.projectDirectory = URL(fileURLWithPath: "/tmp/text-style-source")
        XCTAssertTrue(source.saveTextStyle(clipId: sourceIds[0], styleId: "style:title", name: "Title"))
        XCTAssertTrue(source.applyTextStyle(styleId: "style:title", clipIds: sourceIds))
        XCTAssertTrue(source.setTextColor(clipId: sourceIds[0], "#ff0000"))
        XCTAssertTrue(source.updateTextStyle(styleId: "style:title", fromClipId: sourceIds[0]))
        let expected = try XCTUnwrap(source.clipText(clipId: sourceIds[1]))
        let board = try XCTUnwrap(source.copyClips([sourceIds[1]]))
        for collides in [false, true] {
            let (destination, destinationIds) = try editor()
            destination.projectDirectory = URL(fileURLWithPath: "/tmp/text-style-destination")
            if collides {
                XCTAssertTrue(
                    destination.saveTextStyle(clipId: destinationIds[0], styleId: "style:title", name: "Different"))
            }
            let before = destination.document
            let undoCount = destination.undoStack.count
            let pasted = destination.paste(board, at: 30)
            let copiedId = try XCTUnwrap(pasted.first)
            XCTAssertEqual(destination.clipText(clipId: copiedId), expected)
            XCTAssertNil(destination.clip(copiedId)?.clip.textStyle)
            XCTAssertEqual(destination.undoStack.count, undoCount + 1)
            XCTAssertTrue(destination.undo())
            XCTAssertEqual(destination.document, before)
        }
        let localId = try XCTUnwrap(source.paste(board, at: 30).first)
        XCTAssertEqual(source.clip(localId)?.clip.textStyle?.styleId, "style:title")
    }

    internal func testUnsupportedStyleRefusesCrossProjectPasteAtomically() throws {
        let (source, ids) = try editor()
        XCTAssertTrue(source.saveTextStyle(clipId: ids[0], styleId: "style:future", name: "Future"))
        XCTAssertTrue(source.applyTextStyle(styleId: "style:future", clipIds: ids))
        var future = source.document
        future.textStyles?[0].version = 2
        XCTAssertTrue(source.apply(.restoreDocument(future)))
        let board = try XCTUnwrap(source.copyClips([ids[0]]))
        let (destination, _) = try editor()
        destination.projectDirectory = URL(fileURLWithPath: "/tmp/another-text-project")
        let before = destination.document
        let count = destination.undoStack.count
        XCTAssertEqual(destination.paste(board, at: 30), [])
        XCTAssertEqual(destination.document, before)
        XCTAssertEqual(destination.undoStack.count, count)
        XCTAssertTrue(destination.lastFailure?.message.contains("newer editor") == true)
    }

    internal func testInspectorInheritanceTiersResetToStyleAndResolveSwatches() throws {
        let (editor, ids) = try editor()
        XCTAssertTrue(editor.saveTextStyle(clipId: ids[0], styleId: "style:title", name: "Title"))
        XCTAssertTrue(editor.applyTextStyle(styleId: "style:title", clipIds: ids))
        XCTAssertTrue(editor.setTextColor(clipId: ids[0], "#ff0000"))
        XCTAssertTrue(editor.updateTextStyle(styleId: "style:title", fromClipId: ids[0]))
        let panel = InspectorPanel()
        panel.editor = editor
        panel.selection = [ids[1]]
        panel.openGroupId = "text"
        func draw() { panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 360, height: 2000)) }
        draw()
        for key in ["fontSize", "fontWeight", "textColor"] {
            XCTAssertEqual(panel.number(key)?.tier, .default, key)
            XCTAssertNil(panel.number(key)?.reset, key)
        }
        XCTAssertEqual(panel.number("textColor")?.swatch?.color, "#ff0000")
        XCTAssertTrue(InspectorPanel.projectColors(editor.document).contains("#ff0000"))
        XCTAssertFalse(InspectorPanel.projectColors(editor.document).contains("#ffffff"))
        XCTAssertTrue(editor.setTextFontSize(clipId: ids[1], nil))
        XCTAssertTrue(editor.setTextColor(clipId: ids[1], nil))
        draw()
        XCTAssertEqual(panel.number("fontSize")?.tier, .explicitCustom)
        XCTAssertEqual(panel.number("textColor")?.tier, .explicitCustom)
        let count = editor.undoStack.count
        try XCTUnwrap(panel.number("fontSize")?.reset)()
        try XCTUnwrap(panel.number("textColor")?.reset)()
        XCTAssertEqual(editor.undoStack.count, count + 2)
        draw()
        XCTAssertEqual(editor.clipText(clipId: ids[1])?.fontSize, editor.clipText(clipId: ids[0])?.fontSize)
        XCTAssertEqual(editor.clipText(clipId: ids[1])?.color, "#ff0000")
        XCTAssertEqual(panel.number("fontSize")?.tier, .default)
        XCTAssertEqual(panel.number("textColor")?.tier, .default)
    }

}
