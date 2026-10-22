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

/// Issue #454: Auto balance computes Exposure, Warmth and Tint from the frame's statistics.
final class AutoBalanceTests: XCTestCase {
    /// A flat 16x16 frame of one colour.
    static func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CanvasImage {
        CanvasImage(width: 16, height: 16, rgba: (0..<256).flatMap { _ in [r, g, b, 255] })
    }

    func testADarkFrameRaisesExposureAndABrightOneLowersIt() throws {
        let dark = try XCTUnwrap(AutoBalance.balanced(ColorGrading(), frame: Self.flat(40, 40, 40)))
        let bright = try XCTUnwrap(AutoBalance.balanced(ColorGrading(), frame: Self.flat(220, 220, 220)))
        XCTAssertGreaterThan(dark.adjustValue("exposure"), 0.5)
        XCTAssertLessThan(bright.adjustValue("exposure"), -0.5)
        XCTAssertEqual(dark.adjustValue("temperature"), 0, accuracy: 1e-9, "a grey frame has no cast")
        XCTAssertEqual(dark.adjustValue("tint"), 0, accuracy: 1e-9)
    }

    func testAWarmCastMovesWarmthDownAndACoolCastUp() throws {
        let warm = try XCTUnwrap(AutoBalance.balanced(ColorGrading(), frame: Self.flat(160, 120, 90)))
        let cool = try XCTUnwrap(AutoBalance.balanced(ColorGrading(), frame: Self.flat(90, 120, 160)))
        XCTAssertLessThan(warm.adjustValue("temperature"), -0.1)
        XCTAssertGreaterThan(cool.adjustValue("temperature"), 0.1)
    }

    /// The solved Warmth and Tint, put through the shader's gain, turn the average colour grey (contract 3) or
    /// shift it by the additive offsets (contract 2).
    func testTheSolvedValuesNeutraliseTheAverageColourInBothContracts() {
        let mean = SIMD3(0.62, 0.48, 0.35)
        let (t3, n3) = AutoBalance.whiteBalance(mean, gains: true)
        let g = SIMD3(1 + t3 * 0.16 + n3 * 0.08, 1 - n3 * 0.16, 1 - t3 * 0.16 + n3 * 0.08)
        let out = mean * g
        XCTAssertEqual(out.x, out.y, accuracy: 1e-9); XCTAssertEqual(out.z, out.y, accuracy: 1e-9)
        let (t2, n2) = AutoBalance.whiteBalance(mean, gains: false)
        let r = mean.x + t2 * 0.08 + n2 * 0.04, gg = mean.y - n2 * 0.08, b = mean.z - (t2 * 0.08 - n2 * 0.04)
        XCTAssertEqual(r, gg, accuracy: 1e-9); XCTAssertEqual(b, gg, accuracy: 1e-9)
    }

    func testTheSameFrameAndGradeGiveTheSameValuesAndOnlyThreeKeysChange() throws {
        let frame = Self.flat(150, 110, 70)
        var base = ColorGrading(); base.adjust["contrast"] = 0.2; base.intensity = 0.7
        let a = try XCTUnwrap(AutoBalance.balanced(base, frame: frame)), b = try XCTUnwrap(AutoBalance.balanced(base, frame: frame))
        XCTAssertEqual(a, b)
        var expected = a
        expected.adjust["exposure"] = nil; expected.adjust["temperature"] = nil; expected.adjust["tint"] = nil
        var rest = base; rest.adjust["contrast"] = 0.2
        XCTAssertEqual(expected, rest, "nothing but Exposure, Warmth and Tint is written")
    }

    func testEmptyAndTransparentFramesGiveNoResult() {
        XCTAssertNil(AutoBalance.balanced(ColorGrading(), frame: CanvasImage(width: 8, height: 8, rgba: [UInt8](repeating: 0, count: 256))))
        XCTAssertNil(AutoBalance.balanced(ColorGrading(), frame: CanvasImage(width: 1, height: 1, rgba: [9, 9, 9, 255])))
    }

