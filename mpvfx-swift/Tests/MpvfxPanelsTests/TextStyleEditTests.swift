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
import OneTakeKeyframes
import MpvfxTimeline
@testable import MpvfxPanels

final class TextStyleEditTests: XCTestCase {
    func editor() throws -> (TimelineEditor, [String]) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let ids = (0..<3).compactMap { editor.addTextClip(at: Double($0 * 6), content: "Words \($0)") }
        XCTAssertEqual(ids.count, 3)
        return (editor, ids)
    }
    func testSaveApplyEditUpdateAndDetachAreSingleUndoStepsAndSurviveReopen() throws {
        let (e, ids) = try editor()
        let original = e.document
        let count = e.undoStack.count
        XCTAssertTrue(e.saveTextStyle(clipId: ids[0], styleId: "style:title", name: "Title"))
        XCTAssertEqual(e.undoStack.count, count + 1)
        XCTAssertTrue(e.applyTextStyle(styleId: "style:title", clipIds: ids))
        XCTAssertEqual(e.undoStack.count, count + 2)
        XCTAssertTrue(e.setTextColor(clipId: ids[0], "#ff0000"))
        XCTAssertEqual(e.clip(ids[0])?.1.textStyle?.overrides, ["color"])
        XCTAssertTrue(e.setTextFontSize(clipId: ids[1], 80))
        XCTAssertTrue(e.updateTextStyle(styleId: "style:title", fromClipId: ids[1]))
        XCTAssertEqual(e.undoStack.count, count + 5)
        XCTAssertEqual(e.clipText(clipId: ids[0])?.fontSize, 80)
        XCTAssertEqual(e.clipText(clipId: ids[2])?.fontSize, 80)
        XCTAssertEqual(e.clipText(clipId: ids[0])?.color, "#ff0000")
        let resolved = ids.map { e.clipText(clipId: $0) }
        XCTAssertTrue(e.detachTextStyle(clipIds: ids))
        XCTAssertEqual(e.undoStack.count, count + 6)
        XCTAssertEqual(ids.map { e.clipText(clipId: $0) }, resolved)
        let saved = try serializeNativeProjectDocument(e.document, engine: e.engine)
        let reopened = try TimelineEditor(json: saved, engine: try KeyframeRuntime())
        XCTAssertEqual(ids.map { reopened.clipText(clipId: $0) }, resolved)
        for _ in 0..<6 { XCTAssertTrue(e.undo()) }
        XCTAssertEqual(e.document, original)
        for _ in 0..<6 { XCTAssertTrue(e.redo()) }
        XCTAssertEqual(ids.map { e.clipText(clipId: $0) }, resolved)
    }
}
