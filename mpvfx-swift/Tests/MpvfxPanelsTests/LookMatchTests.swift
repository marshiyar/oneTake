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

final class LookMatchTests: XCTestCase {
    static func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CanvasImage {
        .init(width: 16, height: 16, rgba: (0..<256).flatMap { _ in [r, g, b, 255] })
    }
    static func ramp(_ low: UInt8, _ high: UInt8) -> CanvasImage {
        .init(width: 16, height: 16, rgba: (0..<256).flatMap { i in
            let v = i < 128 ? low : high
            return [v, v, v, 255]
        })
    }

    func testBrightnessContrastAndOffsetAreOrdinaryEditableGradeValues() throws {
        let brighter = try XCTUnwrap(LookMatch.matched(ColorGrading(), source: Self.flat(60, 60, 60), reference: Self.flat(120, 120, 120)))
        XCTAssertEqual(brighter.adjustValue("exposure"), 1, accuracy: 0.001)
        let narrower = try XCTUnwrap(LookMatch.matched(ColorGrading(), source: Self.ramp(64, 192), reference: Self.ramp(96, 160)))
        XCTAssertEqual(narrower.adjustValue("contrast"), -0.5, accuracy: 0.01)
        let cast = try XCTUnwrap(LookMatch.matched(ColorGrading(), source: Self.flat(110, 90, 70), reference: Self.flat(90, 100, 110)))
        XCTAssertGreaterThan(cast.balanceWheel("offset").amount, 0.1)
        XCTAssertGreaterThan(LookMatch.vector(cast.balanceWheel("offset")).z, LookMatch.vector(cast.balanceWheel("offset")).x)
    }

    func testIdenticalFramesAreAnExactNoOpAndOtherLookFieldsArePreserved() throws {
        var grade = ColorGrading(); grade.adjust["saturation"] = 0.3; grade.details["grain"] = 0.1
        grade.curves["master"] = [[0, 0], [0.5, 0.6], [1, 1]]
        grade.balance["gain"] = .init(hue: 30, amount: 0.2, level: 0.1)
        XCTAssertEqual(try XCTUnwrap(LookMatch.matched(grade, source: Self.flat(80, 90, 100), reference: Self.flat(80, 90, 100))), grade)
        let next = try XCTUnwrap(LookMatch.matched(grade, source: Self.flat(80, 90, 100), reference: Self.flat(120, 100, 80)))
        XCTAssertEqual(next.adjust["saturation"], 0.3); XCTAssertEqual(next.details, grade.details)
        XCTAssertEqual(next.curves, grade.curves); XCTAssertEqual(next.balance["gain"], grade.balance["gain"])
        XCTAssertEqual(ColorGrading(json: next.json), next)
    }

    func testStatisticsExcludeTransparentPixelsAndRejectEmptyFrames() throws {
        let visible = Self.flat(100, 110, 120)
        let padded = CanvasImage(width: 32, height: 16, rgba: visible.rgba + [UInt8](repeating: 0, count: visible.rgba.count))
        XCTAssertEqual(LookMatch.statistics(visible), LookMatch.statistics(padded))
        XCTAssertNil(LookMatch.statistics(Self.flat(0, 0, 0).withTransparentAlpha()))
        XCTAssertNil(LookMatch.statistics(CanvasImage(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16))))
    }

    func testExtremeFramesStayFiniteAndInTheExistingGradeLimits() throws {
        for (a, b) in [(Self.flat(0, 0, 0), Self.flat(255, 0, 255)), (Self.flat(255, 255, 255), Self.flat(0, 255, 0))] {
            let next = try XCTUnwrap(LookMatch.matched(ColorGrading(), source: a, reference: b))
            for key in ["exposure", "contrast"] { XCTAssertTrue(GradeValues.adjustLimit(key).contains(next.adjustValue(key))) }
            let w = next.balanceWheel("offset")
            XCTAssertTrue(w.hue.isFinite && w.amount.isFinite && w.level.isFinite)
            XCTAssertTrue((0...360).contains(w.hue)); XCTAssertTrue((0...1).contains(w.amount)); XCTAssertTrue((-1...1).contains(w.level))
        }
    }

    func testOffsetWheelVectorRoundTripsAndDisabledGradesDoNotMatch() {
        for w in [ColorGrading.Wheel(hue: 0, amount: 0.3, level: -0.2), .init(hue: 160, amount: 0.5, level: 0.1), .init(hue: 285, amount: 1, level: 0)] {
            let v = LookMatch.vector(w), got = LookMatch.vector(LookMatch.wheel(v))
            XCTAssertEqual(got.x, v.x, accuracy: 0.001); XCTAssertEqual(got.y, v.y, accuracy: 0.001); XCTAssertEqual(got.z, v.z, accuracy: 0.001)
        }
        var g = ColorGrading(); g.enabled = false
        XCTAssertNil(LookMatch.matched(g, source: Self.flat(70, 70, 70), reference: Self.flat(100, 100, 100)))
    }
}

