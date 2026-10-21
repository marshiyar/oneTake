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
import Foundation
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import MpvfxTimeline
@testable import MpvfxPanels
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// Keyframe easing, edited in the Keyframe Easing panel that the inspector's "Easing…" opens: presets, custom curve
/// numbers and the curve's draggable handles, each changing the preview frame and the export graph; and the panel
/// follows the keys selected on the timeline instead of the playhead's key.
extension InspectorRenderAuditTests {
    /// Position keyed x 0 at 0 s and x 100 at 2 s (clip-local frames 0 and 20), playhead back at 0.
    func keyPositionTwice() {
        guard case .number(let x)? = find("x"), let kf = x.keyframe else { return XCTFail("position has no keyframe button") }
        kf.toggle(); select("V", time: 2); type("x", "100"); select("V", time: 0)
    }
    func key(_ frame: Double) -> NativeInterpolation? {
        editor.outgoing(TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.positionId, frame: frame))
    }

    /// The panel as "Easing…" opens it (the inspector hands it the clip and its keys, as RightPanel does), drawn.
    func easingPanel(file: StaticString = #filePath, line: UInt = #line) -> KeyframeEasingPanel {
        let p = KeyframeEasingPanel()
        p.editor = editor; p.time = inspector.time; p.selectedKeyframes = inspector.selectedKeyframes
        inspector.onOpenEasing = { clip, refs in
            p.clipId = clip
            p.state.chosenProperty = refs.sorted(by: KeyframeEasingTarget.inTimeOrder).first?.parameterId
        }
        press("openEasing", file: file, line: line)
        p.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 900))
        return p
    }
    func tap(_ p: KeyframeEasingPanel, _ hit: KeyframeEasingPanel.Hit, file: StaticString = #filePath, line: UInt = #line) {
        guard let r = p.hits.rect(where: { $0 == hit }) else { return XCTFail("\(hit) is not drawn", file: file, line: line) }
        let c = CanvasPoint(r.midX, r.midY)
        p.pointerDown(c); p.pointerUp(c); p.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 900))
    }
    /// Picks a preset in the panel opened from the inspector.
    func ease(_ preset: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(easingPanel(file: file, line: line), .preset(preset), file: file, line: line)
    }
    func typeInPanel(_ p: KeyframeEasingPanel, _ field: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(p, .field(field), file: file, line: line)
        for _ in 0..<12 { p.keyDown(EditorKey(.backspace)) }
        for ch in text { p.keyDown(EditorKey(.char(ch))) }
        p.keyDown(EditorKey(.enter)); p.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 900))
    }

    func testEasePresetsMatchTheEditorPresets() {
        keyPositionTwice()
        let p = easingPanel()
        let keys = p.hits.regions.compactMap { r -> String? in if case .preset(let k) = r.action { return k }; return nil }
        XCTAssertEqual(keys, ["linear", "in", "out", "inout", "hold"])
        XCTAssertEqual(key(0), .linear)
        assertVisualEdit("Ease in & out", at: 0.5, { tap(p, .preset("inout")) }) { c in
            XCTAssertLessThan(c.images.first?.rect.x ?? 99, 50, "slow start: behind the linear 50 view px at a quarter")
        }
        XCTAssertEqual(key(0), .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1)))
    }

    func testCustomCurveHandles() {
        keyPositionTwice()
        let p = easingPanel()
        tap(p, .preset("inout"))
        assertVisualEdit("Cubic Y1", at: 0.5, { typeInPanel(p, "y1", "2") }) { c in
            XCTAssertGreaterThan(c.images.first?.rect.x ?? 0, 50, "a high first handle runs ahead")
        }
        typeInPanel(p, "x1", "5")
        guard case .cubicBezier(let q)? = key(0) else { return XCTFail("not a curve") }
        XCTAssertEqual(q.x1, 1, "X handles clamp to 0–1"); XCTAssertEqual(q.y1, 2)
        typeInPanel(p, "y2", "-9")
        guard case .cubicBezier(let r)? = key(0) else { return XCTFail("not a curve") }
        XCTAssertEqual(r.y2, -1, "Y handles clamp to −1–2")
        XCTAssertFalse(exportRender().frame.isEmpty, "the eased path still exports")
    }

    func testCurveGraphHandleDrags() {
        keyPositionTwice()
        let p = easingPanel()
        tap(p, .preset("inout"))
        guard let h1 = p.hits.rect(where: { $0 == .curveHandle(1) }), let plot = p.curveBox?.plot else {
            return XCTFail("the curve graph is not drawn")
        }
        let before = previewFrame(at: 0.5).ops, exportBefore = exportRender()
        // Drag handle 1 to the plot's top-left corner: x 0, value 1 (the top of the 0…1 range of this curve).
        p.pointerDown(CanvasPoint(h1.midX, h1.midY))
        p.pointerMove(CanvasPoint(plot.x, plot.y))
        p.pointerUp(CanvasPoint(plot.x, plot.y))
        guard case .cubicBezier(let q)? = key(0) else { return XCTFail("not a curve") }
        XCTAssertEqual(q.x1, 0, accuracy: 0.011); XCTAssertEqual(q.y1, 1, accuracy: 0.011)
        XCTAssertNotEqual(previewFrame(at: 0.5).ops, before, "the drag changed the preview")
        XCTAssertNotEqual(exportRender().frame, exportBefore.frame, "and the export")
        XCTAssertNil(p.drag, "the draft is gone after release")
    }

    func testEasingFollowsTheTimelineKeyframeSelection() {
        keyPositionTwice()
        // Playhead past the last key: alone, the panel edits that key (whose easing changes nothing on screen).
        select("V", time: 2.5)
        ease("hold")
        XCTAssertEqual(key(20), .hold); XCTAssertEqual(key(0), .linear, "without a selection the playhead's key is edited")
        // Select the first diamond on the timeline: the inspector counts it and the panel edits it.
        inspector.selectedKeyframes = [TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.positionId, frame: 0)]
        var heading: String?
        for g in inspector.groups { for r in g.rows { if case .heading("Keyframe easing", let t) = r.kind { heading = t } } }
        XCTAssertEqual(heading, "1 selected")
        assertVisualEdit("Ease of the selected key", at: 1, { ease("hold") }) { c in
            XCTAssertEqual(c.images.first?.rect.x ?? -1, 0, accuracy: 0.5, "the selected first key now holds")
        }
        XCTAssertEqual(key(0), .hold)
        // A selected key of another clip is ignored.
        inspector.selectedKeyframes = [TimelineKeyframeRef(clipId: "M", parameterId: TimelineEditor.positionId, frame: 0)]
        ease("linear")
        XCTAssertEqual(key(20), .linear, "back to the playhead's key"); XCTAssertEqual(key(0), .hold)
    }
}
