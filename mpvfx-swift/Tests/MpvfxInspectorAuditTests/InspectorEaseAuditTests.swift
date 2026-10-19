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
import MpvfxPanels
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// Keyframe easing editor: presets, custom curve handles (fields and the graph's
/// draggable handles), each changing the preview frame and the export graph; and it follows the keys selected on
/// the timeline instead of the playhead's key.
extension InspectorRenderAuditTests {
    /// Position keyed x 0 at 0 s and x 100 at 2 s (clip-local frames 0 and 20), playhead back at 0.
    func keyPositionTwice() {
        guard case .number(let x)? = find("x"), let kf = x.keyframe else { return XCTFail("position has no keyframe button") }
        kf.toggle(); select("V", time: 2); type("x", "100"); select("V", time: 0)
    }
    func key(_ frame: Double) -> NativeInterpolation? {
        editor.outgoing(TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.positionId, frame: frame))
    }

    func testEasePresetsMatchTheEditorPresets() {
        keyPositionTwice()
        guard case .segmented(let s)? = find("easing") else { return XCTFail("no easing row") }
        XCTAssertEqual(s.options.map(\.key), ["linear", "in", "out", "inout", "hold", "custom"])
        XCTAssertEqual(s.options.first { $0.active }?.key, "linear")
        assertVisualEdit("Ease in & out", at: 0.5, { pick("easing", "inout") }) { c in
            XCTAssertLessThan(c.images.first?.rect.x ?? 99, 50, "slow start: behind the linear 50 view px at a quarter")
        }
        XCTAssertEqual(key(0), .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1)))
    }

    func testCustomCurveHandles() {
        keyPositionTwice()
        pick("easing", "custom")
        XCTAssertEqual(key(0), .cubicBezier(InspectorPanel.defaultCubic), "Custom starts from the default curve")
        assertVisualEdit("Cubic Y1", at: 0.5, { type("cubicY1", "2") }) { c in
            XCTAssertGreaterThan(c.images.first?.rect.x ?? 0, 50, "a high first handle runs ahead")
        }
        type("cubicX1", "5")
        guard case .cubicBezier(let p)? = key(0) else { return XCTFail("not a curve") }
        XCTAssertEqual(p.x1, 1, "X handles clamp to 0–1"); XCTAssertEqual(p.y1, 2)
        type("cubicY2", "-9")
        guard case .cubicBezier(let q)? = key(0) else { return XCTFail("not a curve") }
        XCTAssertEqual(q.y2, -1, "Y handles clamp to −1–2")
        XCTAssertFalse(exportRender().frame.isEmpty, "the eased path still exports")
    }

    func testCurveGraphHandleDrags() {
        keyPositionTwice()
        pick("easing", "custom")
        inspector.openGroupId = "layout"
        let c = AuditCanvas()
        inspector.draw(c, in: CanvasRect(x: 0, y: 0, width: 300, height: 1600))
        guard let h1 = inspector.hits.rect(where: { $0 == .custom("ease:curve", 1) }), let box = inspector.easeGraphBox?.box else {
            return XCTFail("the curve graph is not drawn")
        }
        let before = previewFrame(at: 0.5).ops, exportBefore = exportRender()
        // Drag handle 1 to the graph's top-left corner area: x 0, value at the top of the range.
        _ = inspector.pointerDown(CanvasPoint(h1.x + h1.width / 2, h1.y + h1.height / 2))
        _ = inspector.pointerMove(CanvasPoint(box.x, box.y))
        inspector.pointerUp(CanvasPoint(box.x, box.y))
        guard case .cubicBezier(let p)? = key(0) else { return XCTFail("not a curve") }
        XCTAssertEqual(p.x1, 0, accuracy: 0.011); XCTAssertEqual(p.y1, 1, accuracy: 0.011, "the graph's top is value 1 for the default curve")
        XCTAssertNotEqual(previewFrame(at: 0.5).ops, before, "the drag changed the preview")
        XCTAssertNotEqual(exportRender().frame, exportBefore.frame, "and the export")
        XCTAssertNil(inspector.easeDrag, "the draft is gone after release")
    }

    func testEasingFollowsTheTimelineKeyframeSelection() {
        keyPositionTwice()
        // Playhead past the last key: alone, the rows edit that key (whose easing changes nothing on screen).
        select("V", time: 2.5)
        guard case .segmented? = find("easing") else { return XCTFail("no easing row") }
        pick("easing", "hold")
        XCTAssertEqual(key(20), .hold); XCTAssertEqual(key(0), .linear, "without a selection the playhead's key is edited")
        // Select the first diamond on the timeline: the rows now edit it.
        inspector.selectedKeyframes = [TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.positionId, frame: 0)]
        var heading: String?
        for g in inspector.groups { for r in g.rows { if case .heading("Keyframe easing", let t) = r.kind { heading = t } } }
        XCTAssertEqual(heading, "1 selected")
        assertVisualEdit("Ease of the selected key", at: 1, { pick("easing", "hold") }) { c in
            XCTAssertEqual(c.images.first?.rect.x ?? -1, 0, accuracy: 0.5, "the selected first key now holds")
        }
        XCTAssertEqual(key(0), .hold)
        // A selected key of another clip is ignored.
        inspector.selectedKeyframes = [TimelineKeyframeRef(clipId: "M", parameterId: TimelineEditor.positionId, frame: 0)]
        pick("easing", "linear")
        XCTAssertEqual(key(20), .linear, "back to the playhead's key"); XCTAssertEqual(key(0), .hold)
    }
}
