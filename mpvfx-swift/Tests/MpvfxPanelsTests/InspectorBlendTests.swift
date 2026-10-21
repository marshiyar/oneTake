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
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Style group's Blend dropdown: one undo step per pick, the saved `clip.style.blend`, the tier and the reset.
final class InspectorBlendTests: XCTestCase {
    func panel() throws -> (RightPanel, TimelineEditor) {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json)
        r.inspector.editor = editor
        r.inspector.selection = ["clip:a"]
        r.inspector.openGroupId = "style"
        return (r, editor)
    }

    func testTheStyleGroupHasABlendRowWithEveryMode() throws {
        let (r, _) = try panel()
        XCTAssertNotNil(r.inspector.customRow(InspectorPanel.blendRowId))
        XCTAssertEqual(InspectorPanel.blendOptions().map(\.label),
                       ["Normal", "Multiply", "Screen", "Overlay", "Add", "Soft light", "Darken", "Lighten"])
        XCTAssertEqual(InspectorPanel.blendTier(.normal), .default); XCTAssertEqual(InspectorPanel.blendTier(.screen), .explicitCustom)
    }

    func testEachPickIsOneUndoStepSavedInTheStyleAndResetRemovesTheKey() throws {
        let (r, editor) = try panel()
        let depth = editor.undoStack.count
        XCTAssertTrue(editor.setClipBlend(clipId: "clip:a", .multiply))
        XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "multiply")
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertFalse(editor.setClipBlend(clipId: "clip:a", .multiply), "the shown value again is no edit")
        XCTAssertTrue(editor.setClipBlend(clipId: "clip:a", .softLight)); XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "soft-light")
        XCTAssertTrue(editor.setClipBlend(clipId: "clip:a", .normal))
        XCTAssertNil(editor.clip("clip:a")?.1.style, "normal removes the key and the empty style with it")
        XCTAssertEqual(editor.undoStack.count, depth + 3)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "soft-light")
        XCTAssertTrue(editor.undo()); XCTAssertTrue(editor.undo()); XCTAssertNil(editor.clipStyle(clipId: "clip:a").blend)
        _ = r
    }

    func testTheSelectOpensTheDropdownAndThePickAndResetEdit() throws {
        let (r, editor) = try panel()
        r.draw(PanelMeasureCanvas(), size: CanvasSize(409, 1400))
        let field = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.blendRowId, 0) }))
        XCTAssertNil(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.blendRowId, 1) }), "no reset at Normal")
        XCTAssertTrue(r.pointerDown(CanvasPoint(field.midX, field.midY)))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(r.dropdown.options.map(\.value),
                       ["normal", "multiply", "screen", "overlay", "add", "soft-light", "darken", "lighten"])
        XCTAssertEqual(r.dropdown.selected, "normal", "the current mode is highlighted")
        r.dropdown.pick("screen")
        XCTAssertFalse(r.dropdown.isOpen); XCTAssertEqual(editor.undoLabel, "Set blend mode")
        XCTAssertEqual(editor.clipStyle(clipId: "clip:a").blend, "screen")
        r.draw(PanelMeasureCanvas(), size: CanvasSize(409, 1400))
        let reset = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.blendRowId, 1) }), "reset shows once a mode is set")
        XCTAssertTrue(r.pointerDown(CanvasPoint(reset.midX, reset.midY)))
        XCTAssertNil(editor.clipStyle(clipId: "clip:a").blend)
    }
}
