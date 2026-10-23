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
import MpvfxTheme
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// Issue #177, one test per acceptance line: numeric point entry (A1), legible tabs with an edited mark (A2),
/// Reset curve / Reset all (A3), a persistent Delete point and double-click delete (A4), reference lines (A5) and a
/// graph that grows with the panel (A6).
final class CurveEditorUXTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func inspector(_ g: ColorGrading, tab: String = "master", width: Double = 380) throws -> (InspectorPanel, TimelineEditor, () -> Void) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var clock = 1000.0
        editor.now = { clock += 0.01; return clock }   // 10 ms per call: two presses are a double-click
        if g.isAuthored { XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g)) }
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"; p.grade.curveTab = tab
        let c = PanelMeasureCanvas()
        let redraw = { c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: width, height: 5000)) }
        redraw(); redraw()   // the second layout knows the body width
        return (p, editor, redraw)
    }

    func view(_ p: InspectorPanel, _ x: Double, _ y: Double) -> CanvasPoint {
        let b = p.grade.curveBox
        return CanvasPoint(b.x + x * b.width, b.maxY - y * b.height)
    }

    func click(_ p: InspectorPanel, _ at: CanvasPoint, _ redraw: () -> Void) { XCTAssertTrue(p.pointerDown(at)); p.pointerUp(at); redraw() }

    func master(_ e: TimelineEditor) -> [[Double]]? { e.colorGrading(clipId: "clip:a")?.curves["master"] }

    static var midPoint: ColorGrading { var g = ColorGrading(); g.curves["master"] = [[0, 0], [0.5, 0.5], [1, 1]]; return g }

    /// A1: Input 25 and Output 20 typed into the selected point's fields store [0.25, 0.2], one undo step each; with no
    /// point selected the fields read "–" and are disabled, and an end point's Input is disabled.
    func testTypingInputAndOutputSetsThePoint() throws {
        let (p, e, redraw) = try inspector(Self.midPoint)
        XCTAssertEqual(p.number("grade:curve:input")?.text, "–"); XCTAssertEqual(p.number("grade:curve:input")?.disabled, true)
        click(p, view(p, 0.5, 0.5), redraw)
        XCTAssertEqual(p.number("grade:curve:input")?.disabled, false)
        p.number("grade:curve:input")?.commit("25"); redraw()
        p.number("grade:curve:output")?.commit("20"); redraw()
        XCTAssertEqual(master(e)?[1], [0.25, 0.2])
        e.undo()
        XCTAssertEqual(master(e)?[1], [0.25, 0.5], "each typed value is its own undo step")
        p.number("grade:curve:input")?.commit("150"); redraw()
        XCTAssertEqual(master(e)?[1][0], 0.99, "kept inside the white point")
        click(p, view(p, 1, 1), redraw)
        XCTAssertEqual(p.number("grade:curve:input")?.disabled, true, "an end point keeps its input")
        XCTAssertEqual(p.number("grade:curve:output")?.disabled, false)
    }

    /// A1 on a hue curve: degrees across, and Hue/Sat's output in percent of the delta.
    func testHueFieldsReadDegreesAndPercent() throws {
        var g = ColorGrading(); g.hueCurves["hueVsSaturation"] = [[60, 0], [120, 0.5], [180, 0]]
        let (p, e, redraw) = try inspector(g, tab: "hueVsSaturation")
        let b = p.grade.curveBox
        click(p, CanvasPoint(b.x + 120 / 360 * b.width, b.maxY - 0.75 * b.height), redraw)
        XCTAssertEqual(p.number("grade:curve:input")?.text.hasSuffix("°"), true)
        p.number("grade:curve:output")?.commit("-40"); redraw()
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.hueCurves["hueVsSaturation"]?[1], [120, -0.4])
    }

    /// A2: tabs are 24 pt tall targets in 11px text-2 (4.5:1 on the panel in both modes) and only an edited curve's
    /// tab carries the mark.
    func testTabsAreLegibleTargetsAndMarkEditedCurves() throws {
        var g = ColorGrading(); g.curves["red"] = [[0, 0], [0.5, 0.7], [1, 1]]
        let (p, _, _) = try inspector(g)
        XCTAssertEqual(p.editedCurveTabs(g), ["red"])
        for i in InspectorPanel.curveTabs.indices {
            let t = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curvetabs", i) })
            XCTAssertGreaterThanOrEqual(t.height, 24); XCTAssertGreaterThanOrEqual(t.width, 24)
        }
        XCTAssertGreaterThanOrEqual(ThemeTokens.textPairs[2].dark.contrast(ThemeTokens.panelBgPair.dark), 4.5)
        XCTAssertGreaterThanOrEqual(ThemeTokens.textPairs[2].light.contrast(ThemeTokens.panelBgPair.light), 4.5)
        let rec = RecordingCanvas()
        p.draw(rec, in: CanvasRect(x: 0, y: 0, width: 380, height: 5000))
        let red = CanvasColor(ThemeTokens.curveRedPair.now)
        let tabs = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curvetabs", 1) })
        XCTAssertTrue(rec.ops.contains { !$0.isStroke && $0.color == red && $0.points.allSatisfy { CurveGraphTests.contains(tabs, $0) } }, "a red dot on R")
        let green = CanvasColor(ThemeTokens.curveGreenPair.now)
        XCTAssertFalse(rec.ops.contains { !$0.isStroke && $0.color == green }, "no mark on an unedited tab")
    }

    /// A3: Reset curve clears the open tab only; Reset all clears every curve in one undo step.
    func testResetCurveAndResetAll() throws {
        var g = Self.midPoint; g.curves["master"] = [[0, 0.1], [1, 1]]; g.curves["blue"] = [[0, 0], [0.4, 0.6], [1, 1]]
        g.hueCurves["hueVsLuma"] = [[0, 0.2], [120, 0], [240, 0]]; g.adjust["contrast"] = 0.1
        let (p, e, redraw) = try inspector(g)
        for part in [0, 2] {
            let t = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curvefoot", part) })
            XCTAssertGreaterThanOrEqual(t.height, 24); XCTAssertGreaterThanOrEqual(t.width, 24)
        }
        click(p, try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curvefoot", 0) }).curveCenter, redraw)
        XCTAssertNil(master(e)); XCTAssertNotNil(e.colorGrading(clipId: "clip:a")?.curves["blue"])
        click(p, try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curvefoot", 2) }).curveCenter, redraw)
        let cleared = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        XCTAssertTrue(cleared.curves.isEmpty && cleared.hueCurves.isEmpty, "\(cleared.curves) \(cleared.hueCurves)")
        XCTAssertNil(p.hits.rect { $0 == .custom("grade:curvefoot", 2) }, "nothing left to reset")
        e.undo()
        XCTAssertNotNil(e.colorGrading(clipId: "clip:a")?.curves["blue"]); XCTAssertNotNil(e.colorGrading(clipId: "clip:a")?.hueCurves["hueVsLuma"])
    }

    func testResetSaturationCurvesReturnsToFlatDefault() throws {
        for key in ColorGrading.deltaCurveKeys {
            var g = ColorGrading(); g.curves[key] = [[0, 0.8], [0.5, -0.6], [1, -1]]
            let (p, e, redraw) = try inspector(g)
            p.grade.curveTab = key; redraw()
            let reset = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:curvefoot", 0) })
            click(p, reset.curveCenter, redraw)
            XCTAssertNil(e.colorGrading(clipId: "clip:a")?.curves[key])
            XCTAssertEqual(p.currentCurvePoints(e.colorGrading(clipId: "clip:a") ?? ColorGrading()), GradeCurve.flatDelta)
        }
    }

    /// A4: Delete point is always drawn and takes a press only with a removable point selected; a double-click on a
    /// point deletes it, but not on an end point.
    func testDeletePointButtonAndDoubleClick() throws {
        let (p, e, redraw) = try inspector(Self.midPoint)
        XCTAssertNil(p.hits.rect { $0 == .custom("grade:curvefoot", 1) }, "disabled with nothing selected")
        let mid = view(p, 0.5, 0.5)
        click(p, mid, redraw)
        XCTAssertNotNil(p.hits.rect { $0 == .custom("grade:curvefoot", 1) })
        click(p, mid, redraw)
        XCTAssertEqual(master(e), nil, "double-click deleted the middle point, leaving the identity")
        let white = view(p, 1, 1)
        click(p, white, redraw); click(p, white, redraw)
        XCTAssertNil(master(e), "the white point stays: still the identity, two points")
        XCTAssertEqual(p.currentCurvePoints(e.colorGrading(clipId: "clip:a") ?? ColorGrading()).count, 2)
    }

    /// A5: on R the edited Master and G curves draw as faint lines in their own colours; hue tabs draw none.
    func testOtherChannelsDrawAsReferenceLines() throws {
        var g = ColorGrading(); g.curves["master"] = [[0, 0], [0.5, 0.6], [1, 1]]; g.curves["green"] = [[0, 0.2], [1, 1]]
        for (tab, want) in [("red", 2), ("hueVsHue", 0)] {
            let (p, _, _) = try inspector(g, tab: tab)
            let rec = RecordingCanvas()
            p.draw(rec, in: CanvasRect(x: 0, y: 0, width: 380, height: 5000))
            let faint = [ThemeTokens.curveMasterPair, ThemeTokens.curveGreenPair].map { CanvasColor($0.now).withAlpha(0.4) }
            XCTAssertEqual(rec.ops.filter { $0.isStroke && faint.contains($0.color) }.count, want, tab)
            XCTAssertFalse(rec.ops.contains { $0.isStroke && $0.color == CanvasColor(ThemeTokens.curveBluePair.now).withAlpha(0.4) }, "blue is not edited")
        }
    }

    /// A6: the graph is square at the body width (at least 160 pt), and hit-testing follows the drawn size.
    func testGraphGrowsWithThePanel() throws {
        for width in [280.0, 520.0] {
            let (p, _, redraw) = try inspector(Self.midPoint, width: width)
            let side = InspectorPanel.curveGraphSize(width - 32)
            XCTAssertEqual(p.grade.curveBox.width, (side - 2) * 144 / 160, accuracy: 1e-9, "\(width)")
            XCTAssertEqual(p.grade.curveBox.height, p.grade.curveBox.width)
            click(p, view(p, 0.5, 0.5), redraw)
            XCTAssertEqual(p.grade.selectedPoint, 1, "\(width): a press on the drawn point selects it")
        }
        XCTAssertEqual(InspectorPanel.curveGraphSize(100), 160)
    }
}

private extension CanvasRect {
    var curveCenter: CanvasPoint { CanvasPoint(midX, midY) }
}
