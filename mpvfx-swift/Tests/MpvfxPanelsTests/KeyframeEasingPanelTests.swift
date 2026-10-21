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
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Keyframe Easing panel's interaction: what it shows for the selection, presets and disabled engine controls,
/// handle drags that commit once on release, typed numbers, zoom and pan, copy / paste, saved presets, the preview.
final class KeyframeEasingPanelTests: XCTestCase {
    let rot = TimelineEditor.rotationId
    let box = CanvasRect(x: 0, y: 0, width: 320, height: 760)

    /// clip:a: position keyed at 0, 60, 120; rotation 0° at 0, 90° at 30 (30 fps); rotation's first key selected.
    func make() throws -> (KeyframeEasingPanel, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        for (f, v) in [(0.0, 0.0), (30, 90)] {
            let a = try XCTUnwrap(e.parameterAddress(clipId: "clip:a", rot))
            XCTAssertTrue(e.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: f, value: .number(v), baselineValue: .number(v))))))
        }
        let p = KeyframeEasingPanel()
        p.editor = e; p.clipId = "clip:a"; p.selectedKeyframes = [ref(0)]
        draw(p)
        return (p, e)
    }
    func ref(_ f: Double, _ pid: String? = nil) -> TimelineKeyframeRef { TimelineKeyframeRef(clipId: "clip:a", parameterId: pid ?? rot, frame: f) }
    @discardableResult func draw(_ p: KeyframeEasingPanel) -> PanelMeasureCanvas {
        let c = PanelMeasureCanvas(); p.draw(c, in: box); return c
    }
    func center(_ p: KeyframeEasingPanel, _ h: KeyframeEasingPanel.Hit) throws -> CanvasPoint {
        let r = try XCTUnwrap(p.hits.rect { $0 == h }, "\(h) is not drawn")
        return CanvasPoint(r.midX, r.midY)
    }
    func click(_ p: KeyframeEasingPanel, _ h: KeyframeEasingPanel.Hit) throws {
        let pt = try center(p, h)
        p.pointerDown(pt); p.pointerUp(pt); draw(p)
    }
    func type(_ p: KeyframeEasingPanel, _ key: String, _ text: String) throws {
        try click(p, .field(key))
        for _ in 0..<12 { p.keyDown(EditorKey(.backspace)) }
        for ch in text { p.keyDown(EditorKey(.char(ch))) }
        p.keyDown(EditorKey(.enter)); draw(p)
    }

    func testDockDescriptor() {
        XCTAssertEqual(KeyframeEasingPanel.dock.id, "keyframe-easing")
        XCTAssertEqual(KeyframeEasingPanel.dock.title, "Keyframe Easing")
        XCTAssertEqual(KeyframeEasingPanel.dock.defaultEdge, .bottom)
        XCTAssertEqual(KeyframeEasingPanel.dock.minimumSize, CanvasSize(360, 300))
    }

    func testEmptyStateWithoutAClip() throws {
        let p = KeyframeEasingPanel()
        XCTAssertTrue(draw(p).drawnStrings.contains("No keyframes to ease"))
        p.editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime()); p.clipId = "clip:a"
        XCTAssertTrue(draw(p).drawnStrings.contains("No keyframes to ease"), "a clip with no keys has nothing to ease")
    }

    func testShowsTheSelectedPropertyAndKeyCount() throws {
        let (p, _) = try make()
        var s = draw(p).drawnStrings
        XCTAssertTrue(s.contains("Rotation")); XCTAssertTrue(s.contains("1 key selected"))
        p.selectedKeyframes = []; p.time = 3
        s = draw(p).drawnStrings
        XCTAssertTrue(s.contains("Position"), "no selection: the first animated property"); XCTAssertTrue(s.contains("Key at playhead"))
    }

    func testPresetChipAppliesToEveryKeyInOneUndoStep() throws {
        let (p, e) = try make()
        p.selectedKeyframes = [ref(0, TimelineEditor.positionId), ref(60, TimelineEditor.positionId)]; draw(p)
        var edits = 0; p.onEdited = { edits += 1 }
        let undo = e.undoStack.count
        try click(p, .preset("inout"))
        let ease = NativeInterpolation.cubicBezier(.init(x1: 0.42, y1: 0, x2: 0.58, y2: 1))
        XCTAssertEqual([0.0, 60].map { e.outgoing(ref($0, TimelineEditor.positionId)) }, [ease, ease])
        XCTAssertEqual(e.undoStack.count, undo + 1); XCTAssertEqual(edits, 1)
        e.undo()
        XCTAssertEqual(e.outgoing(ref(0, TimelineEditor.positionId)), .linear)
    }

    func testEnginePendingControlsAreDisabled() throws {
        let (p, e) = try make()
        let before = e.document
        try click(p, .disabled("spring"))
        p.hovered = .disabled("bounce")
        XCTAssertEqual(e.document, before, "Spring and Bounce change nothing")
        XCTAssertEqual(p.hint?.contains("#192"), true)
        p.selectedKeyframes = [ref(0, TimelineEditor.positionId)]; draw(p)
        XCTAssertNotNil(p.hits.rect { $0 == .disabled("dimensions") }, "position shows the disabled Separate dimensions toggle")
        p.hovered = .disabled("dimensions")
        XCTAssertEqual(p.hint?.contains("#193"), true)
    }

    func testCurveHandleDragCommitsOnceOnRelease() throws {
        let (p, e) = try make()
        let undo = e.undoStack.count
        let start = try center(p, .curveHandle(1)), plot = try XCTUnwrap(p.curveBox?.plot)
        p.pointerDown(start)
        p.pointerMove(CanvasPoint(plot.x + plot.width * 0.5, plot.maxY))
        draw(p)
        XCTAssertEqual(e.undoStack.count, undo, "nothing is written while the handle moves")
        p.pointerMove(CanvasPoint(plot.x + plot.width * 0.6, plot.maxY))
        p.pointerUp(CanvasPoint(plot.x + plot.width * 0.6, plot.maxY))
        guard case .cubicBezier(let q)? = e.outgoing(ref(0)) else { return XCTFail("not a curve") }
        XCTAssertEqual(q.x1, 0.6, accuracy: 0.011); XCTAssertEqual(q.y1, 0, accuracy: 0.011)
        XCTAssertEqual(e.undoStack.count, undo + 1)
    }

    func testSpeedHandleDragSetsInfluenceAndSpeed() throws {
        let (p, e) = try make()
        XCTAssertEqual(p.state.graph, .speed)
        let b = try XCTUnwrap(p.graphBox)
        p.pointerDown(try center(p, .speedHandle(.out)))
        // Half-way along the 30-frame segment, at speed 0: an ease out of the first key with 50 % influence.
        let target = CanvasPoint(b.plot.x + (15 - b.frames.lowerBound) / (b.frames.upperBound - b.frames.lowerBound) * b.plot.width, b.plot.maxY)
        p.pointerMove(target); p.pointerUp(target)
        let s = try XCTUnwrap(KeyframeEasing.sides(e, ref(0)))
        XCTAssertEqual(s.outInfluence, 0.5, accuracy: 0.02); XCTAssertEqual(s.outVelocity, 0, accuracy: 1e-9)
        XCTAssertEqual(s.inVelocity, 90, accuracy: 1e-6, "the in side kept its linear speed")
    }

    func testTypedNumbersApplyAndClamp() throws {
        let (p, e) = try make()
        try type(p, "outInfluence", "50")
        XCTAssertEqual(try XCTUnwrap(KeyframeEasing.sides(e, ref(0))).outInfluence, 0.5, accuracy: 1e-9)
        try type(p, "outVelocity", "0")
        XCTAssertEqual(try XCTUnwrap(KeyframeEasing.sides(e, ref(0))).outVelocity, 0, accuracy: 1e-9)
        let undo = e.undoStack.count
        try type(p, "inInfluence", "abc")
        XCTAssertEqual(e.undoStack.count, undo, "text that is not a number changes nothing")
        try type(p, "x2", "7")
        guard case .cubicBezier(let q)? = e.outgoing(ref(0)) else { return XCTFail("not a curve") }
        XCTAssertEqual(q.x2, 1, "X clamps to 0–1")
    }

    func testZoomAndPanStayInsideTheKeyedRange() throws {
        let (p, _) = try make()
        for _ in 0..<20 { try click(p, .zoomIn) }
        XCTAssertEqual(p.state.zoom, 64, "zoom stops at 64×")
        p.state.pan = 5
        XCTAssertEqual(p.state.pan, 1 - 1.0 / 64, accuracy: 1e-12)
        try click(p, .fit)
        XCTAssertEqual(p.state.zoom, 1); XCTAssertEqual(p.state.pan, 0)
        let b = try XCTUnwrap(p.graphBox)
        XCTAssertTrue(p.scroll(CanvasPoint(b.plot.midX, b.plot.midY), dy: -1, zoom: true))
        XCTAssertGreaterThan(p.state.zoom, 1)
        XCTAssertFalse(p.scroll(CanvasPoint(b.plot.midX, b.plot.maxY + 200), dy: 1, zoom: false), "outside the graph")
    }

    func testCopyThenPasteOntoAnotherProperty() throws {
        let (p, e) = try make()
        try click(p, .preset("hold"))
        try click(p, .copy)
        p.selectedKeyframes = [ref(60, TimelineEditor.positionId)]; draw(p)
        let undo = e.undoStack.count
        try click(p, .paste)
        XCTAssertEqual(e.outgoing(ref(60, TimelineEditor.positionId)), .hold)
        XCTAssertEqual(e.undoStack.count, undo + 1)
    }

    func testSaveApplyAndDeleteACustomPreset() throws {
        let (p, e) = try make()
        try type(p, "outInfluence", "80")
        let made = e.outgoing(ref(0))
        try click(p, .savePreset)
        for ch in "Slow" { p.keyDown(EditorKey(.char(ch))) }
        p.keyDown(EditorKey(.enter)); draw(p)
        let preset = try XCTUnwrap(e.easingPresets.first)
        XCTAssertEqual(preset.name, "Slow"); XCTAssertEqual(preset.outgoing, made)
        try click(p, .preset("linear"))
        try click(p, .customPreset(preset.id))
        XCTAssertEqual(e.outgoing(ref(0)), made)
        try click(p, .deletePreset(preset.id))
        XCTAssertEqual(e.easingPresets, [])
    }

    func testPropertyPickerSwitchesProperty() throws {
        let (p, _) = try make()
        try click(p, .property)
        XCTAssertTrue(p.dropdown.isOpen)
        p.dropdown.pick(TimelineEditor.positionId)
        XCTAssertEqual(p.state.chosenProperty, TimelineEditor.positionId)
        XCTAssertEqual(p.target?.parameterId, TimelineEditor.positionId, "the rotation selection no longer pins the property")
    }

    func testMotionPreviewRunsAfterAnEditAndStops() throws {
        let (p, _) = try make()
        var asked = 0; p.onAnimate = { asked += 1 }
        try click(p, .preset("in"))
        XCTAssertEqual(asked, 1); XCTAssertNotNil(p.previewPhase)
        XCTAssertTrue(p.tick(0.6)); XCTAssertFalse(p.tick(0.7))
        XCTAssertNil(p.previewPhase); XCTAssertFalse(p.tick(0.1), "at rest it asks for no frames")
    }

    func testSpeedHandleRangeStaysFixedWhileDragging() throws {
        let (p, _) = try make()
        p.pointerDown(try center(p, .speedHandle(.out)))
        let b = try XCTUnwrap(p.graphBox), high = CanvasPoint(b.plot.midX, b.plot.y - 30)
        var seen: [KeyframeEasingPanel.Drag?] = []
        for _ in 0..<4 { p.pointerMove(high); draw(p); seen.append(p.drag) }
        XCTAssertEqual(Set(seen.map { "\(String(describing: $0))" }).count, 1, "the same pointer position keeps the same speed")
        p.pointerUp(high)
        XCTAssertNil(p.frozenSpeedRange)
    }

    func testCurveHandleRangeStaysFixedWhileDragging() throws {
        let (p, _) = try make()
        p.pointerDown(try center(p, .curveHandle(1)))
        let plot = try XCTUnwrap(p.curveBox?.plot), above = CanvasPoint(plot.midX, plot.y - 40)
        var heights: [Double] = []
        for _ in 0..<4 {
            p.pointerMove(above); draw(p)
            if case .curveHandle(_, let q)? = p.drag { heights.append(q.y1) }
        }
        XCTAssertEqual(heights.count, 4); XCTAssertEqual(Set(heights).count, 1, "Y1 does not drift while the pointer stays put")
        p.pointerUp(above)
        XCTAssertNil(p.frozenCurveRange)
    }

    func testANegativeEndSpeedStaysOnTheSpeedAxis() throws {
        let (p, e) = try make()
        XCTAssertTrue(e.setOutgoing([(ref(0), .cubicBezier(.init(x1: 0.3, y1: -0.5, x2: 0.7, y2: 1)))]))
        draw(p)
        let b = try XCTUnwrap(p.graphBox), h = try XCTUnwrap(p.hits.rect { $0 == .speedHandle(.out) })
        XCTAssertLessThan(b.values.lowerBound, 0, "the axis reaches below 0")
        XCTAssertTrue(b.plot.insetBy(-1).contains(CanvasPoint(h.midX, h.midY)), "the backwards handle is drawn inside the plot")
    }

    func testPresetNameFieldWrapsLikeAChip() throws {
        let (p, e) = try make()
        for name in ["A long preset name", "Another long one", "Third"] { XCTAssertNotNil(e.saveEasingPreset(name: name, outgoing: .linear)) }
        draw(p)
        try click(p, .savePreset)
        let f = try XCTUnwrap(p.hits.rect { $0 == .field("presetName") })
        XCTAssertGreaterThanOrEqual(f.width, 100, "the name field keeps its width")
        XCTAssertLessThanOrEqual(f.maxX, box.maxX - KeyframeEasingPanel.pad + 0.5)
    }

    func testEveryControlIsReachableAtTheMinimumSize() throws {
        let (p, _) = try make()
        let small = CanvasRect(x: 0, y: 0, width: KeyframeEasingPanel.dock.minimumSize.width, height: KeyframeEasingPanel.dock.minimumSize.height)
        p.draw(PanelMeasureCanvas(), in: small)
        XCTAssertGreaterThan(p.maxScroll, 0, "the column is taller than the panel")
        XCTAssertFalse(p.pointerDown(CanvasPoint(10, small.maxY + 50)), "a control below the panel is not pressed")
        XCTAssertTrue(p.scroll(CanvasPoint(small.midX, small.maxY - 4), dy: 10_000, zoom: false))
        p.draw(PanelMeasureCanvas(), in: small)
        let last = try XCTUnwrap(p.hits.rect { $0 == .field("inVelocity") }, "a linear key: In speed is the last control")
        XCTAssertTrue(small.contains(CanvasPoint(last.midX, last.midY)), "scrolled to the end, the last field is in view")
        XCTAssertEqual(p.scrollY, p.maxScroll)
    }
}