    func testValuesStayInTheContractLimitsEvenForAnAlmostBlackFrame() throws {
        let g = try XCTUnwrap(AutoBalance.balanced(ColorGrading(), frame: Self.flat(1, 0, 0)))
        for k in ["exposure", "temperature", "tint"] { XCTAssertTrue(GradeValues.adjustLimit(k).contains(g.adjustValue(k)), k) }
        XCTAssertLessThanOrEqual(g.adjustValue("exposure"), AutoBalance.maxStops)
    }

    func testABalancedFrameChangesNothingMuch() throws {
        let g = try XCTUnwrap(AutoBalance.balanced(ColorGrading(), frame: Self.flat(115, 115, 115)))
        XCTAssertEqual(g.adjustValue("exposure"), 0, accuracy: 0.03)
    }

    // MARK: Inspector

    func inspector(frame: PresetPreviewState) throws -> (InspectorPanel, TimelineEditor, PanelMeasureCanvas) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"
        p.scopeFrame = { _, _, _ in frame }
        let c = PanelMeasureCanvas()
        p.draw(c, in: CanvasRect(x: 0, y: 0, width: 380, height: 4000))
        return (p, editor, c)
    }

    func press(_ p: InspectorPanel) throws {
        let hit = try XCTUnwrap(p.hits.rect { $0 == .custom("grade:autobalance", 0) }, "the button is drawn")
        XCTAssertTrue(p.pointerDown(CanvasPoint(hit.midX, hit.midY))); p.pointerUp(CanvasPoint(hit.midX, hit.midY))
    }

    func testTheButtonWritesTheGradeInOneUndoStepAndResetReturnsToDefaults() throws {
        let (p, editor, _) = try inspector(frame: .ready(Self.flat(150, 110, 70)))
        try press(p)
        let g = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        XCTAssertNotEqual(g.adjustValue("exposure"), 0)
        XCTAssertLessThan(g.adjustValue("temperature"), 0)
        XCTAssertTrue(editor.undo(), "one step")
        XCTAssertFalse(editor.colorGrading(clipId: "clip:a")?.isAuthored ?? false, "a single undo removes all three values")
        XCTAssertTrue(editor.redo())
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", ColorGrading()))
        XCTAssertEqual((editor.colorGrading(clipId: "clip:a") ?? ColorGrading()).adjustValue("exposure"), 0, "reset returns the defaults")
    }

    func testTheGradeRoundTripsThroughTheDocumentJSON() throws {
        let (p, editor, _) = try inspector(frame: .ready(Self.flat(150, 110, 70)))
        try press(p)
        let g = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(ColorGrading(json: g.json).adjust, g.adjust)
    }

    func testEnterOnTheFocusedButtonBalancesFromTheKeyboard() throws {
        let (p, editor, _) = try inspector(frame: .ready(Self.flat(30, 30, 30)))
        p.focus.current = .custom("grade:autobalance", 0); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertGreaterThan(editor.colorGrading(clipId: "clip:a")?.adjustValue("exposure") ?? 0, 0.5)
    }

    func testAFrameStillRenderingIsWaitedForAndAnUnavailableOneIsSaid() throws {
        var state: PresetPreviewState = .rendering
        let (p, editor, c) = try inspector(frame: .rendering)
        p.scopeFrame = { _, _, _ in state }
        try press(p)
        XCTAssertNil(editor.colorGrading(clipId: "clip:a"), "nothing written yet")
        state = .ready(Self.flat(30, 30, 30))
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 380, height: 4000))
        XCTAssertGreaterThan(editor.colorGrading(clipId: "clip:a")?.adjustValue("exposure") ?? 0, 0.5, "applied once the frame arrived")
        state = .unavailable
        try press(p)
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 380, height: 4000))
        XCTAssertTrue(c.drawnStrings.contains("No frame to measure"))
    }
}
