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

/// The Design tab with nothing selected shows the Composition section: a preset dropdown (Landscape, Portrait,
/// Square, Vertical 4:5, 4K, Custom), the width and height, and the current size. Every change is one undo step.
final class CompositionPanelTests: XCTestCase {
    func panel() throws -> (RightPanel, TimelineEditor) {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        r.inspector.editor = editor
        r.inspector.selection = []
        return (r, editor)
    }

    func rows(_ r: RightPanel) -> [InspectorRow] { r.inspector.groups.first { $0.id == "composition" }?.addressableRows ?? [] }
    func number(_ r: RightPanel, _ key: String) -> InspectorRow.Number? {
        for row in rows(r) {
            if case .pair(_, let a, let b) = row.kind { if a.key == key { return a }; if b.key == key { return b } }
        }
        return nil
    }
    func button(_ r: RightPanel, _ key: String) -> InspectorRow.Button? {
        for row in rows(r) { if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == key }) { return b } }
        return nil
    }

    func testNothingSelectedShowsTheCompositionSectionWithEveryPreset() throws {
        let (r, _) = try panel()
        XCTAssertEqual(r.inspector.groups.map(\.title), ["Composition"])
        XCTAssertEqual(r.inspector.compositionPresetOptions().map(\.label), [
            "Landscape 16:9 · 1920×1080", "Portrait 9:16 · 1080×1920", "Square 1:1 · 1080×1080",
            "Vertical 4:5 · 1080×1350", "4K 16:9 · 3840×2160", "Custom",
        ])
        XCTAssertEqual(r.inspector.compositionPresetValue, "landscape", "the matching preset is the current one")
        XCTAssertEqual(number(r, "compositionWidth")?.text, "1920"); XCTAssertEqual(number(r, "compositionHeight")?.text, "1080")
        XCTAssertEqual(r.inspector.groups.first?.summary, "1920×1080 · 16:9")
        // Selecting a clip shows the clip's groups instead.
        r.inspector.selection = ["clip:a"]
        XCTAssertFalse(r.inspector.groups.contains { $0.id == "composition" })
    }

    func testAPresetSetsTheSizeAsOneUndoStep() throws {
        let (r, editor) = try panel()
        var edits = 0
        r.inspector.onEdited = { edits += 1 }
        try XCTUnwrap(button(r, "compositionPreset.portrait")).action()
        XCTAssertEqual(editor.document.canvas.width, 1080); XCTAssertEqual(editor.document.canvas.height, 1920)
        XCTAssertEqual(editor.undoLabel, "Set composition size"); XCTAssertEqual(edits, 1)
        XCTAssertEqual(r.inspector.compositionPresetValue, "portrait")
        XCTAssertEqual(r.inspector.compositionPresetLabel, "Portrait 9:16 · 1080×1920")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(r.inspector.compositionPresetValue, "landscape")
    }

    func testCustomWidthAndHeightFieldsAndTheCustomLabel() throws {
        let (r, editor) = try panel()
        try XCTUnwrap(number(r, "compositionWidth")).commit("1000")
        XCTAssertEqual(editor.document.canvas.width, 1000); XCTAssertEqual(editor.document.canvas.height, 1080, "height kept")
        XCTAssertEqual(r.inspector.compositionPresetValue, "custom", "no preset matches")
        XCTAssertEqual(r.inspector.compositionPresetLabel, "Custom · 1000×1080")
        try XCTUnwrap(number(r, "compositionHeight")).commit("1,000 px")
        XCTAssertEqual(editor.document.canvas.height, 1000)
        XCTAssertEqual(r.inspector.groups.first?.summary, "1000×1000 · 1:1")
        // Not a whole number of pixels: refused, nothing changes.
        let before = editor.document
        try XCTUnwrap(number(r, "compositionWidth")).commit("0")
        try XCTUnwrap(number(r, "compositionWidth")).commit("12.5")
        try XCTUnwrap(number(r, "compositionWidth")).commit("abc")
        XCTAssertEqual(editor.document, before)
    }

    func testThePresetFieldOpensTheDropdownWithTheMatchingPresetMarked() throws {
        let (r, editor) = try panel()
        let size = CanvasSize(409, 900)
        r.draw(PanelMeasureCanvas(), size: size)
        let field = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom("compositionPreset", 0) }), "the preset select is drawn")
        XCTAssertTrue(r.pointerDown(CanvasPoint(field.midX, field.midY)))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(r.dropdown.options.map(\.value), ["landscape", "portrait", "square", "vertical-4-5", "landscape-4k", "custom"])
        XCTAssertEqual(r.dropdown.selected, "landscape", "the current preset is highlighted")
        r.dropdown.pick("square")
        XCTAssertFalse(r.dropdown.isOpen)
        XCTAssertEqual(editor.document.canvas.width, 1080); XCTAssertEqual(editor.document.canvas.height, 1080)
        _ = r.pointerDown(CanvasPoint(field.midX, field.midY))
        XCTAssertEqual(r.dropdown.selected, "square")
    }

    func testRenderResolutionsFollowTheComposition() throws {
        let (r, _) = try panel()
        r.canvasSize = CanvasSize(1080, 1920)
        let options = r.resolutionOptions()
        XCTAssertEqual(options.map(\.value), ["auto", "720p", "1080p", "1440p", "2160p", "4320p", "custom"])
        XCTAssertEqual(options.first?.label, "Composition · 1080×1920")
        XCTAssertEqual(options[1].label, "720p · 720×1280")
        XCTAssertEqual(options[4].label, "4K · 2160×3840")
        // A choice saved before (a fixed preset) shows as the scale it now means.
        r.settings.resolution = "vertical-hd"
        XCTAssertEqual(r.resolutionLabel, "720p · 720×1280")
        r.settings.resolution = "custom"; r.settings.customWidth = 540
        XCTAssertEqual(r.resolutionLabel, "Custom · 540×960")
    }
}

