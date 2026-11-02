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
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes

/// Issue #228: a curve point and a secondary's setting animate as numeric tracks. The grade reads and writes them by id,
/// the shown grade has the keyed value at the playhead, an edit of an animated one keys it there, and stopping the
/// animation keeps the playhead's value.
final class GradeCurveKeyframeModelTests: XCTestCase {
    static let pointY = NativeGradeParameter.curveId("master", 1, "y")
    static let tint = NativeGradeParameter.secondaryId(0, "tint")

    func gradedGrade() -> ColorGrading {
        var g = ColorGrading()
        g.curves["master"] = [[0, 0], [0.5, 0.5], [1, 1]]
        g.hueCurves["hueVsHue"] = [[0, 0], [120, 0.1], [240, 0]]
        var s = ColorGrading.Secondary(); s.hueCenter = 120; s.tint = 0.1
        g.secondaries = [s]
        return g
    }

    func make() throws -> TimelineEditor {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", gradedGrade()))
        return editor
    }

    func keys(_ e: TimelineEditor, _ pid: String) throws -> [NativeKeyframe] {
        try XCTUnwrap(e.clip("clip:a")).clip.parameterTracks.first { $0.parameterId == pid }?.keyframes ?? []
    }

    func testTheGradeReadsAndWritesPointsAndSecondarySettingsById() {
        var g = gradedGrade()
        XCTAssertEqual(g.value(Self.pointY), 0.5)
        XCTAssertEqual(g.value(NativeGradeParameter.curveId("master", 2, "x")), 1)
        XCTAssertEqual(g.value(NativeGradeParameter.hueCurveId("hueVsHue", 1, "x")), 120)
        XCTAssertEqual(g.value(NativeGradeParameter.secondaryId(0, "hueCenter")), 120)
        XCTAssertEqual(g.value(Self.tint), 0.1)
        for id in [NativeGradeParameter.curveId("master", 3, "x"), NativeGradeParameter.curveId("red", 0, "x"), NativeGradeParameter.secondaryId(1, "tint")] {
            XCTAssertNil(g.value(id), "\(id): not in this grade")
        }
        g.set(Self.pointY, 0.9); g.set(Self.tint, -0.3); g.set(NativeGradeParameter.hueCurveId("hueVsHue", 0, "y"), 0.2)
        g.set(NativeGradeParameter.curveId("master", 7, "y"), 1); g.set(NativeGradeParameter.secondaryId(2, "tint"), 1)
        XCTAssertEqual(g.curves["master"], [[0, 0], [0.5, 0.9], [1, 1]])
        XCTAssertEqual(g.hueCurves["hueVsHue"]?.first, [0, 0.2])
        XCTAssertEqual(g.secondaries.map(\.tint), [-0.3], "a point or secondary that is not there is not created")
        for field in NativeGradeParameter.secondaryFields.map(\.field) {
            XCTAssertNotNil(g.value(NativeGradeParameter.secondaryId(0, field)), field)
        }
    }

    func testAnEditOfAnAnimatedPointKeysItAtThePlayheadAndLeavesTheStoredCurve() throws {
        let e = try make()
        XCTAssertTrue(e.setAnimated(clipId: "clip:a", [(Self.pointY, .number(0.5))], true, time: 1))
        XCTAssertEqual(try keys(e, Self.pointY).map(\.frame), [30])
        XCTAssertEqual(NativeGradeParameter.animatedCurveChannels(try XCTUnwrap(e.clip("clip:a")).clip), ["curves.master"])
        let shown = e.gradeShown(clipId: "clip:a", time: 3)
        var next = shown
        next.set(Self.pointY, 0.8)
        next.set(NativeGradeParameter.curveId("master", 2, "y"), 0.9)   // a point that is not animated
        XCTAssertTrue(e.commitGrade(clipId: "clip:a", time: 3, shown: shown, next: next))
        XCTAssertEqual(try keys(e, Self.pointY).map(\.frame), [30, 90])
        XCTAssertEqual(try keys(e, Self.pointY).last?.value, .number(0.8))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 1).value(Self.pointY), 0.5)
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).value(Self.pointY), 0.8)
        let stored = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(stored.curves["master"], [[0, 0], [0.5, 0.5], [1, 0.9]], "the animated point keeps its stored value, the static one is written")
    }

    func testStoppingTheAnimationOfAPointOrASecondaryKeepsThePlayheadValue() throws {
        let e = try make()
        XCTAssertTrue(e.setAnimated(clipId: "clip:a", [(Self.pointY, .number(0.5)), (Self.tint, .number(0.1))], true, time: 1))
        let shown = e.gradeShown(clipId: "clip:a", time: 3)
        var next = shown
        next.set(Self.pointY, 0.8); next.set(Self.tint, -0.4)
        XCTAssertTrue(e.commitGrade(clipId: "clip:a", time: 3, shown: shown, next: next))
        XCTAssertEqual(try keys(e, Self.tint).last?.value, .number(-0.4))
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).secondaries.first?.tint, -0.4)
        XCTAssertTrue(e.stopGradeAnimation(clipId: "clip:a", [Self.pointY, Self.tint], time: 3))
        XCTAssertTrue(try keys(e, Self.pointY).isEmpty)
        XCTAssertTrue(try keys(e, Self.tint).isEmpty)
        let stored = try XCTUnwrap(e.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(stored.curves["master"]?[1], [0.5, 0.8])
        XCTAssertEqual(stored.secondaries.first?.tint, -0.4)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(try keys(e, Self.tint).count, 2, "one undo brings the animation back")
    }
}
