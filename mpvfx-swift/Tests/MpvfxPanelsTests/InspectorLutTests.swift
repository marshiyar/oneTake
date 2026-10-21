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
@testable import MpvfxPanels
import MpvfxShared
@testable import MpvfxTimeline
import XCTest

/// The Grade group's Custom LUT section (issue #182): a dropdown of None, the project's `.cube` files and Import
/// LUT…, a Remove button, the grid size or load error under the row, and the section open while a LUT is set.
internal final class InspectorLutTests: XCTestCase {
    private static let film: String = "/p/luts/film.cube"
    private static let log: String = "/p/luts/log.cube"
    private let size: CanvasSize = CanvasSize(409, 4_000)

    deinit {}

    // A1: None, every .cube by name, Import LUT…; each pick is one undo step; Remove clears it; undo restores.
    internal func testPickRemoveAndUndo() throws {
        let (rightPanel, editor): (RightPanel, TimelineEditor) = try panel()
        rightPanel.inspector.grade.lutOpen = true
        let labels: [String] = ["None", "film.cube", "log.cube", "Import LUT…"]
        XCTAssertEqual(rightPanel.inspector.lutOptions().map(\.label), labels)
        XCTAssertEqual(button(rightPanel.inspector, "lut.remove")?.disabled, true, "nothing to remove")
        let depth: Int = editor.undoStack.count
        try XCTUnwrap(button(rightPanel.inspector, "lut.pick.\(Self.film)")).action()
        XCTAssertEqual(lut(editor)?.src, Self.film)
        XCTAssertEqual(editor.undoStack.count, depth + 1, "one undo step")
        try XCTUnwrap(button(rightPanel.inspector, "lut.pick.\(Self.film)")).action()
        XCTAssertEqual(editor.undoStack.count, depth + 1, "the LUT already set: no edit")
        try XCTUnwrap(button(rightPanel.inspector, "lut.pick.\(Self.log)")).action()
        XCTAssertEqual(lut(editor)?.src, Self.log)
        try XCTUnwrap(button(rightPanel.inspector, "lut.remove")).action()
        XCTAssertNil(lut(editor))
        XCTAssertEqual(editor.undoStack.count, depth + 3)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(lut(editor)?.src, Self.log, "Remove was one undo step")
        var imports: Int = 0
        rightPanel.inspector.onImportLut = { imports += 1 }
        try XCTUnwrap(button(rightPanel.inspector, "lut.pick.\(InspectorPanel.lutImport)")).action()
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(lut(editor)?.src, Self.log, "Import LUT… asks for files, it changes nothing")
    }

    // A1: the select opens the dropdown with the current choice marked; Remove has a text label and a 24 pt target.
    internal func testTheSelectOpensTheDropdownAndRemoveIsA24ptButton() throws {
        let (rightPanel, editor): (RightPanel, TimelineEditor) = try panel()
        rightPanel.inspector.grade.lutOpen = true
        let canvas: PanelMeasureCanvas = PanelMeasureCanvas()
        rightPanel.draw(canvas, size: size)
        XCTAssertTrue(canvas.drawnStrings.contains("LUT"))
        XCTAssertTrue(canvas.drawnStrings.contains("None"))
        XCTAssertNil(hit(rightPanel, 1), "no Remove without a LUT")
        let select: CanvasRect = try XCTUnwrap(hit(rightPanel, 0))
        XCTAssertGreaterThanOrEqual(select.height, 24)
        XCTAssertTrue(rightPanel.pointerDown(CanvasPoint(select.midX, select.midY)))
        XCTAssertTrue(rightPanel.dropdown.isOpen)
        let values: [String] = [InspectorPanel.lutNone, Self.film, Self.log, InspectorPanel.lutImport]
        XCTAssertEqual(rightPanel.dropdown.options.map(\.value), values)
        XCTAssertEqual(rightPanel.dropdown.selected, InspectorPanel.lutNone)
        rightPanel.dropdown.pick(Self.film)
        XCTAssertEqual(lut(editor)?.src, Self.film)
        canvas.reset()
        rightPanel.draw(canvas, size: size)
        XCTAssertTrue(canvas.drawnStrings.contains("film.cube"))
        XCTAssertTrue(canvas.drawnStrings.contains("Remove"))
        let remove: CanvasRect = try XCTUnwrap(hit(rightPanel, 1))
        XCTAssertGreaterThanOrEqual(remove.height, 24)
        XCTAssertGreaterThanOrEqual(remove.width, 24)
        XCTAssertTrue(rightPanel.pointerDown(CanvasPoint(remove.midX, remove.midY)))
        XCTAssertNil(lut(editor))
    }

