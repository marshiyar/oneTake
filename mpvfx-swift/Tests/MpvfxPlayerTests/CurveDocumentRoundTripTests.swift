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
import MpvfxColor
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// Curves on all seven tabs survive what happens to a project around them: saving `project.json` and opening it
/// again, undo and redo, and keyframing another property of the clip (the grade is a static effect parameter: no
/// keyframe track carries it, so the curves read the same at every time).
final class CurveDocumentRoundTripTests: XCTestCase {
    /// One curve per tab, with inputs and outputs that are not round numbers.
    static var everyCurve: ColorGrading {
        var g = ColorGrading()
        g.curves["master"] = [[0, 0.05], [0.3, 0.2], [0.7, 0.85], [1, 0.95]]
        g.curves["red"] = [[0, 0], [0.58, 0], [0.62, 0.65], [1, 1]]
        g.curves["green"] = [[0, 0.1], [1, 0.9]]
        g.curves["blue"] = [[0, 0], [0.123, 0.456], [1, 1]]
        g.hueCurves["hueVsHue"] = [[0, 0], [30, 40], [90, 0]]
        g.hueCurves["hueVsSaturation"] = [[60, 0], [120, 0.8], [180, 0]]
        g.hueCurves["hueVsLuma"] = [[10.5, -0.25], [200.125, 0.3], [330, 0]]
        return g
    }

    func editor(_ json: String = TimelineEditor.demoJSON) throws -> TimelineEditor {
        try TimelineEditor(json: json, engine: try? KeyframeRuntime())
    }

    /// The renderer's reading of clip:a's grade.
    func rendered(_ e: TimelineEditor) throws -> (curves: [String: [[Double]]], hue: [String: [[Double]]]) {
        let clip = try XCTUnwrap(e.clip("clip:a")?.clip)
        let p = try XCTUnwrap(ColorGradeParams.clipGrade(clip))
        return (p.curves, p.hueCurves)
    }

    func testCurvesSurviveSavingAndReopeningTheProject() throws {
        let e = try editor()
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", Self.everyCurve))
        let saved = try serializeNativeProjectDocument(e.document, engine: try? KeyframeRuntime())
        let reopened = try editor(saved)
        XCTAssertEqual(reopened.colorGrading(clipId: "clip:a"), Self.everyCurve)
        let before = try rendered(e), after = try rendered(reopened)
        XCTAssertEqual(after.curves, before.curves); XCTAssertEqual(after.hue, before.hue)
        XCTAssertEqual(after.curves["blue"], [[0, 0], [0.123, 0.456], [1, 1]], "stored values come back exactly")
        XCTAssertEqual(try serializeNativeProjectDocument(reopened.document, engine: try? KeyframeRuntime()), saved, "a second save writes the same text")
    }

    func testCurvesSurviveUndoAndRedo() throws {
        let e = try editor()
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", Self.everyCurve))
        var flatter = Self.everyCurve
        flatter.curves["master"] = nil
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", flatter))
        e.undo()
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), Self.everyCurve)
        e.redo()
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), flatter)
    }

    /// Keyframing the clip's opacity leaves the grade alone, before and after a save.
    func testKeyframingAnotherPropertyKeepsTheCurves() throws {
        let e = try editor()
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", Self.everyCurve))
        let graded = try rendered(e)
        XCTAssertTrue(e.setAnimated(clipId: "clip:a", [(id: "visual.opacity", fallback: .number(1))], true, time: 0.5))
        XCTAssertTrue(e.setParameter(clipId: "clip:a", "visual.opacity", .number(0.4), time: 1.5))
        XCTAssertFalse(try XCTUnwrap(e.clip("clip:a")?.clip).parameterTracks.isEmpty, "opacity is keyframed")
        XCTAssertEqual(e.colorGrading(clipId: "clip:a"), Self.everyCurve)
        let reopened = try editor(try serializeNativeProjectDocument(e.document, engine: try? KeyframeRuntime()))
        XCTAssertEqual(try rendered(reopened).curves, graded.curves); XCTAssertEqual(try rendered(reopened).hue, graded.hue)
    }
}
