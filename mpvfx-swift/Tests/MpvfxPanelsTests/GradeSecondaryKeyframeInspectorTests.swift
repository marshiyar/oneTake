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

/// Grade secondary keyframes: each secondary slider carries the stopwatch and
/// ‹ ◆ ›, clicking one keys only that setting at the playhead, an edit of an
/// animated setting keys there and leaves the stored value, stopping keeps the
/// playhead value, Add/Remove is refused while a secondary animates, and the
/// second secondary's sliders key independently of the first.
final class GradeSecondaryKeyframeInspectorTests: XCTestCase {
    static let hueShift = NativeGradeParameter.secondaryId(0, "hueShift")
    static let saturation = NativeGradeParameter.secondaryId(0, "saturation")

    /// Slider keys of the selected secondary, in row order (qualifier softness
    /// x3, then the five correction sliders).
    static let secondarySliderKeys = [
        "sec:hue:soft", "sec:saturation:soft", "sec:luma:soft",
        "sec:shift", "sec:sat", "sec:luma", "sec:temp", "sec:tint",
    ]

    /// Demo document, clip:a (video, 30 fps) selected, the Grade group open,
    /// one secondary on the grade, playhead at `time`.
    func make(time: Double = 1, secondaries: Int = 1) throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        var g = ColorGrading()
        g.secondaries = (0..<secondaries).map { _ in ColorGrading.Secondary() }
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.time = time
        p.openGroupId = "grade"
        p.grade.selectedSecondary = 0
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

    func customHead(_ p: InspectorPanel, _ part: Int) throws {
        let r = try XCTUnwrap(p.hits.rect { $0 == .custom("sec:head", part) }, "sec:head[\(part)] is drawn")
        XCTAssertTrue(p.pointerDown(CanvasPoint(r.x + r.width / 2, r.y + r.height / 2)))
        p.pointerUp(CanvasPoint(r.x + r.width / 2, r.y + r.height / 2))
        redraw(p)
    }

    func testEachSecondarySliderShowsAStopwatch() throws {
        let (p, _) = try make()
        for key in Self.secondarySliderKeys {
            let row = try XCTUnwrap(p.slider(key), "\(key) is drawn")
            XCTAssertNotNil(row.keyframe, "\(key) carries keyframe controls")
            XCTAssertNotNil(p.hits.rect { $0 == .stopwatch(key) }, "\(key) shows a stopwatch")
        }
    }

    func testStopwatchKeysOnlyThatSettingInOneUndoStep() throws {
        let (p, e) = try make()
        let undo = e.undoStack.count
        try click(p, .stopwatch("sec:shift"))
        XCTAssertEqual(try keys(e, Self.hueShift).map(\.frame), [30])
        XCTAssertEqual(try keys(e, Self.hueShift).map(\.value), [.number(0)])
        for field in NativeGradeParameter.secondaryFields.map(\.field) where field != "hueShift" {
            XCTAssertTrue(try keys(e, NativeGradeParameter.secondaryId(0, field)).isEmpty, "\(field) stays static")
        }
        XCTAssertEqual(e.undoStack.count, undo + 1, "one undo step")
        XCTAssertEqual(p.slider("sec:shift")?.keyframe?.state, .onKey)
        XCTAssertEqual(p.slider("sec:sat")?.keyframe?.state, .some(.none))
    }