    // A5: closed without a LUT, open by default once one is set, and the user's own open/close wins.
    internal func testTheSectionIsOpenWhileALutIsSet() throws {
        let (rightPanel, editor): (RightPanel, TimelineEditor) = try panel()
        XCTAssertNil(button(rightPanel.inspector, "lut.remove"), "closed without a LUT")
        try setLut(editor)
        XCTAssertNotNil(button(rightPanel.inspector, "lut.remove"), "open by default with a LUT")
        rightPanel.draw(PanelMeasureCanvas(), size: size)
        let toggle: CanvasRect = try XCTUnwrap(rightPanel.inspector.hits.rect { $0 == .custom("lut:toggle", 0) })
        XCTAssertTrue(rightPanel.pointerDown(CanvasPoint(toggle.midX, toggle.midY)))
        XCTAssertEqual(rightPanel.inspector.grade.lutOpen, false)
        XCTAssertNil(button(rightPanel.inspector, "lut.remove"), "closed by the user")
    }

    // A3: the grid size in the label grey, 11 px.
    internal func testTheStatusLineShowsTheGridSize() throws {
        try assertStatusLine(.loaded(size: 33), startsWith: "33³ grid", color: PanelTheme.rowLabel)
    }

    // A2: the parser's reason in the error colour, 11 px; the failed LUT stays chosen and the preview skips it.
    internal func testTheStatusLineShowsWhyTheFileCannotBeRead() throws {
        let reason: String = "LUT data rows must contain three numbers at line 12"
        let prefix: String = "LUT 'film.cube' could not be read:"
        try assertStatusLine(.failed(reason), startsWith: prefix, color: PanelTheme.red400)
    }

    internal func testNoProjectLutsSaysHowToAddOne() throws {
        let (rightPanel, _): (RightPanel, TimelineEditor) = try panel()
        rightPanel.inspector.lutAssets = { [] }
        rightPanel.inspector.grade.lutOpen = true
        let canvas: PanelMeasureCanvas = PanelMeasureCanvas()
        rightPanel.draw(canvas, size: size)
        let hint: Bool = canvas.drawnStrings.contains { $0.hasPrefix("Choose Import LUT…") }
        XCTAssertTrue(hint, "\(canvas.drawnStrings)")
    }

    private func panel(status: LutStatus? = nil) throws -> (RightPanel, TimelineEditor) {
        let layout: PanelLayoutState = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1_440)
        let rightPanel: RightPanel = RightPanel(layout: layout)
        let editor: TimelineEditor = try TimelineEditor(json: InspectorMediaFitTests.json)
        rightPanel.inspector.editor = editor
        rightPanel.inspector.selection = ["clip:a"]
        rightPanel.inspector.openGroupId = "grade"
        rightPanel.inspector.lutAssets = { [Self.film, Self.log] }
        rightPanel.inspector.lutStatus = { _ in status }
        return (rightPanel, editor)
    }

    private func setLut(_ editor: TimelineEditor) throws {
        var grading: ColorGrading = editor.gradeShown(clipId: "clip:a", time: 0)
        grading.lut = ColorGrading.Lut(src: Self.film, intensity: 1)
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grading))
    }

    private func assertStatusLine(_ status: LutStatus, startsWith prefix: String, color: CanvasColor) throws {
        let (rightPanel, editor): (RightPanel, TimelineEditor) = try panel(status: status)
        try setLut(editor)
        let canvas: PanelMeasureCanvas = PanelMeasureCanvas()
        rightPanel.draw(canvas, size: size)
        let drawn: (String, CanvasPoint, CanvasFont, CanvasColor)? = canvas.texts.first { $0.0.hasPrefix(prefix) }
        let line: (String, CanvasPoint, CanvasFont, CanvasColor) = try XCTUnwrap(drawn, "\(prefix) is drawn")
        XCTAssertEqual(line.3, color)
        XCTAssertEqual(line.2.size, 11, "status text is 11 px")
        XCTAssertEqual(lut(editor)?.src, Self.film, "the LUT stays chosen")
    }

    private func lut(_ editor: TimelineEditor) -> ColorGrading.Lut? {
        editor.gradeShown(clipId: "clip:a", time: 0).lut
    }

    private func button(_ inspector: InspectorPanel, _ key: String) -> InspectorRow.Button? {
        let rows: [InspectorRow] = inspector.groups.first { $0.id == "grade" }?.addressableRows ?? []
        for row in rows {
            if case .buttons(let buttons) = row.kind, let match = buttons.first(where: { $0.key == key }) {
                return match
            }
        }
        return nil
    }

    private func hit(_ rightPanel: RightPanel, _ part: Int) -> CanvasRect? {
        rightPanel.inspector.hits.rect { $0 == .custom(InspectorPanel.lutRowId, part) }
    }
}
