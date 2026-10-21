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

/// The Grade group's Custom LUT section (issue #182): a dropdown of None, the project's `.cube` files and Import
/// LUT…, a Remove button, the grid size or load error under the row, and the section open while a LUT is set.
final class InspectorLutTests: XCTestCase {
    static let film = "/p/luts/film.cube", log = "/p/luts/log.cube"
    let size = CanvasSize(409, 4000)

    func panel(status: LutStatus? = nil) throws -> (RightPanel, TimelineEditor) {
        let r = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json)
        r.inspector.editor = editor
        r.inspector.selection = ["clip:a"]
        r.inspector.openGroupId = "grade"
        r.inspector.lutAssets = { [Self.film, Self.log] }
        r.inspector.lutStatus = { _ in status }
        return (r, editor)
    }

    func lut(_ editor: TimelineEditor) -> ColorGrading.Lut? { editor.gradeShown(clipId: "clip:a", time: 0).lut }

    func button(_ p: InspectorPanel, _ key: String) -> InspectorRow.Button? {
        for row in p.groups.first(where: { $0.id == "grade" })?.addressableRows ?? [] {
            if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == key }) { return b }
        }
        return nil
    }

    func hit(_ r: RightPanel, _ part: Int) -> CanvasRect? {
        r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.lutRowId, part) })
    }

    // A1: None, every .cube by name, Import LUT…; each pick is one undo step; Remove clears it; undo restores.
    func testPickRemoveAndUndo() throws {
        let (r, editor) = try panel()
        r.inspector.grade.lutOpen = true
        XCTAssertEqual(r.inspector.lutOptions().map(\.label), ["None", "film.cube", "log.cube", "Import LUT…"])
        XCTAssertEqual(button(r.inspector, "lut.remove")?.disabled, true, "nothing to remove")
        let depth = editor.undoStack.count
        try XCTUnwrap(button(r.inspector, "lut.pick.\(Self.film)")).action()
        XCTAssertEqual(lut(editor)?.src, Self.film)
        XCTAssertEqual(editor.undoStack.count, depth + 1, "one undo step")
        try XCTUnwrap(button(r.inspector, "lut.pick.\(Self.film)")).action()
        XCTAssertEqual(editor.undoStack.count, depth + 1, "the LUT already set: no edit")
        try XCTUnwrap(button(r.inspector, "lut.pick.\(Self.log)")).action()
        XCTAssertEqual(lut(editor)?.src, Self.log)
        try XCTUnwrap(button(r.inspector, "lut.remove")).action()
        XCTAssertNil(lut(editor)); XCTAssertEqual(editor.undoStack.count, depth + 3)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(lut(editor)?.src, Self.log, "Remove was one undo step")
        var imports = 0
        r.inspector.onImportLut = { imports += 1 }
        try XCTUnwrap(button(r.inspector, "lut.pick.\(InspectorPanel.lutImport)")).action()
        XCTAssertEqual(imports, 1); XCTAssertEqual(lut(editor)?.src, Self.log, "Import LUT… asks for files, it changes nothing")
    }

    // A1: the select opens the dropdown with the current choice marked; Remove has a text label and a 24 pt target.
    func testTheSelectOpensTheDropdownAndRemoveIsA24ptButton() throws {
        let (r, editor) = try panel()
        r.inspector.grade.lutOpen = true
        let c = PanelMeasureCanvas()
        r.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains("LUT")); XCTAssertTrue(c.drawnStrings.contains("None"))
        XCTAssertNil(hit(r, 1), "no Remove without a LUT")
        let select = try XCTUnwrap(hit(r, 0))
        XCTAssertGreaterThanOrEqual(select.height, 24)
        XCTAssertTrue(r.pointerDown(CanvasPoint(select.midX, select.midY)))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(r.dropdown.options.map(\.value), [InspectorPanel.lutNone, Self.film, Self.log, InspectorPanel.lutImport])
        XCTAssertEqual(r.dropdown.selected, InspectorPanel.lutNone)
        r.dropdown.pick(Self.film)
        XCTAssertEqual(lut(editor)?.src, Self.film)
        c.reset(); r.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains("film.cube")); XCTAssertTrue(c.drawnStrings.contains("Remove"))
        let remove = try XCTUnwrap(hit(r, 1))
        XCTAssertGreaterThanOrEqual(remove.height, 24); XCTAssertGreaterThanOrEqual(remove.width, 24)
        XCTAssertTrue(r.pointerDown(CanvasPoint(remove.midX, remove.midY)))
        XCTAssertNil(lut(editor))
    }

    // A5: closed without a LUT, open by default once one is set, and the user's own open/close wins.
    func testTheSectionIsOpenWhileALutIsSet() throws {
        let (r, editor) = try panel()
        XCTAssertNil(button(r.inspector, "lut.remove"), "closed without a LUT")
        var g = editor.gradeShown(clipId: "clip:a", time: 0); g.lut = .init(src: Self.film, intensity: 1)
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        XCTAssertNotNil(button(r.inspector, "lut.remove"), "open by default with a LUT")
        r.draw(PanelMeasureCanvas(), size: size)
        let toggle = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom("lut:toggle", 0) }))
        XCTAssertTrue(r.pointerDown(CanvasPoint(toggle.midX, toggle.midY)))
        XCTAssertEqual(r.inspector.grade.lutOpen, false)
        XCTAssertNil(button(r.inspector, "lut.remove"), "closed by the user")
    }

    // A3: the grid size; A2: the parser's reason, in the error colour, and nothing else changes.
    func testTheStatusLineShowsTheGridSizeOrWhyTheFileCannotBeRead() throws {
        for (status, expected, colour) in [(LutStatus.loaded(size: 33), "33³ grid", PanelTheme.rowLabel),
                                           (.failed("LUT data rows must contain three numbers at line 12"), "LUT 'film.cube' could not be read:", PanelTheme.red400)] {
            let (r, editor) = try panel(status: status)
            var g = editor.gradeShown(clipId: "clip:a", time: 0); g.lut = .init(src: Self.film, intensity: 1)
            XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
            let c = PanelMeasureCanvas()
            r.draw(c, size: size)
            let line = try XCTUnwrap(c.texts.first { $0.0.hasPrefix(expected) }, "\(expected) is drawn: \(c.drawnStrings)")
            XCTAssertEqual(line.3, colour)
            XCTAssertEqual(line.2.size, 11, "status text is 11 px")
            XCTAssertEqual(lut(editor)?.src, Self.film, "a failed LUT stays chosen; the preview renders without it")
        }
    }

    func testNoProjectLutsSaysHowToAddOne() throws {
        let (r, _) = try panel()
        r.inspector.lutAssets = { [] }
        r.inspector.grade.lutOpen = true
        let c = PanelMeasureCanvas()
        r.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains { $0.hasPrefix("Choose Import LUT…") }, "\(c.drawnStrings)")
    }
}