    func testEditingAnAnimatedSettingKeysThereAndLeavesTheStoredValue() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("sec:shift"))
        p.time = 3; redraw(p)
        XCTAssertEqual(p.slider("sec:shift")?.keyframe?.state, .animated)
        p.slider("sec:shift")?.commit(45)
        XCTAssertEqual(try keys(e, Self.hueShift).map(\.frame), [30, 90])
        XCTAssertEqual(try keys(e, Self.hueShift).last?.value, .number(45))
        XCTAssertEqual(try XCTUnwrap(e.colorGrading(clipId: "clip:a")).secondaries.first?.hueShift, 0,
                       "the stored secondary keeps its value")
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).secondaries.first?.hueShift, 45,
                       "the row shows the keyed value")
        p.slider("sec:sat")?.commit(20)
        XCTAssertEqual(try XCTUnwrap(e.colorGrading(clipId: "clip:a")).secondaries.first?.saturation, 0.2,
                       "a static setting is written as before")
        XCTAssertTrue(try keys(e, Self.saturation).isEmpty)
    }

    func testStopwatchOffKeepsThePlayheadValue() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("sec:shift"))
        p.time = 3; redraw(p)
        p.slider("sec:shift")?.commit(45)
        redraw(p)
        try click(p, .stopwatch("sec:shift"))
        XCTAssertTrue(try keys(e, Self.hueShift).isEmpty, "the keys are gone")
        XCTAssertEqual(try XCTUnwrap(e.colorGrading(clipId: "clip:a")).secondaries.first?.hueShift, 45,
                       "the value at the playhead stays")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(try keys(e, Self.hueShift).count, 2, "one undo brings the animation back")
    }

    func testAddAndRemoveRefusedWhileASecondaryAnimates() throws {
        let (p, e) = try make()
        try click(p, .stopwatch("sec:shift"))
        let count = try XCTUnwrap(e.colorGrading(clipId: "clip:a")).secondaries.count
        XCTAssertNil(p.hits.rect { $0 == .custom("sec:head", 0) }, "Add has no hit while animated")
        XCTAssertNil(p.hits.rect { $0 == .custom("sec:head", 1) }, "Remove has no hit while animated")
        let head = try XCTUnwrap(p.customRow("sec:head"), "sec:head is drawn")
        head.pointer(0, CanvasPoint(0, 0), 0)
        redraw(p)
        XCTAssertEqual(try XCTUnwrap(e.colorGrading(clipId: "clip:a")).secondaries.count, count,
                       "Add is refused while animated")
        head.pointer(1, CanvasPoint(0, 0), 0)
        redraw(p)
        XCTAssertEqual(try XCTUnwrap(e.colorGrading(clipId: "clip:a")).secondaries.count, count,
                       "Remove is refused while animated")
        XCTAssertFalse(try keys(e, Self.hueShift).isEmpty, "the animation is untouched")
    }

    func testQualifierRangeStopwatchesKeyTheirRanges() throws {
        let (p, e) = try make()
        let channels: [(SecondaryQualifier, [String])] = [
            (.hue, ["hueCenter", "hueRange"]),
            (.saturation, ["satMin", "satMax"]),
            (.luma, ["lumaMin", "lumaMax"]),
        ]
        for (channel, fields) in channels {
            let key = "sec:qualifier:\(channel.rawValue):keys"
            let row = try XCTUnwrap(p.number(key), "\(key) descriptor is drawn")
            XCTAssertNotNil(row.keyframe, "\(key) carries keyframe controls")
            try click(p, .stopwatch(key))
            for field in fields {
                XCTAssertEqual(try keys(e, NativeGradeParameter.secondaryId(0, field)).map(\.frame), [30],
                               "\(field) is keyed at the playhead")
            }
            XCTAssertEqual(p.number(key)?.keyframe?.state, .onKey, "\(key) shows on-key state")
        }
    }

    func testSecondSecondarySlidersKeyIndependentlyOfTheFirst() throws {
        let (p, e) = try make(secondaries: 2)
        try click(p, .stopwatch("sec:shift"))
        XCTAssertEqual(try keys(e, NativeGradeParameter.secondaryId(0, "hueShift")).map(\.frame), [30])
        XCTAssertTrue(try keys(e, NativeGradeParameter.secondaryId(1, "hueShift")).isEmpty)
        p.grade.selectedSecondary = 1
        redraw(p)
        try click(p, .stopwatch("sec:shift"))
        XCTAssertEqual(try keys(e, NativeGradeParameter.secondaryId(1, "hueShift")).map(\.frame), [30])
        XCTAssertEqual(try keys(e, NativeGradeParameter.secondaryId(0, "hueShift")).map(\.frame), [30],
                       "the first secondary keeps its own track")
        p.time = 3; redraw(p)
        p.slider("sec:shift")?.commit(60)
        XCTAssertEqual(try keys(e, NativeGradeParameter.secondaryId(1, "hueShift")).map(\.frame), [30, 90])
        XCTAssertEqual(try keys(e, NativeGradeParameter.secondaryId(0, "hueShift")).map(\.frame), [30],
                       "editing the second leaves the first track alone")
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).secondaries[1].hueShift, 60)
        XCTAssertEqual(e.gradeShown(clipId: "clip:a", time: 3).secondaries[0].hueShift, 0)
    }
}
