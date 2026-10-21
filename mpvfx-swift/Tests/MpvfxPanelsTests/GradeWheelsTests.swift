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
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The Grade group's colour wheels (issue #176) and their keyboard behaviour (issue #171), driven through the
/// inspector's hit regions as a pointer and a keyboard would.
final class GradeWheelsTests: XCTestCase {
    func inspector(width: Double = 380, grade: ColorGrading? = nil) throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        if let grade { XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade)) }
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"
        redraw(p, width: width)
        return (p, editor)
    }
    func redraw(_ p: InspectorPanel, width: Double = 380) {
        let rect = CanvasRect(x: 0, y: 0, width: width, height: 5000)
        p.draw(PanelMeasureCanvas(), in: rect); p.draw(PanelMeasureCanvas(), in: rect)   // the second layout knows the width
    }
    func rect(_ p: InspectorPanel, _ h: InspectorPanel.Hit) throws -> CanvasRect { try XCTUnwrap(p.hits.rect { $0 == h }, "\(h)") }
    func click(_ p: InspectorPanel, _ at: CanvasPoint) { XCTAssertTrue(p.pointerDown(at)); p.pointerUp(at) }
    func gain(_ e: TimelineEditor) -> ColorGrading.Wheel { e.colorGrading(clipId: "clip:a")?.balanceWheel("gain") ?? .init() }
    static let set = "grade:balance"

    func testANewGradeShowsLiftGammaGainOffset() throws {
        let (p, _) = try inspector()
        let c = PanelMeasureCanvas(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 380, height: 5000))
        for label in ["Lift", "Gamma", "Gain", "Offset", "Pivot"] { XCTAssertTrue(c.drawnStrings.contains(label), label) }
        XCTAssertFalse(c.drawnStrings.contains("Midtones"), "a new grade has no tonal wheels")
        let old = try inspector(grade: ColorGrading(json: ["adjust": .object(["contrast": .number(0.1)])])).0
        XCTAssertNotNil(old.hits.rect { $0 == .custom("grade:wheels", 1) }, "a contract 2 grade keeps its tonal wheels")
    }

    /// The puck lands under the pointer: a press at the puck's full radius is amount 1, half way is 0.5.
    func testThePuckFollowsThePointer() throws {
        let (p, e) = try inspector()
        let wheel = try rect(p, .custom(Self.set, 2))
        let r = GradeWheelLayout.puckRadius(wheel.width)
        click(p, CanvasPoint(wheel.midX + r / 2, wheel.midY))
        XCTAssertEqual(gain(e).amount, 0.5, accuracy: 0.01); XCTAssertEqual(gain(e).hue, 0, accuracy: 0.5)
        redraw(p)
        click(p, CanvasPoint(wheel.midX, wheel.midY - r))
        XCTAssertEqual(gain(e).amount, 1, accuracy: 0.01); XCTAssertEqual(gain(e).hue, 90, accuracy: 0.5)
    }

    func testOnlyThePointsInsideTheCircleHitTheWheel() throws {
        let (p, e) = try inspector()
        let wheel = try rect(p, .custom(Self.set, 2))
        click(p, CanvasPoint(wheel.x + 2, wheel.y + 2))
        XCTAssertNil(e.colorGrading(clipId: "clip:a"), "a press in the square's corner changes nothing")
    }

    func testTheWheelFieldsTakeTypedValues() throws {
        let (p, e) = try inspector()
        let hue = "\(Self.set):gain:hue", amount = "\(Self.set):gain:amount", level = "\(Self.set):gain:level"
        for (key, text) in [(hue, "-30"), (amount, "150%"), (level, "40")] {
            redraw(p)
            click(p, CanvasPoint(try rect(p, .field(key)).midX, try rect(p, .field(key)).midY))
            XCTAssertEqual(p.field?.key, key)
            for _ in 0..<8 { _ = p.keyDown(EditorKey(.backspace)) }
            for ch in text { _ = p.keyDown(EditorKey(.char(ch))) }
            XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        }
        XCTAssertEqual(gain(e), .init(hue: 330, amount: 1, level: 0.4), "hue wraps, amount is clamped to 100%")
        redraw(p)
        click(p, CanvasPoint(try rect(p, .field(hue)).midX, try rect(p, .field(hue)).midY))
        for ch in "abc" { _ = p.keyDown(EditorKey(.char(ch))) }
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(gain(e).hue, 330, "text that is not a number changes nothing")
    }

    func testTabReachesTheWheelFields() throws {
        let (p, _) = try inspector()
        let order = PanelFocus<InspectorPanel.Hit>.order(p.hits, InspectorPanel.focusable)
        for f in ["hue", "amount", "level"] { XCTAssertTrue(order.contains(.field("\(Self.set):lift:\(f)")), f) }
    }

    func testTheResetPutsOneWheelBackToNeutral() throws {
        var g = ColorGrading(); g.balance["gain"] = .init(hue: 40, amount: 0.5, level: 0.2); g.balance["lift"] = .init(hue: 10, amount: 0.3, level: 0)
        let (p, e) = try inspector(grade: g)
        let reset = try rect(p, .custom(Self.set, 22))
        XCTAssertGreaterThanOrEqual(min(reset.width, reset.height), 24, "a 24 pt target")
        click(p, CanvasPoint(reset.midX, reset.midY))
        XCTAssertTrue(gain(e).isNeutral)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.balanceWheel("lift").amount, 0.3)
    }

    /// Issue #171 A1: Enter or Space on a focused wheel or level never changes the grade and adds no undo step.
    func testEnterAndSpaceOnAFocusedWheelChangeNothing() throws {
        var g = ColorGrading(); g.balance["gain"] = .init(hue: 40, amount: 0.5, level: 0.2)
        let (p, e) = try inspector(grade: g)
        let before = e.document
        for part in [2, 12] {
            p.focus.visible = true; p.focus.current = .custom(Self.set, part)
            XCTAssertTrue(p.keyDown(EditorKey(.enter))); XCTAssertTrue(p.keyDown(EditorKey(.space)))
        }
        XCTAssertEqual(e.document, before)
        e.undo()
        XCTAssertNil(e.colorGrading(clipId: "clip:a"), "the one undo step is setting the grade, not a key press")
    }

    /// Issue #171 A2: arrows turn the hue and change the amount of a focused wheel, and move a focused level; each
    /// press is one undo step.
    func testArrowKeysAdjustAFocusedWheel() throws {
        var g = ColorGrading(); g.balance["gain"] = .init(hue: 40, amount: 0.5, level: 0.2)
        let (p, e) = try inspector(grade: g)
        p.focus.visible = true; p.focus.current = .custom(Self.set, 2)
        XCTAssertTrue(p.keyDown(EditorKey(.right)))
        XCTAssertEqual(gain(e).hue, 41)
        var shiftUp = EditorKey(.up); shiftUp.shift = true
        XCTAssertTrue(p.keyDown(shiftUp))
        XCTAssertEqual(gain(e).amount, 0.6, accuracy: 1e-9)
        p.focus.current = .custom(Self.set, 12)
        XCTAssertTrue(p.keyDown(EditorKey(.left)))
        XCTAssertEqual(gain(e).level, 0.19, accuracy: 1e-9)
        e.undo()
        XCTAssertEqual(gain(e).level, 0.2, accuracy: 1e-9, "one press, one undo step")
    }

    /// At the narrowest panel the field labels (10 px) never run into each other.
    func testWheelFieldLabelsDoNotOverlapAt280() throws {
        let (p, _) = try inspector(width: 280)
        let labels = try GradeValues.balanceKeys.flatMap { k in try ["hue", "amount", "level"].map { try rect(p, .scrub("\(Self.set):\(k):\($0)")) } }
        for (i, a) in labels.enumerated() { for b in labels[(i + 1)...] { XCTAssertFalse(a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY, "\(a) overlaps \(b)") } }
        let c = PanelMeasureCanvas(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 280, height: 5000))
        let amountWidth = c.measureText("Amount", font: PanelTheme.font(10)).width
        XCTAssertLessThanOrEqual(amountWidth, try XCTUnwrap(labels.first).width, "the longest label fits its field")
    }

    func testPivotSliderWritesThePivot() throws {
        let (p, e) = try inspector()
        let pivot = try XCTUnwrap(p.slider("grade:adj:pivot"))
        XCTAssertEqual(pivot.position, 50)
        pivot.commit(25)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.pivot, 0.25)
        redraw(p)
        try XCTUnwrap(p.slider("grade:adj:pivot")?.reset)()
        XCTAssertNil(e.colorGrading(clipId: "clip:a"), "pivot back at 50% leaves a neutral grade")
    }

    func testBalanceRoundTripsThroughTheGradeJSON() {
        var g = ColorGrading(); g.balance["offset"] = .init(hue: 200, amount: 0.25, level: -0.5); g.pivot = 0.3
        XCTAssertEqual(ColorGrading(json: g.json), g)
        XCTAssertTrue(g.isAuthored)
        XCTAssertEqual(ColorGrading(json: ["balance": .object(["gain": .object(["amount": .number(9), "hue": .number(-10)])])]).balanceWheel("gain"),
                       .init(hue: 350, amount: 1, level: 0))
    }
}
