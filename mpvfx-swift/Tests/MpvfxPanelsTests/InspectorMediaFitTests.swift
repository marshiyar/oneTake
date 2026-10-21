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

/// The Media group's Fit dropdown (Fit, Fill, Stretch) for video and image clips: one undo step per pick, the value
/// tier of the row, and its reset back to Fit.
final class InspectorMediaFitTests: XCTestCase {
    static let json = ##"""
    {"schemaVersion":1,"id":"project:fit","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1080,"height":1920,"background":"#111111"},
     "assets":[{"id":"asset:a","kind":"video","name":"a.mp4","source":"media/a.mp4","durationFrames":600,"width":1920,"height":1080},
               {"id":"asset:m","kind":"audio","name":"m.wav","source":"media/m.wav","durationFrames":600}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:a1","kind":"audio","lane":{"authoredTrack":2,"displayTrack":1},"clips":[
       {"id":"clip:m","assetId":"asset:m","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """##

    func panel(select id: String = "clip:a") throws -> (RightPanel, TimelineEditor) {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        let r = RightPanel(layout: layout)
        let editor = try TimelineEditor(json: Self.json)
        r.inspector.editor = editor
        r.inspector.selection = [id]
        r.inspector.openGroupId = "media"
        return (r, editor)
    }

    func button(_ p: InspectorPanel, _ key: String) -> InspectorRow.Button? {
        for row in p.groups.first(where: { $0.id == "media" })?.addressableRows ?? [] {
            if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == key }) { return b }
        }
        return nil
    }

    func testTheMediaGroupOfAVideoClipHasAFitRowAndAnAudioClipHasNone() throws {
        let (r, _) = try panel()
        XCTAssertNotNil(r.inspector.customRow(InspectorPanel.mediaFitRowId))
        XCTAssertEqual(InspectorPanel.mediaFitOptions().map(\.value), ["fit", "fill", "stretch"])
        XCTAssertEqual(InspectorPanel.mediaFitOptions().map(\.label), ["Fit", "Fill", "Stretch"])
        XCTAssertEqual(button(r.inspector, "mediaFit.fit")?.style, .chipActive, "an absent fit shows as Fit")
        let (audio, _) = try panel(select: "clip:m")
        XCTAssertNil(audio.inspector.customRow(InspectorPanel.mediaFitRowId), "a sound has no picture to fit")
    }

    // Acceptance: the inspector's Fit dropdown is one undo step and has the reset-to-default tier.
    func testEachPickIsOneUndoStepAndTheTierFollowsTheValue() throws {
        let (r, editor) = try panel()
        var edits = 0
        r.inspector.onEdited = { edits += 1 }
        XCTAssertEqual(InspectorPanel.mediaFitTier(editor.mediaFit(clipId: "clip:a")), .default)
        XCTAssertEqual(button(r.inspector, "mediaFit.reset")?.disabled, true, "nothing to reset")
        let undoDepth = editor.undoStack.count
        try XCTUnwrap(button(r.inspector, "mediaFit.fill")).action()
        XCTAssertEqual(editor.mediaFit(clipId: "clip:a"), .fill)
        XCTAssertEqual(editor.undoStack.count, undoDepth + 1, "one undo step"); XCTAssertEqual(editor.undoLabel, "Set fit")
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(InspectorPanel.mediaFitTier(editor.mediaFit(clipId: "clip:a")), .explicitCustom)
        XCTAssertEqual(button(r.inspector, "mediaFit.fill")?.style, .chipActive)
        XCTAssertEqual(button(r.inspector, "mediaFit.reset")?.disabled, false)
        try XCTUnwrap(button(r.inspector, "mediaFit.stretch")).action()
        XCTAssertEqual(editor.mediaFit(clipId: "clip:a"), .stretch); XCTAssertEqual(editor.undoStack.count, undoDepth + 2)
        // Reset returns to the default: the key is removed, as in a project that never set it.
        try XCTUnwrap(button(r.inspector, "mediaFit.reset")).action()
        XCTAssertNil(editor.mediaFit(clipId: "clip:a")); XCTAssertEqual(editor.undoStack.count, undoDepth + 3)
        XCTAssertEqual(InspectorPanel.mediaFitTier(nil), .default)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.mediaFit(clipId: "clip:a"), .stretch)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.mediaFit(clipId: "clip:a"), .fill)
        XCTAssertTrue(editor.undo()); XCTAssertNil(editor.mediaFit(clipId: "clip:a"))
        // Picking Fit stores no key, and picking the shown value again is no edit.
        try XCTUnwrap(button(r.inspector, "mediaFit.fit")).action()
        XCTAssertEqual(editor.undoStack.count, undoDepth, "Fit is already the value: nothing to undo")
        XCTAssertEqual(InspectorPanel.mediaFitTier(.fit), .explicitDefault, "a written-out Fit reads as an explicit default")
    }

    func testTheSelectOpensTheDropdownAndTheResetAppearsOnceAFitIsSet() throws {
        let (r, editor) = try panel()
        let size = CanvasSize(409, 900)
        r.draw(PanelMeasureCanvas(), size: size)
        let field = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.mediaFitRowId, 0) }), "the Fit select is drawn")
        XCTAssertNil(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.mediaFitRowId, 1) }), "no reset at the default")
        XCTAssertTrue(r.pointerDown(CanvasPoint(field.midX, field.midY)))
        XCTAssertTrue(r.dropdown.isOpen)
        XCTAssertEqual(r.dropdown.options.map(\.value), ["fit", "fill", "stretch"])
        XCTAssertEqual(r.dropdown.selected, "fit", "the current fit is highlighted")
        r.dropdown.pick("fill")
        XCTAssertFalse(r.dropdown.isOpen)
        XCTAssertEqual(editor.mediaFit(clipId: "clip:a"), .fill); XCTAssertEqual(editor.undoLabel, "Set fit")
        r.draw(PanelMeasureCanvas(), size: size)
        let reset = try XCTUnwrap(r.inspector.hits.rect(where: { $0 == .custom(InspectorPanel.mediaFitRowId, 1) }), "the reset is drawn")
        XCTAssertTrue(r.pointerDown(CanvasPoint(reset.midX, reset.midY)))
        XCTAssertNil(editor.mediaFit(clipId: "clip:a"), "reset to Fit")
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.mediaFit(clipId: "clip:a"), .fill, "the reset was one undo step")
    }

    func testALockedTrackRefusesTheFit() throws {
        let (_, editor) = try panel()
        XCTAssertTrue(editor.setTrackLocked("track:v1", true))
        XCTAssertFalse(editor.setMediaFit(clipId: "clip:a", .fill))
        XCTAssertNil(editor.mediaFit(clipId: "clip:a"))
    }
}
