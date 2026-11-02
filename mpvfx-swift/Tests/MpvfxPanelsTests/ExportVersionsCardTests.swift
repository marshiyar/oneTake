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

/// The "Export versions" checklist (⇧⌘R, #334).
final class ExportVersionsCardTests: XCTestCase {
    func panel(_ presets: [RenderPreset]) -> RightPanel {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        let p = RightPanel(layout: layout)
        p.renderPresets = presets
        return p
    }

    func preset(_ name: String, format: String = "mp4", composition: RenderPresetComposition? = nil) -> RenderPreset {
        var s = RenderSettingsModel(); s.format = format
        return RenderPreset(name: name, settings: s, composition: composition)
    }

    func center(_ panel: RightPanel, _ hit: ExportVersionsCard.Hit) throws -> CanvasPoint {
        let r = try XCTUnwrap(panel.versions.hits.rect { $0 == hit }, "\(hit) is not on the card")
        return CanvasPoint(r.midX, r.midY)
    }

    func testOpeningListsThePresetsAndExportNeedsAtLeastOneChecked() throws {
        let p = panel([preset("Master"), preset("Review")])
        p.openExportVersions()
        XCTAssertTrue(p.versions.isOpen)
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertNil(p.versions.hits.rect { $0 == .export }, "nothing checked, nothing to export")
        var asked: [[String]] = []
        p.onExportVersions = { asked.append($0) }
        XCTAssertFalse(p.versions.export())
        XCTAssertTrue(asked.isEmpty)
    }

    func testCheckedPresetsExportInListOrderAndTheCardCloses() throws {
        let p = panel([preset("Master"), preset("Review"), preset("Square")])
        var asked: [[String]] = []
        p.onExportVersions = { asked.append($0) }
        p.openExportVersions()
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        for name in ["Square", "Master"] {
            XCTAssertTrue(p.pointerDown(try center(p, .toggle(name))))
            p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        }
        XCTAssertEqual(p.versions.selection, ["Master", "Square"])
        XCTAssertTrue(p.pointerDown(try center(p, .export)))
        XCTAssertEqual(asked, [["Master", "Square"]])
        XCTAssertFalse(p.versions.isOpen)
        // The next run starts from the last choice.
        p.openExportVersions()
        XCTAssertEqual(p.versions.selection, ["Master", "Square"])
    }

    func testAnUnusablePresetIsListedWithItsReasonAndCannotBeChecked() throws {
        let p = panel([preset("Old", format: "webm"), preset("Master")])
        p.openExportVersions()
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertNil(p.versions.hits.rect { $0 == .toggle("Old") })
        p.versions.toggle("Old")
        XCTAssertEqual(p.versions.selection, [])
        XCTAssertEqual(p.versions.reason(p.renderPresets[0]), "Format webm is not supported yet")
        let canvas = PanelMeasureCanvas()
        p.draw(canvas, size: CanvasSize(409, 700))
        XCTAssertTrue(canvas.drawnStrings.contains("Format webm is not supported yet"), "\(canvas.drawnStrings)")
    }

    func testKeysMoveCheckExportAndClose() throws {
        let p = panel([preset("A"), preset("B"), preset("C")])
        var asked: [[String]] = []
        p.onExportVersions = { asked.append($0) }
        p.openExportVersions()
        XCTAssertTrue(p.isEditingText, "the editor's own keys stay out of the way")
        _ = p.keyDown(EditorKey(.down)); _ = p.keyDown(EditorKey(.space))   // B
        _ = p.keyDown(EditorKey(.down)); _ = p.keyDown(EditorKey(.space))   // C
        _ = p.keyDown(EditorKey(.down)); _ = p.keyDown(EditorKey(.space))   // the end of the list: C off again
        XCTAssertEqual(p.versions.selection, ["B"])
        XCTAssertTrue(p.keyDown(EditorKey(.char("x"))), "a modal card keeps every key")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(asked, [["B"]])
        p.openExportVersions()
        _ = p.keyDown(EditorKey(.escape))
        XCTAssertFalse(p.versions.isOpen)
        XCTAssertEqual(asked.count, 1)
    }

    func testAPressOutsideTheCardClosesItWithoutExporting() throws {
        let p = panel([preset("A")])
        var asked = 0
        p.onExportVersions = { _ in asked += 1 }
        p.openExportVersions()
        p.versions.toggle("A")
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertTrue(p.pointerDown(CanvasPoint(2, 690)))
        XCTAssertFalse(p.versions.isOpen)
        XCTAssertEqual(asked, 0)
    }

    func testItWaitsForRendersInProgressAndSaysSo() {
        let p = panel([preset("A")])
        p.jobs = [.init(id: "1", name: "x.mp4", status: .rendering)]
        p.openExportVersions()
        XCTAssertFalse(p.versions.isOpen)
        XCTAssertEqual(p.actionError, "Wait for the renders in progress to finish, then export versions.")
    }

    func testPickingACompositionSizeAsksTheHostToSaveItAndClearingRemovesIt() throws {
        let p = panel([preset("Master"), preset("Tall", composition: RenderPresetComposition(width: 1080, height: 1920))])
        var picked: [(String, RenderPresetComposition?)] = []
        p.onSetPresetComposition = { picked.append(($0, $1)) }
        p.openExportVersions()
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertTrue(p.pointerDown(try center(p, .size("Master"))))
        XCTAssertEqual(p.versions.dropdown.options.first?.label, "Project size")
        p.versions.dropdown.pick("square")
        XCTAssertEqual(picked.count, 1)
        XCTAssertEqual(picked[0].0, "Master"); XCTAssertEqual(picked[0].1, RenderPresetComposition(width: 1080, height: 1080))
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertTrue(p.pointerDown(try center(p, .size("Tall"))))
        XCTAssertEqual(p.versions.dropdown.selected, "portrait", "1080 × 1920 is the Portrait 9:16 size")
        p.versions.dropdown.pick("project")
        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked[1].0, "Tall"); XCTAssertNil(picked[1].1)
        XCTAssertTrue(p.versions.isOpen, "choosing a size keeps the checklist open")
    }

    func testASizeThatIsNoNamedOneIsKeptAndShown() throws {
        let p = panel([preset("Odd", composition: RenderPresetComposition(width: 1000, height: 500))])
        p.openExportVersions()
        p.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertTrue(p.pointerDown(try center(p, .size("Odd"))))
        XCTAssertEqual(p.versions.dropdown.selected, "keep")
        XCTAssertEqual(p.versions.dropdown.options.last?.label, "1000 × 500")
    }
}
