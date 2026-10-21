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

final class InspectorSliderKeyboardTests: XCTestCase {
    static let frame = CanvasRect(x: 0, y: 0, width: 360, height: 9000)

    func make(_ group: String = "style") throws -> (InspectorPanel, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let p = InspectorPanel(); p.editor = e; p.selection = ["clip:a"]; p.openGroupId = group
        redraw(p)
        return (p, e)
    }

    func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: Self.frame) }

    func focus(_ p: InspectorPanel, _ key: String) {
        p.focus.current = .slider(key); p.focus.visible = true
    }

    func type(_ text: String, into p: InspectorPanel) throws {
        let old = try XCTUnwrap(p.field).draft
        for _ in old { XCTAssertTrue(p.keyDown(EditorKey(.backspace))) }
        for c in text { XCTAssertTrue(p.keyDown(EditorKey(.char(c)))) }
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        redraw(p)
    }

    func testA1AllGradeSlidersAndResetsAppearInTabOrderWithAFocusRing() throws {
        let (p, _) = try make("grade")
        let sliders = p.allRows().compactMap { row -> InspectorRow.Slider? in
            if case .slider(let s) = row.kind { return s }; return nil
        }
        XCTAssertGreaterThan(sliders.count, 12)
        let order = PanelFocus<InspectorPanel.Hit>.order(p.hits, p.isFocusable)
        for s in sliders {
            XCTAssertTrue(order.contains(.slider(s.key)), s.key)
            if s.tier == .explicitCustom, s.reset != nil { XCTAssertTrue(order.contains(.reset(s.key)), s.key) }
        }
        p.focus.current = nil
        for hit in order {
            XCTAssertTrue(p.keyDown(EditorKey(.tab)))
            XCTAssertEqual(p.focus.current, hit)
            XCTAssertNotNil(p.focus.ringRect(p.hits))
        }
        XCTAssertTrue(p.keyDown(EditorKey(.tab, shift: true)))
        XCTAssertEqual(p.focus.current, order.dropLast().last)
    }

    func testA2OpacityArrowsShiftAndHomeEndUsePercentSteps() throws {
        let (p, e) = try make()
        focus(p, "opacity")
        for (key, shift, expected) in [(EditorKey.Code.left, false, 0.99), (.down, true, 0.89),
                                       (.up, false, 0.90), (.right, false, 0.91), (.home, false, 0), (.end, false, 1)] {
            XCTAssertTrue(p.keyDown(EditorKey(key, shift: shift)))
            XCTAssertEqual(try XCTUnwrap(e.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 0)), expected, accuracy: 1e-9)
        }
    }

    func testA2ExposureUsesHundredthsOfAnEVAndRepeatsUndoTogether() throws {
        let (p, e) = try make("grade")
        var clock = 0.0; e.now = { clock }
        focus(p, "grade:adj:exposure")
        let start = e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure")
        let undo = e.undoStack.count
        XCTAssertTrue(p.keyDown(EditorKey(.right)))
        clock = 1
        XCTAssertTrue(p.keyDown(EditorKey(.right, isRepeat: true)))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure"), start + 0.02, accuracy: 1e-9)
        XCTAssertEqual(e.undoStack.count, undo + 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure"), start, accuracy: 1e-9)
        XCTAssertTrue(p.keyDown(EditorKey(.up, shift: true)))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure"), start + 0.1, accuracy: 1e-9)
        XCTAssertTrue(p.keyDown(EditorKey(.home)))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure"), -2)
        XCTAssertTrue(p.keyDown(EditorKey(.end)))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure"), 2)
    }

    func testA3EnterTypesDisplayedUnitsClampsAndEscapeCancels() throws {
        let (p, e) = try make()
        focus(p, "opacity")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        try type("35%", into: p)
        XCTAssertEqual(try XCTUnwrap(e.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 0)), 0.35, accuracy: 1e-9)
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        try type("350", into: p)
        XCTAssertEqual(e.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 0), 1)
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertTrue(p.keyDown(EditorKey(.char("5"))))
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        XCTAssertNil(p.field)
        XCTAssertEqual(e.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 0), 1)
        p.openGroupId = "grade"; redraw(p); focus(p, "grade:adj:exposure")
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        try type("+0.35", into: p)
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 0).adjustValue("exposure"), 0.35, accuracy: 1e-9)
    }

    func testA3InvalidValueKeepsDocumentAndFieldAndShowsRange() throws {
        let (p, e) = try make()
        focus(p, "opacity")
        let before = e.document, undo = e.undoStack.count
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        try type("NaN", into: p)
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.undoStack.count, undo)
        XCTAssertEqual(p.field?.draft, "NaN")
        let c = PanelMeasureCanvas(); p.draw(c, in: Self.frame)
        XCTAssertTrue(c.drawnStrings.contains("Enter 0%…100%"))
        XCTAssertTrue(p.keyDown(EditorKey(.tab)))
        XCTAssertNotNil(p.field, "invalid input must not silently move focus")
        try type("35", into: p)
        XCTAssertNil(p.field)
        XCTAssertNil(p.sliderInputError)
    }

    func testA3ValuePointerOpensFieldWithoutMovingTheSlider() throws {
        let (p, e) = try make()
        let r = try XCTUnwrap(p.hits.rect { $0 == .field("opacity") })
        let point = CanvasPoint(r.midX, r.midY)
        let before = e.document
        XCTAssertTrue(p.pointerDown(point, time: 1)); p.pointerUp(point)
        XCTAssertTrue(p.pointerDown(point, time: 1.1)); p.pointerUp(point)
        XCTAssertEqual(p.field?.key, "opacity")
        XCTAssertEqual(e.document, before)
    }

    func testA4DeleteAndBackspaceResetAndUndoRestoresTheValue() throws {
        for code in [EditorKey.Code.delete, .backspace] {
            let (p, e) = try make()
            p.slider("opacity")?.commit(35); redraw(p); focus(p, "opacity")
            let undo = e.undoStack.count
            XCTAssertTrue(p.keyDown(EditorKey(code)))
            XCTAssertEqual(e.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 0) ?? 1, 1)
            XCTAssertEqual(e.undoStack.count, undo + 1)
            XCTAssertTrue(e.undo())
            XCTAssertEqual(try XCTUnwrap(e.numberValue(clipId: "clip:a", TimelineEditor.opacityId, time: 0)), 0.35, accuracy: 1e-9)
        }
    }

    func testA5OpacityAndVolumeKeyboardEditsWriteAtThePlayhead() throws {
        for (group, key, pid) in [("style", "opacity", TimelineEditor.opacityId), ("media", "volume", TimelineEditor.volumeId)] {
            let (p, e) = try make(group)
            try XCTUnwrap(p.slider(key)?.keyframe).stopwatch()
            p.time = 1; redraw(p); focus(p, key)
            let undo = e.undoStack.count
            XCTAssertTrue(p.keyDown(EditorKey(.left)))
            let keys = try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.first { $0.parameterId == pid }?.keyframes ?? []
            XCTAssertEqual(keys.map(\.frame), [0, 30])
            XCTAssertEqual(e.undoStack.count, undo + 1)
            XCTAssertTrue(e.undo())
            let restored = try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.first { $0.parameterId == pid }?.keyframes ?? []
            XCTAssertEqual(restored.map(\.frame), [0])
        }
    }

    func testRateGainAndNonlinearEffectFieldsParseTheirDisplayedUnits() throws {
        let (p, e) = try make("media")
        focus(p, "rate"); XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        try type("1.50×", into: p)
        XCTAssertEqual(e.playbackRate(clipId: "clip:a"), 1.5)
        focus(p, "volume"); XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        try type("-6 dB", into: p)
        XCTAssertEqual(try XCTUnwrap(e.numberValue(clipId: "clip:a", TimelineEditor.volumeId, time: 0)), pow(10, -6.0 / 20), accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(InspectorPanel.effectSliderInput("48px", key: "pixelate")), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(InspectorPanel.effectSliderInput("32.75px", key: "blur")), 100, accuracy: 1e-9)
    }
}
