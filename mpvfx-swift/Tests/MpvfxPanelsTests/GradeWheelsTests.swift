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
        // Issue #230 keeps the tonal wheels on every grade so a neutral grade can start a wheel animation.
        for label in ["Shadows", "Midtones", "Highlights"] { XCTAssertTrue(c.drawnStrings.contains(label), label) }
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

    /// A hue set on a tonal wheel before its amount keeps the grade (it is not dropped as neutral), as on a balance wheel.
    func testAHueOnlyWheelKeepsTheGrade() {
        var g = ColorGrading(json: ["version": .number(2)]); g.wheels["midtones"] = .init(hue: 120, amount: 0, level: 0)
        XCTAssertTrue(g.isAuthored)
        var b = ColorGrading(); b.balance["gain"] = .init(hue: 60, amount: 0, level: 0)
        XCTAssertTrue(b.isAuthored)
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

    func testEveryWheelArrowUsesItsStepAndOwnUndoEntry() throws {
        let cases: [(EditorKey, ColorGrading.Wheel)] = [
            (.init(.left), .init(hue: 39, amount: 0.5, level: 0.2)),
            (.init(.right), .init(hue: 41, amount: 0.5, level: 0.2)),
            (.init(.up), .init(hue: 40, amount: 0.51, level: 0.2)),
            (.init(.down), .init(hue: 40, amount: 0.49, level: 0.2)),
            (.init(.left, shift: true), .init(hue: 30, amount: 0.5, level: 0.2)),
            (.init(.right, shift: true), .init(hue: 50, amount: 0.5, level: 0.2)),
            (.init(.up, shift: true), .init(hue: 40, amount: 0.6, level: 0.2)),
            (.init(.down, shift: true), .init(hue: 40, amount: 0.4, level: 0.2))]
        for (key, expected) in cases {
            var g = ColorGrading(); g.balance["gain"] = .init(hue: 40, amount: 0.5, level: 0.2)
            let (p, e) = try inspector(grade: g)
            p.focus.visible = true; p.focus.current = .custom(Self.set, 2)
            let steps = e.undoStack.count
            XCTAssertTrue(p.keyDown(key)); XCTAssertEqual(gain(e), expected)
            XCTAssertEqual(e.undoStack.count, steps + 1)
            e.undo(); XCTAssertEqual(e.colorGrading(clipId: "clip:a"), g)
        }
    }

    /// Each fresh press is separate, while repeat events from a held wheel or level arrow share one step.
    func testHeldWheelAndLevelArrowsCoalesceWithoutCombiningSeparatePresses() throws {
        for part in [2, 12] {
            var g = ColorGrading(); g.balance["gain"] = .init(hue: 40, amount: 0.5, level: 0.2)
            let (p, e) = try inspector(grade: g)
            var clock = 1000.0
            e.now = { clock += 0.01; return clock }
            p.focus.visible = true; p.focus.current = .custom(Self.set, part)
            let steps = e.undoStack.count
            for i in 0..<5 { XCTAssertTrue(p.keyDown(EditorKey(.right, isRepeat: i > 0))) }
            XCTAssertEqual(e.undoStack.count, steps + 1)
            let held = gain(e)
            XCTAssertEqual(part == 2 ? held.hue : held.level, part == 2 ? 45 : 0.25, accuracy: 1e-9)
            p.keyUp(EditorKey(.right))
            XCTAssertTrue(p.keyDown(EditorKey(.right)))
            XCTAssertEqual(e.undoStack.count, steps + 2, "a new physical press has its own undo step")
            e.undo(); XCTAssertEqual(gain(e), held)
            e.undo(); XCTAssertEqual(e.colorGrading(clipId: "clip:a"), g)
        }
    }

    func testDelayedWheelAndLevelRepeatsStayInOneHistoryEntryWithoutRepeatFlags() throws {
        for flagged in [false, true] {
            for part in [2, 12] {
                var grade = ColorGrading()
                grade.balance["gain"] = .init(hue: 40, amount: 0.5, level: 0.2)
                let (panel, editor) = try inspector(grade: grade)
                var clock: Double = 1_000
                editor.now = { clock }
                panel.focus.visible = true
                panel.focus.current = .custom(Self.set, part)
                let entries: Int = editor.undoStack.count
                XCTAssertTrue(panel.keyDown(EditorKey(.right)))
                clock += 1 // Normal first-repeat delay exceeds the generic 0.3-second timeout.
                XCTAssertTrue(panel.keyDown(EditorKey(.right, isRepeat: flagged)))
                clock += 2
                XCTAssertTrue(panel.keyDown(EditorKey(.right, isRepeat: flagged)))
                XCTAssertEqual(editor.undoStack.count, entries + 1)
                let held = gain(editor)
                panel.keyUp(EditorKey(.right))
                XCTAssertTrue(panel.keyDown(EditorKey(.right)))
                XCTAssertEqual(editor.undoStack.count, entries + 2)
                XCTAssertTrue(editor.undo())
                XCTAssertEqual(gain(editor), held)
                XCTAssertTrue(editor.undo())
                XCTAssertEqual(editor.colorGrading(clipId: "clip:a"), grade)
            }
        }
    }

    func testWheelHoldOverrideDoesNotChangeOrdinaryHistoryTimeout() throws {
        let (panel, editor) = try inspector()
        var clock: Double = 1_000
        editor.now = { clock }
        panel.focus.visible = true
        panel.focus.current = .custom(Self.set, 2)
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        panel.keyUp(EditorKey(.right))
        let entries: Int = editor.undoStack.count
        var grade = ColorGrading()
        grade.balance["gain"] = .init(hue: 50, amount: 0.5, level: 0.2)
        editor.withHistory("Ordinary grade edit", coalesceKey: "ordinary") {
            XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        }
        clock += 1
        grade.balance["gain"] = .init(hue: 60, amount: 0.5, level: 0.2)
        editor.withHistory("Ordinary grade edit", coalesceKey: "ordinary") {
            XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", grade))
        }
        XCTAssertEqual(editor.undoStack.count, entries + 2, "the scoped hold override must not leak")
    }

    func testChangingFocusEndsAHoldEvenWithoutAReleaseEvent() throws {
        let (panel, editor) = try inspector()
        panel.focus.visible = true
        panel.focus.current = .custom(Self.set, 2)
        let entries = editor.undoStack.count
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        panel.focus.visible = false // A lost release must not survive focus leaving and returning.
        panel.focus.visible = true
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertEqual(editor.undoStack.count, entries + 2)
    }

    func testRightPanelForwardsKeyReleaseToItsInspector() throws {
        let (_, editor) = try inspector()
        let right = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1_440))
        let panel = right.inspector
        panel.editor = editor
        panel.selection = ["clip:a"]
        panel.openGroupId = "grade"
        redraw(panel)
        panel.focus.visible = true
        panel.focus.current = .custom(Self.set, 2)
        let entries = editor.undoStack.count
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        right.keyUp(EditorKey(.right))
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertEqual(editor.undoStack.count, entries + 2)
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
