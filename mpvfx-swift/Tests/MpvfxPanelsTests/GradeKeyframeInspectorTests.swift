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

/// Issue #179 A2: the Grade and Effects rows carry the stopwatch and ‹ ◆ › like Opacity; animated values show
/// their value at the playhead, an edit of one keys it there, and stopping keeps the playhead's value.
final class GradeKeyframeInspectorTests: XCTestCase {
    static let exposure = NativeGradeParameter.adjustId("exposure")

    /// Demo document, clip:a (video, 30 fps) selected, the Grade group open, playhead at `time`.
    func make(time: Double = 1) throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        var g = ColorGrading(); g.adjust["exposure"] = 0.4
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.time = time
        p.openGroupId = "grade"
        redraw(p)
        return (p, editor)
    }

    func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 360, height: 8000)) }

    func click(_ p: InspectorPanel, _ hit: InspectorPanel.Hit) throws {
        let r = try XCTUnwrap(p.hits.rect { $0 == hit }, "\(hit) is drawn")
        XCTAssertTrue(p.pointerDown(CanvasPoint(r.x + r.width / 2, r.y + r.height / 2)))
        p.pointerUp(CanvasPoint(r.x + r.width / 2, r.y + r.height / 2))
        redraw(p)
    }

    func keys(_ e: TimelineEditor, _ pid: String) throws -> [NativeKeyframe] {
        try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.first { $0.parameterId == pid }?.keyframes ?? []
    }

    func testStopwatchStartsAnimatingExposureAtTheShownValue() throws {
        let (p, e) = try make()
        let undo = e.undoStack.count
        try click(p, .stopwatch("grade:adj:exposure"))
        XCTAssertEqual(try keys(e, Self.exposure).map(\.frame), [30])
        XCTAssertEqual(try keys(e, Self.exposure).map(\.value), [.number(0.4)])
        XCTAssertEqual(e.undoStack.count, undo + 1, "one undo step")
        XCTAssertEqual(p.slider("grade:adj:exposure")?.keyframe?.state, .onKey)
    }

    func testAnEditOfAnAnimatedValueKeysItAtThePlayheadAndLeavesTheStoredGrade() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:adj:exposure"))
        p.time = 3; redraw(p)
        XCTAssertEqual(p.slider("grade:adj:exposure")?.keyframe?.state, .animated)
        p.slider("grade:adj:exposure")?.commit(150)   // the row shows exposure x 100
        XCTAssertEqual(try keys(e, Self.exposure).map(\.frame), [30, 90])
        XCTAssertEqual(try keys(e, Self.exposure).last?.value, .number(1.5))
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.adjustValue("exposure"), 0.4, "the stored grade keeps its value")
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).adjustValue("exposure"), 1.5, "the row shows the keyed value")
        p.slider("grade:adj:contrast")?.commit(20)
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.adjustValue("contrast"), 0.2, "a static value is written as before")
        XCTAssertTrue(try keys(e, NativeGradeParameter.adjustId("contrast")).isEmpty)
    }

    func testStopwatchOffKeepsThePlayheadValueInTheStoredGrade() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:adj:exposure"))
        p.time = 3; redraw(p)
        p.slider("grade:adj:exposure")?.commit(150)
        redraw(p)
        try click(p, .stopwatch("grade:adj:exposure"))
        XCTAssertTrue(try keys(e, Self.exposure).isEmpty, "the keys are gone")
        XCTAssertEqual(e.colorGrading(clipId: "clip:a")?.adjustValue("exposure"), 1.5, "the value at the playhead stays")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(try keys(e, Self.exposure).count, 2, "one undo brings the animation back")
    }

    func testAmountVignetteGrainAndEachWheelHaveKeyframeControls() throws {
        let (p, e) = try make()
        let watches = ["grade:amount", "grade:det:vignette", "grade:det:grain"].map { key in p.hits.rect { $0 == .stopwatch(key) } != nil }
        XCTAssertEqual(watches, [true, true, true], "Amount, Vignette and Grain stopwatches")
        try click(p, .keyframe("grade:wheelkey:shadows"))
        let wheel = NativeGradeParameter.wheelFields.map { NativeGradeParameter.wheelId("shadows", $0) }
        XCTAssertEqual(try wheel.map { try keys(e, $0).map(\.frame) }, [[30], [30], [30]], "hue, amount and level key together")
        try click(p, .keyframe("grade:det:vignette#gear"))
        XCTAssertEqual(p.grade.finishSettings, "vignette", "the gear still opens the vignette settings")
        try click(p, .keyframe("grade:det:vignette"))
        XCTAssertEqual(try keys(e, NativeGradeParameter.detailId("vignette")).map(\.frame), [30])
    }

    // MARK: Review findings (PR #230)

    func testStartingAnimationOnAPresetOnlyGradeKeysThePresetsValue() throws {
        let (p, e) = try make()
        var g = ColorGrading(); g.preset = "warm-daylight"
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        let warm = try XCTUnwrap(ColorGrading.preset("warm-daylight")?.adjust["exposure"])
        redraw(p)
        try click(p, .stopwatch("grade:adj:exposure"))
        XCTAssertEqual(try keys(e, Self.exposure).map(\.value), [.number(warm)], "the key holds what the preset renders, not 0")
    }

    func testCopyGradeToCarriesTheAnimation() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("grade:adj:exposure"))
        XCTAssertGreaterThan(e.copyColorGrading(from: "clip:a", toAllProjectMedia: true), 0)
        let target = try XCTUnwrap(e.clip("clip:b")).clip
        XCTAssertEqual(target.parameterTracks.filter { $0.parameterId == Self.exposure }.map { $0.keyframes.map(\.frame) }, [[30]])
    }

    func testAWheelHueKeyedAcrossZeroTakesTheShortWay() throws {
        let (p, e) = try make()
        let hue = NativeGradeParameter.wheelId("shadows", "hue")
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a")); g.wheels["shadows"] = ColorGrading.Wheel(hue: 350, amount: 0.5)
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        redraw(p)
        try click(p, .keyframe("grade:wheelkey:shadows"))
        var next = e.gradeShown(clipId: "clip:a", time: 3); next.wheels["shadows"]?.hue = 10
        XCTAssertTrue(e.commitGrade(clipId: "clip:a", time: 3, shown: e.gradeShown(clipId: "clip:a", time: 3), next: next))
        XCTAssertEqual(try keys(e, hue).map(\.value), [.number(350), .number(370)], "10° is keyed as 370° after 350°")
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).wheel("shadows").hue, 10, accuracy: 1e-9, "and shown as 10°")
    }

    func testAStylizeEffectAmountKeys() throws {
        let (p, e) = try make()
        var g = try XCTUnwrap(e.colorGrading(clipId: "clip:a")); g.effects["bloom"] = 1
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", g))
        p.openGroupId = "effects"; redraw(p)
        try click(p, .stopwatch("fx:bloom"))
        XCTAssertEqual(try keys(e, NativeGradeParameter.effectId("bloom")).map(\.value), [.number(1)])
    }
}
