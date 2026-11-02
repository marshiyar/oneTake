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
@testable import MpvfxPanels
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes

final class GradeCurveKeyframeInspectorTests: XCTestCase {
    static let points: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
    static let ids = NativeGradeParameter.curveIds("master", count: 3)

    func make(time: Double = 1) throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        var clock = 1000.0
        editor.now = { clock += 0.01; return clock }
        var g = ColorGrading()
        g.curves["master"] = Self.points
        g.curves["red"] = [[0, 0], [0.5, 0.3], [1, 1]]
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.time = time
        p.openGroupId = "grade"
        redraw(p)
        return (p, editor)
    }

    func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 360, height: 8000)) }

    func click(_ p: InspectorPanel, _ hit: InspectorPanel.Hit) throws {
        let r = try XCTUnwrap(p.hits.rect { $0 == hit }, "\(hit) is drawn")
        let point = CanvasPoint(r.midX, r.midY)
        XCTAssertTrue(p.pointerDown(point)); p.pointerUp(point)
        redraw(p)
    }

    func keys(_ e: TimelineEditor, _ pid: String) throws -> [NativeKeyframe] {
        try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.first { $0.parameterId == pid }?.keyframes ?? []
    }

    func drag(_ p: InspectorPanel, from: [Double], to: [Double]) throws {
        let start = p.curveToView(from), end = p.curveToView(to)
        XCTAssertTrue(p.pointerDown(start))
        XCTAssertTrue(p.pointerMove(end))
        p.pointerUp(end)
        redraw(p)
    }

    func testStopwatchKeysEveryPointOfTheShownCurve() throws {
        let (p, e) = try make()
        XCTAssertNotNil(p.hits.rect { $0 == .stopwatch("grade:curvekey") })
        let undo = e.undoStack.count
        try click(p, .stopwatch("grade:curvekey"))
        for (i, id) in Self.ids.enumerated() {
            XCTAssertEqual(try keys(e, id).map(\.frame), [30])
            XCTAssertEqual(try keys(e, id).map(\.value), [.number(Self.points[i / 2][i % 2])])
        }
        XCTAssertEqual(e.undoStack.count, undo + 1)
        XCTAssertEqual(p.keyframe("grade:curvekey")?.state, .onKey)
        XCTAssertTrue(e.undo())
        for id in Self.ids { XCTAssertTrue(try keys(e, id).isEmpty) }
    }

    func testDraggingAnAnimatedPointKeysOnlyItsChangedCoordinates() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; redraw(p)
        XCTAssertEqual(p.keyframe("grade:curvekey")?.state, .animated)
        let undo = e.undoStack.count
        try drag(p, from: [0.5, 0.5], to: [0.6, 0.8])
        for id in Self.ids {
            XCTAssertEqual(try keys(e, id).map(\.frame), id.contains(".1.") ? [30, 90] : [30])
        }
        XCTAssertEqual(try keys(e, NativeGradeParameter.curveId("master", 1, "x")).last?.value, .number(0.6))
        XCTAssertEqual(try keys(e, NativeGradeParameter.curveId("master", 1, "y")).last?.value, .number(0.8))
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], Self.points)
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).curves["master"]?[1], [0.6, 0.8])
        XCTAssertEqual(e.undoStack.count, undo + 1)
    }

    func testNumberFieldsCommitThroughTheAnimatedGradePath() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; p.grade.selectedPoint = 1; redraw(p)
        try XCTUnwrap(p.number("grade:curve:input")).commit("60")
        redraw(p)
        try XCTUnwrap(p.number("grade:curve:output")).commit("80")
        XCTAssertEqual(try keys(e, NativeGradeParameter.curveId("master", 1, "x")).last?.value, .number(0.6))
        XCTAssertEqual(try keys(e, NativeGradeParameter.curveId("master", 1, "y")).last?.value, .number(0.8))
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], Self.points)
        for id in Self.ids where !id.contains(".1.") { XCTAssertEqual(try keys(e, id).map(\.frame), [30]) }
    }

    func testAddingRemovingAndResettingPointsAreRefusedWhileAnimated() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:curvekey"))
        let undo = e.undoStack.count
        let graph = try XCTUnwrap(p.customRow("grade:curve"))
        let empty = p.curveToView([0.25, 0.8])
        graph.pointer(0, empty, 0); graph.pointer(0, empty, 2)
        let middle = p.curveToView([0.5, 0.5])
        for _ in 0..<2 { graph.pointer(0, middle, 0); graph.pointer(0, middle, 2) }
        p.grade.selectedPoint = 1
        XCTAssertTrue(graph.keyPress?(0, EditorKey(.delete)) == true)
        XCTAssertTrue(graph.keyPress?(0, EditorKey(.backspace)) == true)
        XCTAssertTrue(graph.keyPress?(0, EditorKey(.enter)) == true)
        XCTAssertTrue(p.gradeKey(EditorKey(.delete)))
        XCTAssertTrue(p.gradeKey(EditorKey(.enter)))
        let footer = try XCTUnwrap(p.customRow("grade:curvefoot"))
        for part in 0...2 { footer.pointer(part, middle, 0) }
        redraw(p)
        XCTAssertEqual(p.curveFooterButtons(e.gradeShown(clipId: "clip:a", time: p.time)).map(\.enabled), [false, false, false])
        for part in 0...2 { XCTAssertNil(p.hits.rect { $0 == .custom("grade:curvefoot", part) }) }
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], Self.points)
        XCTAssertEqual(try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.map(\.parameterId).sorted(), Self.ids.sorted())
        XCTAssertEqual(e.undoStack.count, undo)
    }

    func testStopwatchOffKeepsThePlayheadCurveAndRemovesItsTracks() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; redraw(p)
        try drag(p, from: [0.5, 0.5], to: [0.6, 0.8])
        let undo = e.undoStack.count
        try click(p, .stopwatch("grade:curvekey"))
        for id in Self.ids { XCTAssertTrue(try keys(e, id).isEmpty) }
        XCTAssertTrue(try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.isEmpty)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], [[0, 0], [0.6, 0.8], [1, 1]])
        XCTAssertEqual(e.undoStack.count, undo + 1)
        XCTAssertFalse(p.activeCurveIsAnimated)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(try keys(e, NativeGradeParameter.curveId("master", 1, "y")).map(\.frame), [30, 90])
    }

    func testAnotherCurveTabKeepsItsValuesAndCanStillBeEdited() throws {
        let (p, e) = try make()
        let red = e.colorGrading(clipId: "clip:a")?.curves["red"]
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; redraw(p)
        try drag(p, from: [0.5, 0.5], to: [0.6, 0.8])
        try click(p, .stopwatch("grade:curvekey"))
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["red"], red)
        for id in NativeGradeParameter.curveIds("red", count: 3) { XCTAssertTrue(try keys(e, id).isEmpty) }
        try click(p, .stopwatch("grade:curvekey"))
        try click(p, .custom("grade:curvetabs", 1))
        XCTAssertFalse(p.activeCurveIsAnimated)
        XCTAssertEqual(p.keyframe("grade:curvekey")?.state, InspectorRow.KeyframeState.none)
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["red"]?.count, 4)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"]?.count, 3)
    }

    func testDiamondAndNavigationResolveThroughTheCurveControlKey() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; redraw(p)
        try click(p, .keyframe("grade:curvekey"))
        for id in Self.ids { XCTAssertEqual(try keys(e, id).map(\.frame), [30, 90]) }
        p.time = 2; redraw(p)
        var seeks: [Double] = []
        p.onSeek = { seeks.append($0) }
        try click(p, .kfPrev("grade:curvekey"))
        try click(p, .kfNext("grade:curvekey"))
        XCTAssertEqual(seeks, [1, 3])
        p.time = 3; redraw(p)
        try click(p, .keyframe("grade:curvekey"))
        for id in Self.ids { XCTAssertEqual(try keys(e, id).map(\.frame), [30]) }
    }

    func testOneAnimatedCoordinateLocksOnlyItsCurve() throws {
        let (p, e) = try make()
        let id = NativeGradeParameter.curveId("master", 1, "y")
        XCTAssertTrue(e.setAnimated(clipId: "clip:a", [(id, .number(0.5))], true, time: 1))
        redraw(p)
        p.grade.selectedPoint = 1
        XCTAssertTrue(p.activeCurveIsAnimated)
        XCTAssertTrue(p.gradeKey(EditorKey(.delete)))
        XCTAssertTrue(p.gradeKey(EditorKey(.enter)))
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], Self.points)
        try click(p, .custom("grade:curvetabs", 1))
        XCTAssertFalse(p.activeCurveIsAnimated)
        let footer = try XCTUnwrap(p.customRow("grade:curvefoot"))
        footer.pointer(2, CanvasPoint(0, 0), 0)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], Self.points)
        XCTAssertEqual(try keys(e, id).count, 1)
        XCTAssertNil(p.hits.rect { $0 == .custom("grade:curvefoot", 2) })
    }

    func testEmptyHueCurveHasNoKeyframeControls() throws {
        let (p, _) = try make()
        try click(p, .custom("grade:curvetabs", 4))
        XCTAssertNil(p.hits.rect { $0 == .stopwatch("grade:curvekey") })
        XCTAssertNil(p.keyframe("grade:curvekey"))
    }

    func testHueCurveStopwatchUsesTheShownTab() throws {
        let (p, e) = try make()
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        let points: [[Double]] = [[0, 10], [120, 20], [240, -10]]
        g.hueCurves["hueVsHue"] = points
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        redraw(p)
        try click(p, .custom("grade:curvetabs", 4))
        try click(p, .stopwatch("grade:curvekey"))
        let ids = NativeGradeParameter.curveIds("hueVsHue", count: 3, hue: true)
        for (i, id) in ids.enumerated() {
            XCTAssertEqual(try keys(e, id).map(\.value), [.number(points[i / 2][i % 2])])
        }
        for id in Self.ids { XCTAssertTrue(try keys(e, id).isEmpty) }
        XCTAssertTrue(p.activeCurveIsAnimated)
    }

    func testNumberFieldKeysAnAnimatedEndpointReturningToIdentity() throws {
        let (p, e) = try make()
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        let initial: [[Double]] = [[0, 0], [1, 0.8]]
        g.curves["master"] = initial
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        redraw(p)
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; p.grade.selectedPoint = 1; redraw(p)
        try XCTUnwrap(p.number("grade:curve:output")).commit("100")
        let id = NativeGradeParameter.curveId("master", 1, "y")
        XCTAssertEqual(try keys(e, id).map(\.frame), [30, 90])
        XCTAssertEqual(try keys(e, id).last?.value, .number(1))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).curves["master"], GradeCurve.identity)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], initial)
    }

    func testDraggingAnimatedEndpointToIdentityKeysOnlyItsOutput() throws {
        let (p, e) = try make()
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        let initial: [[Double]] = [[0, 0], [1, 0.8]]
        g.curves["master"] = initial
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        redraw(p)
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; redraw(p)
        try drag(p, from: [1, 0.8], to: [1, 1])
        let output = NativeGradeParameter.curveId("master", 1, "y")
        for id in NativeGradeParameter.curveIds("master", count: 2) {
            XCTAssertEqual(try keys(e, id).map(\.frame), id == output ? [30, 90] : [30])
        }
        XCTAssertEqual(try keys(e, output).last?.value, .number(1))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).curves["master"], GradeCurve.identity)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], initial)
    }

    func testNumberFieldKeysAnAnimatedDeltaCurveReturningToFlat() throws {
        let (p, e) = try make()
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        let initial: [[Double]] = [[0, 0], [1, 0.2]]
        g.curves["lumaVsSaturation"] = initial
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        redraw(p)
        try click(p, .custom("grade:curvetabs", 7))
        try click(p, .stopwatch("grade:curvekey"))
        p.time = 3; p.grade.selectedPoint = 1; redraw(p)
        try XCTUnwrap(p.number("grade:curve:output")).commit("0")
        let id = NativeGradeParameter.curveId("lumaVsSaturation", 1, "y")
        XCTAssertEqual(try keys(e, id).map(\.frame), [30, 90])
        XCTAssertEqual(try keys(e, id).last?.value, .number(0))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).curves["lumaVsSaturation"], GradeCurve.flatDelta)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["lumaVsSaturation"], initial)
    }

    func testCurveKeyframeControlsAreDrawnForEachStoredTab() throws {
        let (p, e) = try make()
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        for tab in InspectorPanel.curveTabs {
            if tab.hue { g.hueCurves[tab.key] = [[0, 0], [120, 0], [240, 0]] }
            else { g.curves[tab.key] = Self.points }
        }
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        for (index, tab) in InspectorPanel.curveTabs.enumerated() {
            redraw(p)
            try click(p, .custom("grade:curvetabs", index))
            XCTAssertNotNil(p.hits.rect { $0 == .stopwatch("grade:curvekey") }, tab.key)
            XCTAssertNotNil(p.keyframe("grade:curvekey"), tab.key)
            try click(p, .stopwatch("grade:curvekey"))
            for id in NativeGradeParameter.curveIds(tab.key, count: 3, hue: tab.hue) {
                XCTAssertEqual(try keys(e, id).map(\.frame), [30], tab.key)
            }
        }
    }

    func testFooterIgnoresDragAndReleaseAndLocksOnlyAffectedActions() throws {
        let (p, e) = try make()
        p.grade.selectedPoint = 1; redraw(p)
        let footer = try XCTUnwrap(p.customRow("grade:curvefoot"))
        let before = e.colorGrading(clipId: "clip:a"), undo = e.undoStack.count
        for phase in [1, 2] {
            for part in 0...2 { footer.pointer(part, CanvasPoint(0, 0), phase) }
        }
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), before)
        XCTAssertEqual(e.undoStack.count, undo)
        // A retained footer must check animation live after its row was built.
        try click(p, .stopwatch("grade:curvekey"))
        for part in 0...2 { footer.pointer(part, CanvasPoint(0, 0), 0) }
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), before)
        try click(p, .custom("grade:curvetabs", 1))
        p.grade.selectedPoint = 1; redraw(p)
        let shown = e.gradeShown(clipId: "clip:a", time: p.time)
        XCTAssertEqual(p.curveFooterButtons(shown).map(\.enabled), [true, true, false])
        // Reset all affects animated channels too, so it stays disabled; Reset curve edits Red.
        try click(p, .custom("grade:curvefoot", 0))
        XCTAssertNil(e.colorGrading(clipId: "clip:a")?.curves["red"])
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.curves["master"], Self.points)
        for id in Self.ids { XCTAssertEqual(try keys(e, id).map(\.frame), [30]) }
    }

}
