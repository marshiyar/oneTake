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
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxPanels

final class BackgroundGeneratorTests: XCTestCase {
    func testMediaBinMenuOffersAllGeneratorsAndKeyboardInsertsAtPlayheadInOneUndo() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let before = editor.document
        let panel = LeftSidebarPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        var clipId: String?
        panel.onAddGenerator = { clipId = editor.addGenerator($0, at: 2) }
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(370, 800))
        panel.focus.current = .panelMenu; panel.focus.visible = true
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        XCTAssertEqual(panel.dropdown.options.filter { $0.value.hasPrefix("generator:") }.count, 3)
        // The dropdown starts on Import. Three down presses choose Radial, then Enter inserts.
        for _ in 0..<4 { XCTAssertTrue(panel.keyDown(EditorKey(.down))) }
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        let clip = try XCTUnwrap(editor.clip(try XCTUnwrap(clipId))?.clip)
        XCTAssertEqual(clip.generator?.gradientType, "radial"); XCTAssertEqual(clip.startFrame, editor.fps * 2)
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
        XCTAssertTrue(editor.redo()); XCTAssertNotNil(editor.clip(clip.id))
    }
    func testEachKindInsertsAValidatedFullCanvasClipAndReopens() throws {
        for kind in NativeGeneratorKind.allCases {
            let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
            let id = try XCTUnwrap(editor.addGenerator(kind, at: 1.25))
            XCTAssertEqual(editor.clip(id)?.clip.generator, kind.fill)
            let reopened = try parseNativeProjectDocument(try NativeJSONValue.parse(serializeNativeProjectDocument(editor.document)))
            XCTAssertEqual(reopened, editor.document)
        }
    }
    func testDesignAngleKeyboardCommitIsOneUndoAndInvalidValueDoesNothing() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let id = try XCTUnwrap(editor.addGenerator(.linear, at: 0))
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = [id]; panel.openGroupId = "generator"
        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 380, height: 1400))
        let before = editor.document, count = editor.undoStack.count
        XCTAssertNotNil(panel.hits.rect { $0 == .field("angle") })
        panel.focus.current = .field("angle"); panel.focus.visible = true
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        for _ in 0..<2 { XCTAssertTrue(panel.keyDown(EditorKey(.backspace))) }
        for c in "45" { XCTAssertTrue(panel.keyDown(EditorKey(.char(c)))) }
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        XCTAssertEqual(editor.clip(id)?.clip.generator?.angle, 45)
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertFalse(editor.editGenerator(clipId: id) { $0["gradient"]?["angle"] = .number(999) })
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
    }
    func testRadialCentreAndColoursEditPersistAndLockedTrackRefuses() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let id = try XCTUnwrap(editor.addGenerator(.radial, at: 0))
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = [id]; panel.openGroupId = "generator"
        let group = try XCTUnwrap(panel.buildGroups().first { $0.id == "generator" })
        let numbers = group.addressableRows.compactMap { row -> InspectorRow.Number? in if case .number(let n) = row.kind { return n }; return nil }
        try XCTUnwrap(numbers.first { $0.key == "centerX" }).commit("0.25")
        XCTAssertEqual(editor.clip(id)?.clip.generator?.centerX, 0.25)
        XCTAssertTrue(editor.editGenerator(clipId: id) { $0["gradient"]?["stops"]?[0]?["color"] = .string("#FF000080") })
        XCTAssertEqual(editor.clip(id)?.clip.generator?.stops[0].color, "#FF000080")
        let track = try XCTUnwrap(editor.clip(id)?.track.id)
        XCTAssertTrue(editor.setTrackLocked(track, true))
        XCTAssertFalse(editor.editGenerator(clipId: id) { $0["gradient"]?["centerY"] = .number(0.2) })
    }
    func testInvalidInsertionDoesNotCreateAnOrphanAsset() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON); let before = editor.document
        XCTAssertNil(editor.addGenerator(.solid, at: .greatestFiniteMagnitude)); XCTAssertNil(editor.addGenerator(.solid, at: .nan)); XCTAssertNil(editor.addGenerator(.linear, at: 0, seconds: -.infinity))
        XCTAssertEqual(editor.document, before); XCTAssertTrue(editor.undoStack.isEmpty)
    }
}