#if os(Linux)   // Cairo draws real pixels here; the AppKit drawing of the same panel is not checked by this test.
final class CompositionPanelPixelTests: XCTestCase {
    /// Writes the PNG for review when MPVFX_SNAPSHOT_DIR is set (as PanelSnapshotTests does).
    func writeSnapshot(_ t: CairoImageTarget, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(t.writePNG("\(dir)/\(name)"), 0)
    }

    func testTheCompositionSectionDraws() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        r.inspector.editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let t = CairoImageTarget(width: 409, height: 600)
        r.draw(t.canvas, size: CanvasSize(409, 600))
        writeSnapshot(t, "inspector-composition-1x.png")
        let field = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom("compositionPreset", 0) }))
        let p = t.pixel(Int(field.maxX - 30), Int(field.y + 3))   // inside the select, clear of its text and caret
        let want = PanelTheme.panelInput
        XCTAssertEqual(Double(p.r), (want.r * 255).rounded(), accuracy: 6); XCTAssertEqual(Double(p.g), (want.g * 255).rounded(), accuracy: 6)
        XCTAssertEqual(Double(p.b), (want.b * 255).rounded(), accuracy: 6)
        XCTAssertNotNil(r.inspector.hits.rect(where: { $0 == .field("compositionWidth") }), "width field drawn")
        XCTAssertNotNil(r.inspector.hits.rect(where: { $0 == .field("compositionHeight") }), "height field drawn")
        // The open preset popover lists every preset over the panel, the current one marked.
        XCTAssertTrue(r.pointerDown(CanvasPoint(field.midX, field.midY)))
        let open = CairoImageTarget(width: 409, height: 600)
        r.draw(open.canvas, size: CanvasSize(409, 600))
        XCTAssertTrue(r.dropdown.isOpen)
        let item = r.dropdown.rect
        XCTAssertGreaterThan(item.height, 6 * PanelDropdown.itemH, "six options shown")
        writeSnapshot(open, "inspector-composition-presets-1x.png")
    }

    func testRendersTabOfAPortraitComposition() throws {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let r = RightPanel(layout: layout)
        r.canvasSize = CanvasSize(1080, 1920)
        let t = CairoImageTarget(width: 409, height: 600)
        r.draw(t.canvas, size: CanvasSize(409, 600))
        let res = try XCTUnwrap(r.hits.rect(where: { $0 == .resolution }))
        XCTAssertTrue(r.pointerDown(CanvasPoint(res.midX, res.midY)))
        r.draw(t.canvas, size: CanvasSize(409, 600))
        XCTAssertEqual(r.dropdown.options.first?.label, "Composition · 1080×1920")
        writeSnapshot(t, "renders-portrait-resolution-1x.png")
    }
}
#endif
