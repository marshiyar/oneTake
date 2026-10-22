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

final class InspectorTransitionTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"Interview 1","source":"a.mov","durationFrames":300},
               {"id":"a2","kind":"video","name":"Interview 2","source":"b.mov","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}],
      "transitions":[{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30,"alignment":"centre"}]}]}}
    """#
    func panel() throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: Self.json)
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = ["A"]; panel.openGroupId = "transitions"
        return (panel, editor)
    }
    func rows(_ panel: InspectorPanel) -> [InspectorRow] { panel.groups.first { $0.id == "transitions" }?.addressableRows ?? [] }
    func pick(_ panel: InspectorPanel, _ key: String, _ value: String) throws {
        for row in rows(panel) { if case .segmented(let field) = row.kind, field.key == key { field.select(value); return } }
        XCTFail("Missing control \(key)")
    }
    func testKindDirectionSoftnessDurationAndDipColorEachUseOneUndoStep() throws {
        let (panel, editor) = try panel()
        let original = editor.document
        try pick(panel, "transition:kind", "wipe")
        try pick(panel, "transition:direction", "down")
        for row in rows(panel) {
            if case .slider(let field) = row.kind, field.key == "transition:softness" { field.commit(40) }
            if case .number(let field) = row.kind, field.key == "transition:duration" { field.commit("20") }
        }
        XCTAssertEqual(editor.undoStack.count, 4)
        let wipe = editor.document.sequence.tracks[0].transitions![0]
        XCTAssertEqual(wipe.kind, .wipe); XCTAssertEqual(wipe.direction, .down); XCTAssertEqual(wipe.softness, 0.4); XCTAssertEqual(wipe.durationFrames, 20)
        let saved = try serializeNativeProjectDocument(editor.document)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(saved)).sequence.tracks[0].transitions, [wipe])
        try pick(panel, "transition:kind", "dip"); try pick(panel, "transition:color", "#ffffff")
        XCTAssertEqual(editor.undoStack.count, 6)
        XCTAssertEqual(editor.document.sequence.tracks[0].transitions![0].color, "#ffffff")
        for _ in 0..<6 { XCTAssertTrue(editor.undo()) }
        XCTAssertEqual(editor.document, original)
    }

    func testKeyboardReachesTransitionKindDurationAndRemoveAndEditsTheKind() throws {
        let (panel, editor) = try panel()
        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 1000))
        var seen: [InspectorPanel.Hit] = []
        for _ in 0..<100 {
            _ = panel.keyDown(EditorKey(.tab))
            if let hit = panel.focus.current { seen.append(hit) }
        }
        XCTAssertTrue(seen.contains(.field("transition:duration")))
        XCTAssertTrue(seen.contains(.button("transition:remove")))
        let kind = try XCTUnwrap(seen.first { $0 == .segment("transition:kind", "push") })
        panel.focus.current = kind; panel.focus.visible = true
        XCTAssertTrue(panel.keyDown(EditorKey(.space)))
        XCTAssertEqual(editor.document.sequence.tracks[0].transitions![0].kind, .push)
        XCTAssertEqual(editor.undoStack.count, 1)
    }

    func testLockedTrackDisablesTransitionControls() throws {
        let (panel, editor) = try panel()
        XCTAssertTrue(editor.setTrackLocked("v1", true))
        XCTAssertFalse(rows(panel).contains { if case .segmented = $0.kind { return true }; return false })
    }
}
