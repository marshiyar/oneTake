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

/// The keyframe diamond context menu: right-click opens it on the diamond (never
/// the clip menu), its targets follow the key selection, and each action is one undo step.
final class TimelineKeyframeMenuTests: XCTestCase {
    /// Demo document: clip:a is 0..180 frames (30 fps) on row 1, keyed (position) at 0, 2 and 4 s; playhead at 5 s.
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 400)
        c.snapEnabled = false
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        c.view.expandedClips = []
        c.playback.seek(5); c.syncFromPlayback()
        return (c, e)
    }

    func barY(_ c: TimelineController) -> Double { c.view.rowTop(1) + c.view.trackHeight / 2 }
    func x(_ c: TimelineController, _ t: Double) -> Double { c.view.x(for: t) }
    func frames(_ e: TimelineEditor) -> [Double] {
        Array(Set(e.clip("clip:a")!.clip.parameterTracks.flatMap { $0.keyframes.map(\.frame) })).sorted()
    }
    func outgoing(_ e: TimelineEditor, frame: Double) -> [NativeInterpolation] {
        e.clip("clip:a")!.clip.parameterTracks.compactMap { $0.keyframes.first { $0.frame == frame }?.outgoing }
    }
    func labels(_ m: TimelineKeyframeMenu) -> [String] {
        m.entries.map { e -> String in if case .item(let i) = e { return i.label }; return "—" }
    }
    func item(_ m: TimelineKeyframeMenu, _ a: TimelineKeyframeMenu.Action) throws -> TimelineKeyframeMenu.Item {
        try XCTUnwrap(m.itemRects().first { $0.0.action == a }?.0)
    }
    func click(_ c: TimelineController, _ m: TimelineKeyframeMenu, _ a: TimelineKeyframeMenu.Action) throws {
        let r = try XCTUnwrap(m.itemRects().first { $0.0.action == a }).1
        c.pointerDown(x: r.x + 20, y: r.y + 10); c.pointerUp(x: r.x + 20, y: r.y + 10)
    }

    func testRightClickOnADiamondOpensTheKeyframeMenuNotTheClipMenu() throws {
        let (c, e) = try make()
        let undo = e.undoStack.count
        c.secondaryClick(x: x(c, 2), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        XCTAssertNil(c.view.clipMenu)
        XCTAssertEqual(labels(m), ["Move to Playhead", "—", "Linear", "Ease In", "Ease Out", "Ease In-Out", "Hold", "Edit Easing…", "—",
                                   "Delete Keyframe", "Delete All Keyframes"])
        XCTAssertEqual(Set(c.view.selectedKeyframes.map(\.frame)), [60], "the clicked diamond becomes the selection")
        XCTAssertEqual(c.playback.currentTime, 5, accuracy: 1e-9, "opening the menu does not seek")
        XCTAssertEqual(try item(m, .linear).checked, true, "a new key is linear")
        XCTAssertEqual(e.undoStack.count, undo, "opening the menu edits nothing")
        // Right-click on the clip body between diamonds still opens the clip menu.
        c.secondaryClick(x: x(c, 3), y: barY(c))
        XCTAssertNil(c.view.keyframeMenu); XCTAssertNotNil(c.view.clipMenu)
    }

    func testEasePresetSetsTheOutgoingEaseAsOneUndoStep() throws {
        let (c, e) = try make()
        c.secondaryClick(x: x(c, 2), y: barY(c))
        let undo = e.undoStack.count
        try click(c, try XCTUnwrap(c.view.keyframeMenu), .easeInOut)
        XCTAssertNil(c.view.keyframeMenu)
        let inOut = try XCTUnwrap(TimelineKeyframeMenu.eases.first { $0.action == .easeInOut }).value
        XCTAssertFalse(outgoing(e, frame: 60).isEmpty)
        XCTAssertTrue(outgoing(e, frame: 60).allSatisfy { $0 == inOut })
        XCTAssertTrue(outgoing(e, frame: 0).allSatisfy { $0 == .linear }, "other keys keep their ease")
        XCTAssertEqual(e.undoStack.count, undo + 1)
        // Reopened, the menu checks the key's current ease.
        c.secondaryClick(x: x(c, 2), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        XCTAssertEqual(try item(m, .easeInOut).checked, true); XCTAssertEqual(try item(m, .linear).checked, false)
        XCTAssertTrue(e.undo()); XCTAssertTrue(outgoing(e, frame: 60).allSatisfy { $0 == .linear })
    }

    func testMenuActsOnTheWholeSelectionWhenTheDiamondBelongsToIt() throws {
        let (c, e) = try make()
        c.pointerDown(x: x(c, 2), y: barY(c)); c.pointerUp(x: x(c, 2), y: barY(c))
        c.pointerDown(x: x(c, 4), y: barY(c), shift: true); c.pointerUp(x: x(c, 4), y: barY(c))
        c.secondaryClick(x: x(c, 4), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        XCTAssertEqual(Set(m.refs.map(\.frame)), [60, 120])
        XCTAssertEqual(try item(m, .delete).label, "Delete 2 Keyframes")
        try click(c, m, .hold)
        XCTAssertTrue((outgoing(e, frame: 60) + outgoing(e, frame: 120)).allSatisfy { $0 == .hold })
        // A diamond outside the selection replaces it.
        c.secondaryClick(x: x(c, 0) + 2, y: barY(c))
        XCTAssertEqual(Set(try XCTUnwrap(c.view.keyframeMenu).refs.map(\.frame)), [0])
        XCTAssertEqual(try item(try XCTUnwrap(c.view.keyframeMenu), .linear).checked, true)
    }

    func testMoveToPlayheadRetimesTheKeysOrIsDisabled() throws {
        let (c, e) = try make()
        c.secondaryClick(x: x(c, 4), y: barY(c))
        try click(c, try XCTUnwrap(c.view.keyframeMenu), .moveToPlayhead)
        XCTAssertEqual(frames(e), [0, 60, 150])
        XCTAssertEqual(e.undoLabel, "Move keyframes to playhead")
        XCTAssertEqual(Set(c.view.selectedKeyframes.map(\.frame)), [150], "the selection follows the key")
        // Already on the playhead: disabled, and a click leaves the menu open.
        c.secondaryClick(x: x(c, 5), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        XCTAssertFalse(try item(m, .moveToPlayhead).enabled)
        try click(c, m, .moveToPlayhead)
        XCTAssertNotNil(c.view.keyframeMenu)
        c.keyDown(EditorKey(.escape)); XCTAssertNil(c.view.keyframeMenu)
        // Onto another key of the same parameter: disabled.
        c.playback.seek(2); c.syncFromPlayback()
        c.secondaryClick(x: x(c, 0) + 2, y: barY(c))
        XCTAssertFalse(try item(try XCTUnwrap(c.view.keyframeMenu), .moveToPlayhead).enabled)
        // Past another key without landing on it (0 s → 3 s crosses the key at 2 s): disabled, as for a drag.
        c.view.keyframeMenu = nil
        c.playback.seek(3); c.syncFromPlayback()
        c.secondaryClick(x: x(c, 0) + 2, y: barY(c))
        XCTAssertFalse(try item(try XCTUnwrap(c.view.keyframeMenu), .moveToPlayhead).enabled)
        // Past the clip's end: disabled.
        c.view.keyframeMenu = nil
        c.playback.seek(7); c.syncFromPlayback()
        c.secondaryClick(x: x(c, 0) + 2, y: barY(c))
        XCTAssertFalse(try item(try XCTUnwrap(c.view.keyframeMenu), .moveToPlayhead).enabled)
    }

    func testEditEasingHandsTheKeysToTheHost() throws {
        let (c, e) = try make()
        // No host easing editor: the item is disabled and a click leaves the menu open.
        c.secondaryClick(x: x(c, 2), y: barY(c))
        XCTAssertFalse(try item(try XCTUnwrap(c.view.keyframeMenu), .editEasing).enabled)
        try click(c, try XCTUnwrap(c.view.keyframeMenu), .editEasing)
        XCTAssertNotNil(c.view.keyframeMenu)
        c.keyDown(EditorKey(.escape))
        var opened: [(String, Set<TimelineKeyframeRef>)] = []
        c.onEditKeyframeEasing = { opened.append(($0, $1)) }
        c.secondaryClick(x: x(c, 2), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        XCTAssertTrue(try item(m, .editEasing).enabled)
        let undo = e.undoStack.count
        try click(c, m, .editEasing)
        XCTAssertNil(c.view.keyframeMenu)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "clip:a"); XCTAssertEqual(opened.first?.1, m.refs)
        XCTAssertEqual(Set(opened.first?.1.map(\.frame) ?? []), [60])
        XCTAssertEqual(e.undoStack.count, undo, "opening the editor edits nothing")
    }

    func testEditEasingIsDisabledOnKeysWithoutAnEasingEditor() throws {
        let (c, e) = try make()
        c.onEditKeyframeEasing = { _, _ in XCTFail("no editor for these keys") }
        let a = NativeProjectParameterAddress(sequenceId: e.sequenceId, trackId: try XCTUnwrap(e.clip("clip:a")).track.id,
                                              clipId: "clip:a", parameterId: "layout.zIndex")
        XCTAssertTrue(e.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: 90, value: .number(1), baselineValue: .number(0))))))
        c.syncFromPlayback()
        c.secondaryClick(x: x(c, 3), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        XCTAssertEqual(m.refs.map(\.parameterId), ["layout.zIndex"])
        XCTAssertFalse(try item(m, .editEasing).enabled)
        try click(c, m, .editEasing)
        XCTAssertNotNil(c.view.keyframeMenu, "a disabled item does nothing")
    }

    func testDeleteAndDeleteAll() throws {
        let (c, e) = try make()
        c.secondaryClick(x: x(c, 2), y: barY(c))
        try click(c, try XCTUnwrap(c.view.keyframeMenu), .delete)
        XCTAssertEqual(frames(e), [0, 120])
        XCTAssertTrue(c.view.selectedKeyframes.isEmpty)
        XCTAssertEqual(e.clip("clip:a")?.clip.startFrame, 0, "the clip stays")
        c.secondaryClick(x: x(c, 4), y: barY(c))
        let undo = e.undoStack.count
        try click(c, try XCTUnwrap(c.view.keyframeMenu), .deleteAll)
        XCTAssertEqual(frames(e), [])
        XCTAssertEqual(e.undoStack.count, undo + 1); XCTAssertEqual(e.undoLabel, "Delete all keyframes")
        XCTAssertNotNil(e.clip("clip:a"))
        XCTAssertTrue(e.undo()); XCTAssertEqual(frames(e), [0, 120])
    }

    func testClickOutsideClosesAndTheMenuDraws() throws {
        let (c, _) = try make()
        c.secondaryClick(x: x(c, 2), y: barY(c))
        let m = try XCTUnwrap(c.view.keyframeMenu)
        c.pointerMove(x: m.itemRects()[1].1.x + 20, y: m.itemRects()[1].1.y + 10)
        XCTAssertEqual(c.view.keyframeMenu?.hovered, .linear)
        let r = RecordingCanvas()
        c.view.draw(r, size: c.viewport)
        XCTAssertTrue(r.texts.contains("Delete All Keyframes")); XCTAssertTrue(r.texts.contains("✓"))
        c.pointerDown(x: m.rect.maxX + 40, y: m.rect.maxY + 40)
        XCTAssertNil(c.view.keyframeMenu)
    }
}
