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
@testable import MpvfxTimeline
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes

/// #201: a keyed clip shows one summary row; U (or the row's disclosure) expands it to one row per animated
/// property, grouped by kind, each kind foldable; the state is kept per clip; coincident keys stack into one mark
/// with a count, and a summary mark drags every key under it.
final class TimelineKeyframeLaneTests: XCTestCase {
    /// Demo document (30 fps), clip:a (video 0…180, row 1) keyed at frame 60 on Position, Scale and Opacity and at
    /// frame 90 on Tilt X and Tilt Y, clip:a selected.
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 600); c.snapEnabled = false
        try key(e, [TimelineEditor.positionId: .vec2(Vec2Value(x: 1, y: 2)), TimelineEditor.scaleId: .vec2(Vec2Value(x: 1, y: 1)),
                    TimelineEditor.opacityId: .number(0.5)], frame: 60)
        try key(e, [NativeTransform3D.rotationXId: .number(10), NativeTransform3D.rotationYId: .number(20)], frame: 90)
        c.view.selection = ["clip:a"]
        return (c, e)
    }

    func key(_ e: TimelineEditor, _ values: [String: NativeParameterValue], frame: Double, outgoing: NativeInterpolation? = nil) throws {
        let cmds: [NativeProjectAtomicPropertyCommand] = try values.sorted { $0.key < $1.key }.map { pid, v in
            let a = try XCTUnwrap(e.parameterAddress(clipId: "clip:a", pid))
            return .keyframe(.upsert(address: a, valueType: TimelineEditor.valueType(v), frame: frame, value: v, baselineValue: v, outgoing: outgoing))
        }
        XCTAssertTrue(e.applyProperty(.batch(cmds)))
    }

    func clipA(_ c: TimelineController) throws -> TimelineClipModel { try XCTUnwrap(c.view.tracks[1].clips.first { $0.id == "clip:a" }) }
    func rowY(_ c: TimelineController, _ j: Int) -> Double { c.view.rowTop(1) + c.view.trackHeight + (Double(j) + 0.5) * TimelineLayout.laneHeight }
    func frames(_ e: TimelineEditor) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: (e.clip("clip:a")?.clip.parameterTracks ?? []).map { ($0.parameterId, $0.keyframes.map(\.frame)) })
    }

    // MARK: Which rows exist

    func testAKeyedClipShowsOneSummaryRowAndAnUnkeyedClipNone() throws {
        let (c, _) = try make()
        XCTAssertEqual(c.view.laneRows(try clipA(c)), [.summary], "one collapsed summary row by default")
        XCTAssertEqual(c.view.trackRowHeight(1), c.view.trackHeight + TimelineLayout.laneHeight)
        let b = try XCTUnwrap(c.view.tracks[1].clips.first { $0.id == "clip:b" })
        XCTAssertEqual(c.view.laneRows(b), [], "no keys, no row")
        XCTAssertEqual(c.view.keyframeMarks(try clipA(c), scope: nil).map(\.frame), [60, 90], "the summary holds every key")
    }

    func testExpandedShowsOnlyAnimatedPropertiesGroupedByKind() throws {
        let (c, _) = try make()
        XCTAssertTrue(c.keyDown(EditorKey(.char("u"))))
        XCTAssertEqual(c.view.laneRows(try clipA(c)), [.summary, .kind(.transform), .property("position"), .property("scale"),
                                                      .kind(.threeD), .property("tiltX"), .property("tiltY"), .property("opacity")],
                       "a kind with one property (Opacity) shows just that property's row; Rotation, Depth… are not animated")
    }

    func testEachKindFoldsOnItsOwnAndTheSummaryDisclosureCollapses() throws {
        let (c, _) = try make()
        XCTAssertTrue(c.keyDown(EditorKey(.char("u"))))
        let kindRow = try XCTUnwrap(c.view.laneRows(try clipA(c)).firstIndex(of: .kind(.transform)))
        let caret = TimelineView.disclosureRect(laneTop: rowY(c, kindRow) - TimelineLayout.laneHeight / 2, row: .kind(.transform))
        c.pointerDown(x: caret.centerX, y: caret.centerY); c.pointerUp(x: caret.centerX, y: caret.centerY)
        XCTAssertEqual(c.view.laneRows(try clipA(c)), [.summary, .kind(.transform), .kind(.threeD), .property("tiltX"), .property("tiltY"), .property("opacity")])
        let summary = TimelineView.disclosureRect(laneTop: rowY(c, 0) - TimelineLayout.laneHeight / 2, row: .summary)
        c.pointerDown(x: summary.centerX, y: summary.centerY); c.pointerUp(x: summary.centerX, y: summary.centerY)
        XCTAssertEqual(c.view.laneRows(try clipA(c)), [.summary], "the summary's caret collapses the clip")
        XCTAssertTrue(c.toggleDisclosure(clipId: "clip:a", row: .summary))
        XCTAssertFalse(c.view.laneRows(try clipA(c)).contains(.property("position")), "the folded kind stays folded")
    }

    func testTheStateIsKeptPerClipAcrossEditsAndUndo() throws {
        let (c, e) = try make()
        try key(e, [TimelineEditor.rotationId: .number(5)], frame: 10)
        _ = try XCTUnwrap(e.clip("clip:b"))
        XCTAssertTrue(c.toggleDisclosure(clipId: "clip:a", row: .summary))
        XCTAssertTrue(c.toggleDisclosure(clipId: "clip:a", row: .kind(.threeD)))
        XCTAssertTrue(e.undo())
        XCTAssertTrue(c.view.expandedClips.contains("clip:a"), "still expanded after an undo")
        XCTAssertEqual(c.view.collapsedKinds["clip:a"], [.threeD])
        XCTAssertFalse(c.view.expandedClips.contains("clip:b"), "another clip keeps its own state")
    }

    // MARK: Stacking

    func testCoincidentKeysStackIntoOneMarkWithACount() throws {
        let (c, _) = try make()
        let marks = c.view.keyframeMarks(try clipA(c), scope: nil)
        XCTAssertEqual(marks.first?.labels, ["Position", "Scale", "Opacity"])
        XCTAssertEqual(marks.first?.count, 3)
        XCTAssertNil(marks.first?.kind, "two kinds at frame 60: a neutral stack mark")
        XCTAssertEqual(marks.last?.kinds, [.threeD]); XCTAssertEqual(marks.last?.count, 2, "Tilt X and Tilt Y share a 3D mark")
        let transform = c.view.keyframeMarks(try clipA(c), scope: c.view.rowScope(.kind(.transform), try clipA(c)))
        XCTAssertEqual(transform.map(\.count), [2]); XCTAssertEqual(transform.first?.kind, .transform)
    }

    func testTheInterpolationIsTheMarksVariant() throws {
        let (c, e) = try make()
        try key(e, [TimelineEditor.rotationId: .number(5)], frame: 20, outgoing: .hold)
        try key(e, [TimelineEditor.rotationId: .number(9)], frame: 30, outgoing: .cubicBezier(CubicBezierControlPoints(x1: 0.4, y1: 0, x2: 0.2, y2: 1)))
        let rotation = c.view.keyframeMarks(try clipA(c), scope: ["rotation"])
        XCTAssertEqual(rotation.map(\.ease), [.hold, .ease])
        XCTAssertEqual(c.view.keyframeMarks(try clipA(c), scope: ["opacity"]).map(\.ease), [.linear])
    }

    func testEveryKindHasItsOwnShape() {
        XCTAssertEqual(Set(TimelineKeyframeKind.allCases.map(\.shape)).count, TimelineKeyframeKind.allCases.count)
        XCTAssertEqual(Set(TimelineKeyframeKind.allCases.map { $0.colorPair.dark.r * 1e6 + $0.colorPair.dark.g * 1e3 + $0.colorPair.dark.b }).count,
                       TimelineKeyframeKind.allCases.count, "and its own colour")
    }

    // MARK: Hit-testing and drag

    func testMarksOnEveryRowHitWithTheirScope() throws {
        let (c, _) = try make()
        let x60 = c.view.x(for: 2), x90 = c.view.x(for: 3)
        let summary = try XCTUnwrap(c.view.keyframeHit(x: x60, y: rowY(c, 0)))
        XCTAssertEqual(summary.laneRow, .summary); XCTAssertNil(summary.lane)
        XCTAssertEqual(Set(summary.refs.map(\.parameterId)), [TimelineEditor.positionId, TimelineEditor.scaleId, TimelineEditor.opacityId])
        XCTAssertTrue(c.keyDown(EditorKey(.char("u"))))
        let threeD = try XCTUnwrap(c.view.keyframeHit(x: x90, y: rowY(c, 4)))
        XCTAssertEqual(threeD.laneRow, .kind(.threeD))
        XCTAssertEqual(Set(threeD.refs.map(\.parameterId)), [NativeTransform3D.rotationXId, NativeTransform3D.rotationYId])
        let tiltY = try XCTUnwrap(c.view.keyframeHit(x: x90, y: rowY(c, 6)))
        XCTAssertEqual(tiltY.laneRow, .property("tiltY")); XCTAssertEqual(tiltY.refs.map(\.parameterId), [NativeTransform3D.rotationYId])
        XCTAssertNil(c.view.keyframeHit(x: x60, y: rowY(c, 4)), "no 3D key at frame 60")
    }

    func testDraggingASummaryMarkMovesEveryKeyUnderItAsOneUndoStep() throws {
        let (c, e) = try make()
        let undo = e.undoStack.count, y = rowY(c, 0)
        c.pointerDown(x: c.view.x(for: 2), y: y)
        c.pointerMove(x: c.view.x(for: 2) + 5, y: y)
        c.pointerMove(x: c.view.x(for: 2.5), y: y)
        c.pointerUp(x: c.view.x(for: 2.5), y: y)
        let f = frames(e)
        XCTAssertEqual([f[TimelineEditor.positionId], f[TimelineEditor.scaleId], f[TimelineEditor.opacityId]], [[75], [75], [75]])
        XCTAssertEqual(f[NativeTransform3D.rotationXId], [90], "keys at other frames stay")
        XCTAssertEqual(e.undoStack.count, undo + 1); XCTAssertEqual(e.undoLabel, "Move 3 keyframes")
        XCTAssertTrue(e.undo()); XCTAssertEqual(frames(e)[TimelineEditor.scaleId], [60])
    }

    func testSummaryRowControlsStepThroughEveryKindAndKeyThemAll() throws {
        let (c, e) = try make()
        c.playback.seek(1); c.syncFromPlayback()
        XCTAssertTrue(c.laneRowControlClick(clipId: "clip:a", row: .summary, control: .next))
        XCTAssertEqual(c.playback.currentTime, 2, accuracy: 1e-9)
        XCTAssertTrue(c.laneRowControlClick(clipId: "clip:a", row: .summary, control: .next))
        XCTAssertEqual(c.playback.currentTime, 3, accuracy: 1e-9, "the 3D keys are on the summary too")
        c.playback.seek(4); c.syncFromPlayback()
        XCTAssertTrue(c.laneRowControlClick(clipId: "clip:a", row: .summary, control: .toggle))
        XCTAssertEqual(Set(frames(e).filter { $0.value.contains(120) }.keys).count, 5, "◆ keys every animated property at the playhead")
        XCTAssertTrue(c.laneRowControlClick(clipId: "clip:a", row: .kind(.threeD), control: .toggle))
        XCTAssertEqual(frames(e)[NativeTransform3D.rotationXId], [90], "the 3D row's ◆ on a key removes only the 3D keys there")
        XCTAssertEqual(frames(e)[TimelineEditor.positionId], [60, 120])
    }
}
