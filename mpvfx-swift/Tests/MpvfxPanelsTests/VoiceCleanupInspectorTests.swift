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
import MpvfxAudioGraph
import MpvfxShared
@testable import MpvfxPanels
@testable import MpvfxTimeline

final class VoiceCleanupInspectorTests: XCTestCase {
    func fixture() throws -> (TimelineEditor, InspectorPanel) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let panel = InspectorPanel()
        panel.editor = editor; panel.selection = ["clip:music"]; panel.openGroupId = "audio-fx"
        return (editor, panel)
    }
    func draw(_ panel: InspectorPanel) {
        panel.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 409, height: 4000))
    }
    func chain(_ editor: TimelineEditor) throws -> FxChain {
        try AudioFx.parseChain(XCTUnwrap(editor.clip("clip:music")?.clip.audioFxChain))
    }
    func activate(_ key: String, _ panel: InspectorPanel, code: EditorKey.Code = .enter) {
        draw(panel)
        panel.focus.current = .button(key); panel.focus.visible = true
        XCTAssertNotNil(panel.hits.rect { $0 == .button(key) })
        XCTAssertTrue(panel.keyDown(EditorKey(code)))
    }

    func testKeyboardApplyAndBeforeAfterEachAreOneUndoStep() throws {
        let (editor, panel) = try fixture()
        let original = editor.clip("clip:music")?.clip.audioFxChain
        activate("voice-cleanup:apply", panel)
        XCTAssertTrue(VoiceCleanup.isEnabled(try chain(editor)))
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.clip("clip:music")?.clip.audioFxChain, original)
        XCTAssertTrue(editor.redo())
        let strength = VoiceCleanup.strength(try chain(editor))
        activate("voice-cleanup:listen", panel, code: .space)
        XCTAssertFalse(VoiceCleanup.isEnabled(try chain(editor)))
        XCTAssertEqual(VoiceCleanup.strength(try chain(editor)), strength)
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(VoiceCleanup.isEnabled(try chain(editor)))
    }

    func testStrengthDragCommitsOnceAndProjectDocumentRoundTrips() throws {
        let (editor, panel) = try fixture()
        activate("voice-cleanup:apply", panel)
        let initial = VoiceCleanup.strength(try chain(editor))
        draw(panel)
        let slider = try XCTUnwrap(panel.hits.rect { $0 == .slider("voice-cleanup:strength") })
        let point = CanvasPoint(slider.x + slider.width * 0.3, slider.midY)
        XCTAssertTrue(panel.pointerDown(point))
        panel.pointerUp(point)
        let changed = VoiceCleanup.strength(try chain(editor))
        XCTAssertEqual(changed, 0.3, accuracy: 0.02)
        let json = try serializeNativeProjectDocument(editor.document)
        let reopened = try TimelineEditor(json: json)
        XCTAssertEqual(VoiceCleanup.strength(try chain(reopened)), changed)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(VoiceCleanup.strength(try chain(editor)), initial)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("clip:music")?.clip.audioFxChain)
    }
}