private extension CanvasImage {
    func withTransparentAlpha() -> CanvasImage {
        var px = rgba
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 0 }
        return CanvasImage(width: width, height: height, rgba: px)
    }
}

final class LookMatchInspectorTests: XCTestCase {
    func setup() throws -> (InspectorPanel, TimelineEditor, PanelMeasureCanvas) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let p = InspectorPanel(); p.editor = e; p.selection = ["clip:a"]; p.openGroupId = "grade"
        p.lookMatch.reference = "clip:b"
        p.matchLookFrame = { id, _, _, _ in .ready(id == "clip:a" ? LookMatchTests.flat(60, 60, 60) : LookMatchTests.flat(120, 110, 100)) }
        let c = PanelMeasureCanvas(); p.draw(c, in: .init(x: 0, y: 0, width: 400, height: 5000))
        return (p, e, c)
    }
    func redraw(_ p: InspectorPanel, _ c: PanelMeasureCanvas) { c.reset(); p.draw(c, in: .init(x: 0, y: 0, width: 400, height: 5000)) }

    func testReferencePickerHasOnlyOtherVisualClipsAndKeyboardApplyIsOneUndoStep() throws {
        let (p, e, _) = try setup()
        XCTAssertFalse(p.matchLookCandidates("clip:a").contains { $0.id == "clip:a" })
        XCTAssertTrue(p.matchLookCandidates("clip:a").contains { $0.id == "clip:b" })
        p.focus.current = .button("grade:match-look"); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        let applied = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        XCTAssertGreaterThan(applied.adjustValue("exposure"), 0.5)
        XCTAssertNotNil(applied.balance["offset"])
        let json = try serializeNativeProjectDocument(e.document, engine: e.engine)
        let reopened = try TimelineEditor(json: json, engine: e.engine)
        XCTAssertEqual(reopened.colorGrading(clipId: "clip:a"), applied)
        XCTAssertTrue(e.undo()); XCTAssertNil(e.colorGrading(clipId: "clip:a"))
        XCTAssertFalse(e.canUndo, "the entire look is one edit")
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.colorGrading(clipId: "clip:a"), applied)
    }

    func testKeyboardReferencePickerReportsChoiceWithoutEditingTheDocument() throws {
        let (p, e, _) = try setup(); let original = e.document
        var ids: [String] = []
        p.onOpenDropdown = { key, options, _, _, select in
            XCTAssertEqual(key, "match-look-reference"); ids = options.map(\.value); select("clip:b")
        }
        p.focus.current = .custom("grade:match-reference", 0); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertTrue(ids.contains("clip:b")); XCTAssertFalse(ids.contains("clip:a"))
        XCTAssertEqual(e.document, original); XCTAssertFalse(e.canUndo)
    }

    func testPendingCaptureWaitsAndSamplesTheReferencesOwnMidpoint() throws {
        let (p, e, c) = try setup(); var waiting = true; var requests: [(String, Double)] = []
        p.time = 0.2
        p.matchLookFrame = { id, t, _, _ in
            requests.append((id, t))
            if waiting { return .rendering }
            return .ready(id == "clip:a" ? LookMatchTests.flat(60, 60, 60) : LookMatchTests.flat(120, 120, 120))
        }
        p.startLookMatch("clip:a"); XCTAssertNil(e.colorGrading(clipId: "clip:a"))
        waiting = false; redraw(p, c)
        XCTAssertNotNil(e.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(requests.first?.0, "clip:a"); XCTAssertEqual(requests.first?.1, 0.2)
        let ref = try XCTUnwrap(e.clip("clip:b")?.clip)
        let expected = (ref.startFrame + (ref.durationFrames - 1) / 2) / e.document.frameRate.numerator * e.document.frameRate.denominator
        XCTAssertEqual(try XCTUnwrap(requests.first { $0.0 == "clip:b" }?.1), expected, accuracy: 1e-9)
    }

    func testSelectionSeekAndDocumentChangesCancelWithoutEditingAnotherClip() throws {
        for change in 0..<3 {
            let (p, e, c) = try setup(); let original = e.document
            p.matchLookFrame = { _, _, _, _ in .rendering }; p.startLookMatch("clip:a")
            XCTAssertNotNil(p.lookMatch.pending)
            if change == 0 { p.selection = ["clip:b"] }
            else if change == 1 { p.time = 2 }
            else { let next = try TimelineEditor(json: TimelineEditor.demoJSON, engine: e.engine); p.editor = next }
            p.matchLookFrame = { _, _, _, _ in XCTFail("a stale request must not ask for another frame"); return .ready(LookMatchTests.flat(120, 120, 120)) }
            redraw(p, c)
            XCTAssertNil(p.lookMatch.pending); XCTAssertEqual(e.document, original); XCTAssertFalse(e.canUndo)
        }
    }

    func testPendingCancellationSurvivesSelectionOrSeekAwayAndBackWithoutGradeRows() throws {
        for change in 0..<3 {
            let (p, e, c) = try setup()
            p.matchLookFrame = { _, _, _, _ in .rendering }; p.startLookMatch("clip:a")
            if change == 0 { p.selection = []; redraw(p, c); p.selection = ["clip:a"] }
            else if change == 1 { p.time = 4; p.time = 0 }
            else { p.editor = nil; p.editor = e }
            p.matchLookFrame = { _, _, _, _ in XCTFail("cancelled work cannot resume"); return .unavailable }
            redraw(p, c)
            XCTAssertNil(p.lookMatch.pending); XCTAssertFalse(e.canUndo)
        }
    }

    func testDocumentMutationWhileGradeClosedCancelsBeforeUndoRestoresDocument() throws {
        let (p, e, c) = try setup()
        p.matchLookFrame = { _, _, _, _ in .rendering }; p.startLookMatch("clip:a")
        p.openGroupId = "layout"
        var g = ColorGrading(); g.adjust["exposure"] = 0.2
        XCTAssertTrue(e.setColorGrading(clipId: "clip:b", g)); redraw(p, c)
        XCTAssertNil(p.lookMatch.pending)
        XCTAssertTrue(e.undo()); p.openGroupId = "grade"
        p.matchLookFrame = { _, _, _, _ in XCTFail("cancelled work cannot resume after undo"); return .unavailable }
        redraw(p, c); XCTAssertFalse(e.canUndo)
    }

    func testAsynchronousIdenticalFramesCompleteWithRefreshAndNoUndo() throws {
        let (p, e, c) = try setup(); var waiting = true, refreshes = 0
        p.onEdited = { refreshes += 1 }
        p.matchLookFrame = { _, _, _, _ in waiting ? .rendering : .ready(LookMatchTests.flat(100, 100, 100)) }
        p.startLookMatch("clip:a"); let before = refreshes
        waiting = false; redraw(p, c)
        XCTAssertNil(p.lookMatch.pending); XCTAssertFalse(e.canUndo)
        XCTAssertGreaterThan(refreshes, before)
    }

    func testUnavailableReferenceShowsAUsefulMessageAndMakesNoEdit() throws {
        let (p, e, c) = try setup()
        p.matchLookFrame = { id, _, _, _ in id == "clip:a" ? .ready(LookMatchTests.flat(70, 70, 70)) : .unavailable }
        p.startLookMatch("clip:a"); redraw(p, c)
        XCTAssertEqual(p.lookMatch.message, "The reference clip has no frame to measure")
        XCTAssertFalse(e.canUndo); XCTAssertNil(e.colorGrading(clipId: "clip:a"))
    }
}
