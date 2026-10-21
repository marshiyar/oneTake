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
import XCTest
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// Issue #171: Enter or Space on a focused wheel, level bar or curve graph replayed a pointer press at the control's
/// centre, which set the wheel's amount (or the level) to 0, or added a curve point at the graph's centre, from the
/// keyboard and without a word. The focused curve graph now takes the keys an editor expects instead.
final class GradeKeyboardTests: XCTestCase {
    func inspector(_ g: ColorGrading, tab: String = "master") throws -> (InspectorPanel, TimelineEditor, PanelMeasureCanvas) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var clock = 1000.0
        editor.now = { clock += 0.01; return clock }   // 10 ms per edit: inside the coalescing window, whatever the machine's load
        if g.isAuthored { XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g)) }
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"; p.grade.curveTab = tab
        let c = PanelMeasureCanvas()
        redraw(p, c)
        return (p, editor, c)
    }

    func redraw(_ p: InspectorPanel, _ c: PanelMeasureCanvas) { c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 380, height: 4000)) }

    func focus(_ p: InspectorPanel, _ c: PanelMeasureCanvas, _ hit: InspectorPanel.Hit) throws {
        XCTAssertNotNil(p.hits.rect { $0 == hit }, "\(hit) is drawn")
        p.focus.current = hit; p.focus.visible = true
    }

    /// A1 / A3: Space on the focused graph changes nothing; Enter adds a point in the widest gap and selects it.
    func testSpaceOnTheFocusedGraphChangesNothingAndEnterAddsAPoint() throws {
        var g = ColorGrading()
        g.curves["master"] = [[0, 0], [0.2, 0.3], [1, 1]]
        let (p, editor, c) = try inspector(g)
        try focus(p, c, .custom("grade:curve", 0))
        XCTAssertTrue(p.keyDown(EditorKey(.space)))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), g)
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        let s = try XCTUnwrap(editor.colorGrading(clipId: "clip:a")?.curves["master"])
        XCTAssertEqual(s.count, 4); XCTAssertEqual(s[2][0], 0.6, "the middle of the widest gap, 0.2…1")
        XCTAssertEqual(p.grade.selectedPoint, 2)
    }

    /// A3: Left / Right select points; Up / Down move the output and Alt+Left / Alt+Right the input by 0.01
    /// (Shift: 0.1); an RGB end point keeps its input; Delete removes the selected point.
    func testArrowsSelectAndMoveTheFocusedGraphsPoints() throws {
        var g = ColorGrading()
        g.curves["master"] = [[0, 0], [0.5, 0.5], [1, 1]]
        let (p, editor, c) = try inspector(g)
        func curve() -> [[Double]]? { editor.colorGrading(clipId: "clip:a")?.curves["master"] }
        try focus(p, c, .custom("grade:curve", 0))
        XCTAssertTrue(p.keyDown(EditorKey(.right))); XCTAssertEqual(p.grade.selectedPoint, 0, "Right with nothing selected: the first point")
        XCTAssertTrue(p.keyDown(EditorKey(.up)))
        XCTAssertEqual(curve()?[0], [0, 0.01])
        XCTAssertTrue(p.keyDown(EditorKey(.right, alt: true)))
        XCTAssertEqual(curve()?[0], [0, 0.01], "the black point keeps input 0")
        XCTAssertTrue(p.keyDown(EditorKey(.right))); XCTAssertEqual(p.grade.selectedPoint, 1)
        XCTAssertTrue(p.keyDown(EditorKey(.right, alt: true)))
        XCTAssertTrue(p.keyDown(EditorKey(.down, shift: true)))
        XCTAssertEqual(curve()?[1], [0.51, 0.4])
        XCTAssertTrue(p.keyDown(EditorKey(.right))); XCTAssertTrue(p.keyDown(EditorKey(.right)))
        XCTAssertEqual(p.grade.selectedPoint, 2, "Right stops at the last point")
        XCTAssertTrue(p.keyDown(EditorKey(.left)))
        XCTAssertTrue(p.keyDown(EditorKey(.delete)))
        XCTAssertEqual(curve(), [[0, 0.01], [1, 1]])
    }

    /// A held arrow (repeats inside the coalescing window) is one undo step.
    func testAHeldArrowIsOneUndoStep() throws {
        var g = ColorGrading()
        g.curves["master"] = [[0, 0], [0.5, 0.5], [1, 1]]
        let (p, editor, c) = try inspector(g)
        try focus(p, c, .custom("grade:curve", 0))
        p.grade.selectedPoint = 1
        let steps = editor.undoStack.count
        for k in 0..<10 { XCTAssertTrue(p.keyDown(EditorKey(.up, isRepeat: k > 0))) }
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a")?.curves["master"]?[1][1] ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(editor.undoStack.count, steps + 1)
        editor.undo()
        XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), g)
    }
}
