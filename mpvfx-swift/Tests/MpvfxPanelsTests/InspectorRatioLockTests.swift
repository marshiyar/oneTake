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
@testable import MpvfxTimeline
@testable import MpvfxPanels

final class InspectorRatioLockTests: XCTestCase {
    func panel() throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: InspectorPitchRowTests.json)
        XCTAssertTrue(editor.applyTransform(clipId: "clip:a", time: 0, ClipTransform(width: 400, height: 200)))
        let panel = InspectorPanel()
        panel.editor = editor; panel.selection = ["clip:a"]; panel.openGroupId = "layout"
        return (panel, editor)
    }

    func type(_ panel: InspectorPanel, _ key: String, _ value: String) throws {
        try XCTUnwrap(panel.number(key)).commit(value)
    }

    func testBothSizeFieldsPreserveTheCurrentRatioAsOneUndoStep() throws {
        let (p, e) = try panel()
        try XCTUnwrap(p.toggle("sizeRatioLocked")).set(true)
        XCTAssertTrue(try XCTUnwrap(p.toggle("scaleRatioLocked")).on, "both controls share the clip's lock")
        let depth = e.undoStack.count
        try type(p, "w", "600")
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).width, 600)
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).height, 300)
        XCTAssertEqual(e.undoStack.count, depth + 1)
        try type(p, "h", "100")
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).width, 200)
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).height, 100)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).width, 600)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).height, 200)
        XCTAssertTrue(e.undo())
        XCTAssertFalse(e.scaleRatioLocked(clipId: "clip:a"))
    }

    func testUnlockedSizeAndScaleEditOnlyTheirOwnAxis() throws {
        let (p, e) = try panel()
        try type(p, "w", "600")
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).height, 200)
        try type(p, "h", "100")
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).width, 600)
        try type(p, "scale", "200")
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 0), Vec2Value(x: 2, y: 1))
        try type(p, "scaleY", "50")
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 0), Vec2Value(x: 2, y: 0.5))
    }

    func testBothScaleFieldsKeepANonUniformRatioAndUndoTogether() throws {
        let (p, e) = try panel()
        try type(p, "scale", "200")
        try XCTUnwrap(p.toggle("scaleRatioLocked")).set(true)
        let depth = e.undoStack.count
        try type(p, "scale", "400")
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 0), Vec2Value(x: 4, y: 2))
        XCTAssertEqual(e.undoStack.count, depth + 1)
        try type(p, "scaleY", "50")
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 0), Vec2Value(x: 1, y: 0.5))
        XCTAssertTrue(e.undo()); XCTAssertTrue(e.undo())
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 0), Vec2Value(x: 2, y: 1))
    }

    func testLockPersistsPerClipAndUnlockOmitsTheField() throws {
        let (p, e) = try panel()
        let before = try serializeNativeProjectDocument(e.document)
        try XCTUnwrap(p.toggle("sizeRatioLocked")).set(true)
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document))
        XCTAssertTrue(reopened.scaleRatioLocked(clipId: "clip:a"))
        try XCTUnwrap(p.toggle("scaleRatioLocked")).set(false)
        XCTAssertEqual(try serializeNativeProjectDocument(e.document), before)
    }

    func testAnimatedSizeAndScaleAreKeyedAtThePlayheadInOneStep() throws {
        let (p, e) = try panel()
        try XCTUnwrap(p.number("w")?.keyframe).stopwatch()
        try XCTUnwrap(p.number("scale")?.keyframe).stopwatch()
        XCTAssertTrue(e.isAnimated(clipId: "clip:a", TimelineEditor.widthId))
        XCTAssertTrue(e.isAnimated(clipId: "clip:a", TimelineEditor.heightId))
        XCTAssertTrue(e.isAnimated(clipId: "clip:a", TimelineEditor.scaleId))
        XCTAssertTrue(e.setScaleRatioLocked(clipId: "clip:a", true))
        p.time = 1
        let depth = e.undoStack.count
        try type(p, "w", "600")
        try type(p, "scaleY", "200")
        XCTAssertEqual(e.undoStack.count, depth + 2)
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 1).height, 300)
        XCTAssertEqual(e.transform(clipId: "clip:a", time: 0).height, 200)
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 1), Vec2Value(x: 2, y: 2))
        XCTAssertEqual(e.inspectorScale(clipId: "clip:a", time: 0), Vec2Value(x: 1, y: 1))
        XCTAssertTrue(e.undo()); XCTAssertTrue(e.undo())
        XCTAssertFalse(e.hasKeyframe(clipId: "clip:a", TimelineEditor.widthId, time: 1))
        XCTAssertFalse(e.hasKeyframe(clipId: "clip:a", TimelineEditor.heightId, time: 1))
        XCTAssertFalse(e.hasKeyframe(clipId: "clip:a", TimelineEditor.scaleId, time: 1))
    }

    func testKeyboardCanToggleBothLockControls() throws {
        let (p, e) = try panel()
        p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 1600))
        for key in ["sizeRatioLocked", "scaleRatioLocked"] {
            let hit = InspectorPanel.Hit.toggle(key)
            XCTAssertNotNil(p.hits.rect(where: { $0 == hit }))
            p.focus.current = hit; p.focus.visible = true
            XCTAssertTrue(p.keyDown(EditorKey(.space)))
        }
        XCTAssertFalse(e.scaleRatioLocked(clipId: "clip:a"))
    }

    func testLockedTrackRefusesTheLockAndCoupledEdits() throws {
        let (_, e) = try panel()
        XCTAssertTrue(e.setScaleRatioLocked(clipId: "clip:a", true))
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        let before = e.document, depth = e.undoStack.count
        XCTAssertFalse(e.setScaleRatioLocked(clipId: "clip:a", false))
        XCTAssertFalse(e.setInspectorSize(clipId: "clip:a", time: 0, width: true, value: 800))
        XCTAssertFalse(e.setInspectorScale(clipId: "clip:a", time: 0, x: true, value: 2))
        XCTAssertEqual(e.document, before); XCTAssertEqual(e.undoStack.count, depth)
    }
}
