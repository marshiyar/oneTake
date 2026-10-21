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

/// The Grade curve editor driven like a user drives it: presses, drags and keys on the inspector, the edits read
/// back from the clip's grade. Each test names the behaviour it holds; the stored curve must always be one the
/// renderer reads as it is stored (`GradeCurve` normalization changes nothing), since a curve it rejects renders as
/// the identity and the user's whole curve disappears from the picture.
final class CurveEditorInteractionTests: XCTestCase {
    struct Rig { let panel: InspectorPanel; let editor: TimelineEditor; let canvas: PanelMeasureCanvas }

    /// The demo project with clip:a's grade set by `set`, the Grade group open on `tab`, drawn once.
    func rig(tab: String = "master", _ set: (inout ColorGrading) -> Void = { _ in }) throws -> Rig {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var g = ColorGrading()
        set(&g)
        if g.isAuthored { XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g)) }
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"
        p.grade.curveTab = tab
        let r = Rig(panel: p, editor: editor, canvas: PanelMeasureCanvas())
        redraw(r)
        return r
    }

    func redraw(_ r: Rig) { r.canvas.reset(); r.panel.draw(r.canvas, in: CanvasRect(x: 0, y: 0, width: 380, height: 4000)) }

    /// The view point of curve value (x, y): RGB tabs 0…1 both ways; hue tabs degrees across, `range` up.
    func view(_ r: Rig, _ x: Double, _ y: Double, hue range: ClosedRange<Double>? = nil) -> CanvasPoint {
        let b = r.panel.grade.curveBox
        let nx = range == nil ? x : x / 360
        let ny = range.map { (y - $0.lowerBound) / ($0.upperBound - $0.lowerBound) } ?? y
        return CanvasPoint(b.x + nx * b.width, b.maxY - ny * b.height)
    }

    func click(_ r: Rig, _ p: CanvasPoint) {
        XCTAssertTrue(r.panel.pointerDown(p)); r.panel.pointerUp(p); redraw(r)
    }

    func drag(_ r: Rig, from a: CanvasPoint, to b: CanvasPoint, steps: Int = 4) {
        XCTAssertTrue(r.panel.pointerDown(a))
        for k in 1...steps {
            let t = Double(k) / Double(steps)
            _ = r.panel.pointerMove(CanvasPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
        }
        r.panel.pointerUp(b); redraw(r)
    }

    func grade(_ r: Rig) -> ColorGrading? { r.editor.colorGrading(clipId: "clip:a") }

    // MARK: Adding points

    /// A click straight below the white point (the graph's right edge) adds a point inside the end points. It used
    /// to store input 1.01, which the renderer clamps onto the white point's input and then drops the whole curve.
    func testClickOnTheRightEdgeAddsAPointTheRendererKeeps() throws {
        let r = try rig { $0.curves["master"] = [[0, 0], [0.5, 0.3], [1, 1]] }
        click(r, view(r, 1, 0.2))
        let s = try XCTUnwrap(grade(r)?.curves["master"])
        XCTAssertEqual(s.count, 4, "\(s)")
        XCTAssertEqual(GradeCurve.normalizedRGB(s), s, "the renderer reads the stored points as they are")
        XCTAssertTrue(s.allSatisfy { (0...1).contains($0[0]) }, "\(s)")
    }

    /// Enter adds a point where there is none. It used to add one at input 0.5 whatever was there, so on a curve
    /// with a point at 0.5 the two shared an input and the renderer dropped the curve.
    func testEnterAddsAPointWhereNoneIs() throws {
        let r = try rig { $0.curves["master"] = [[0, 0], [0.5, 0.25], [1, 1]] }
        XCTAssertTrue(r.panel.keyDown(EditorKey(.enter)))
        let s = try XCTUnwrap(grade(r)?.curves["master"])
        XCTAssertEqual(s.count, 4, "\(s)")
        XCTAssertEqual(GradeCurve.normalizedRGB(s), s, "no two points on one input: \(s)")
        XCTAssertEqual(ColorCurveMath.sample(s, at: 0.5), 0.25, accuracy: 1e-9, "the 0.5 point is kept")
    }

    /// The first click on an empty hue curve changes the picture at that hue, and only near it. A hue curve needs
    /// three points, so one point used to render nothing until the user had added two more.
    func testFirstPointOnAnEmptyHueCurveTakesEffect() throws {
        let r = try rig(tab: "hueVsSaturation")
        click(r, view(r, 120, 0.5, hue: -1...1))
        let s = try XCTUnwrap(grade(r)?.hueCurves["hueVsSaturation"])
        XCTAssertEqual(s.count, 3, "\(s)")
        XCTAssertEqual(ColorCurveMath.sampleHue(s, at: 120, limit: -1...1), 0.5, accuracy: 0.01, "\(s)")
        XCTAssertEqual(ColorCurveMath.sampleHue(s, at: 300, limit: -1...1), 0, accuracy: 1e-9, "the change stays near the hue clicked")
    }

    // MARK: Selecting and dragging

    /// A click on a point selects it and leaves it where it is (it used to jump to the pointer and commit).
    func testClickSelectsAPointWithoutMovingIt() throws {
        let curve: [[Double]] = [[0, 0], [0.5, 0.3], [1, 1]]
        let r = try rig { $0.curves["master"] = curve }
        let p = view(r, 0.5, 0.3)
        click(r, CanvasPoint(p.x + 5, p.y - 5))
        XCTAssertEqual(grade(r)?.curves["master"], curve)
        XCTAssertEqual(r.panel.grade.selectedPoint, 1)
    }

    /// A point's pointer target is 24 pt across: a press 11 pt beside it selects it instead of adding a point.
    func testPointTargetIs24PointsAcross() throws {
        let curve: [[Double]] = [[0, 0], [0.5, 0.3], [1, 1]]
        let r = try rig { $0.curves["master"] = curve }
        let p = view(r, 0.5, 0.3)
        click(r, CanvasPoint(p.x + 11, p.y))
        XCTAssertEqual(grade(r)?.curves["master"], curve)
        XCTAssertEqual(r.panel.grade.selectedPoint, 1)
    }

    /// Dragging the black point moves only its output: the curve always starts on input 0, at a handle.
    func testEndPointDragKeepsItsInput() throws {
        let r = try rig()
        drag(r, from: view(r, 0, 0), to: view(r, 0.3, 0.2))
        let s = try XCTUnwrap(grade(r)?.curves["master"])
        XCTAssertEqual(s.first?[0], 0)
        XCTAssertEqual(s.first?[1] ?? -1, 0.2, accuracy: 0.002)
        XCTAssertEqual(s.count, 2)
    }

    /// A drag is one undo step, however many moves it has.
    func testOneDragIsOneUndoStep() throws {
        let curve: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
        let r = try rig { $0.curves["master"] = curve; $0.adjust["contrast"] = 0.1 }
        drag(r, from: view(r, 0.5, 0.5), to: view(r, 0.6, 0.8), steps: 6)
        let s = try XCTUnwrap(grade(r)?.curves["master"])
        XCTAssertEqual(s[1][0], 0.6, accuracy: 0.002); XCTAssertEqual(s[1][1], 0.8, accuracy: 0.002)
        r.editor.undo()
        XCTAssertEqual(grade(r)?.curves["master"], curve)
    }

    // MARK: Deleting

    /// The end points stay: Delete on a selected end point leaves the curve as it is.
    func testEndPointsAreNotDeleted() throws {
        let curve: [[Double]] = [[0, 0.1], [0.5, 0.5], [1, 0.9]]
        let r = try rig { $0.curves["master"] = curve }
        click(r, view(r, 0, 0.1))
        XCTAssertEqual(r.panel.grade.selectedPoint, 0)
        _ = r.panel.keyDown(EditorKey(.delete))
        XCTAssertEqual(grade(r)?.curves["master"], curve)
    }

    /// Deleting a hue curve's point below three points clears the curve: two points render nothing, so keeping them
    /// would show handles that do nothing.
    func testDeletingAHuePointBelowThreeClearsTheCurve() throws {
        let r = try rig(tab: "hueVsLuma") { $0.hueCurves["hueVsLuma"] = [[0, 0.2], [120, 0.4], [240, 0.2]]; $0.adjust["contrast"] = 0.1 }
        click(r, view(r, 120, 0.4, hue: -1...1))
        XCTAssertEqual(r.panel.grade.selectedPoint, 1)
        XCTAssertTrue(r.panel.keyDown(EditorKey(.delete)))
        let g = try XCTUnwrap(grade(r))
        XCTAssertNil(g.hueCurves["hueVsLuma"], "\(g.hueCurves)")
    }

    // MARK: Robustness and targets

    /// A curve tab key that names no tab (the field is public) draws the Master curve instead of trapping.
    func testUnknownCurveTabDrawsMaster() throws {
        let r = try rig()
        r.panel.grade.curveTab = "no-such-tab"
        redraw(r)
        XCTAssertNotNil(r.panel.hits.rect { $0 == .custom("grade:curve", 0) })
    }

    /// The footer's Delete and reset are pointer targets at least 24 pt each way.
    func testFooterTargetsAre24PointsAcross() throws {
        let r = try rig { $0.curves["master"] = [[0, 0], [0.5, 0.3], [1, 1]] }
        click(r, view(r, 0.5, 0.3))
        let del = try XCTUnwrap(r.panel.hits.rect { $0 == .custom("grade:curvefoot", 1) })
        let reset = try XCTUnwrap(r.panel.hits.rect { $0 == .custom("grade:curvefoot", 0) })
        for t in [del, reset] {
            XCTAssertGreaterThanOrEqual(t.width, 24, "\(t)"); XCTAssertGreaterThanOrEqual(t.height, 24, "\(t)")
        }
    }

    /// Hundreds of presses and drags anywhere on and around the graph, on every tab: after each one the stored
    /// curve is one the renderer reads exactly as stored (sorted, in range, no shared input, 2…16 or 3…16 points).
    func testEveryEditLeavesACurveTheRendererReadsAsStored() throws {
        var seed: UInt64 = 0x5EED
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for tab in InspectorPanel.curveTabs {
            let r = try rig(tab: tab.key) { $0.adjust["contrast"] = 0.1 }
            let box = r.panel.grade.curveBox
            func anywhere() -> CanvasPoint { CanvasPoint(box.x - 10 + next() * (box.width + 20), box.y - 10 + next() * (box.height + 20)) }
            for step in 0..<80 {
                if next() < 0.5 { click(r, anywhere()) } else { drag(r, from: anywhere(), to: anywhere(), steps: 3) }
                if next() < 0.1 { _ = r.panel.keyDown(EditorKey(.enter)) }
                if next() < 0.1 { _ = r.panel.keyDown(EditorKey(.delete)) }
                redraw(r)
                let g = try XCTUnwrap(grade(r))
                if tab.hue {
                    guard let s = g.hueCurves[tab.key] else { continue }
                    XCTAssertEqual(GradeCurve.normalizedHue(s, limit: tab.min...tab.max), s, "\(tab.key) step \(step)")
                    XCTAssertGreaterThanOrEqual(s.count, 3, "\(tab.key) step \(step): \(s)")
                } else {
                    guard let s = g.curves[tab.key] else { continue }
                    XCTAssertEqual(GradeCurve.normalizedRGB(s), s, "\(tab.key) step \(step)")
                }
            }
        }
    }
}
