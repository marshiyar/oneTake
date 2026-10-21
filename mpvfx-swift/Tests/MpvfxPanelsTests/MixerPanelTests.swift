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
import MpvfxTimeline
@testable import MpvfxPanels

final class MixerPanelTests: XCTestCase {
    func testRegisteredClosedByDefault() {
        XCTAssertEqual(DockRegistry.editor.title("mixer"), "Mixer")
        XCTAssertEqual(DockRegistry.editor.spec("mixer")?.startsClosed, true)
    }
    func testDraggingDrawnFaderCommitsOneUndoStep() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let panel = MixerPanel(); panel.editor = editor
        let canvas = PanelMeasureCanvas()
        panel.draw(canvas, size: CanvasSize(300, 220))
        XCTAssertTrue(canvas.drawnStrings.contains { $0.contains("Peak") && $0.contains("RMS") })
        let count = editor.undoStack.count
        XCTAssertTrue(panel.pointerDown(CanvasPoint(100, 36), shift: false))
        XCTAssertTrue(panel.pointerMove(CanvasPoint(180, 36)))
        XCTAssertEqual(editor.undoStack.count, count)
        XCTAssertTrue(panel.pointerUp(CanvasPoint(219, 36)))
        XCTAssertEqual(editor.undoStack.count, count + 1)
        XCTAssertEqual(panel.tracks[0].mixerGainDB, -6)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(panel.tracks[0].mixerGainDB)
        XCTAssertTrue(panel.pointerDown(CanvasPoint(220, 10), shift: false))
        XCTAssertTrue(editor.isTrackMuted(panel.tracks[0].id))
        XCTAssertTrue(panel.pointerDown(CanvasPoint(270, 10), shift: false))
        XCTAssertEqual(panel.tracks[0].soloed, true)
    }
    func testFaderPanMuteSoloAndUndo() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let panel = MixerPanel(); panel.editor = editor
        let track = try XCTUnwrap(panel.tracks.first)
        XCTAssertTrue(editor.setTrackMixer(track.id, gainDB: -6, pan: 0.5))
        XCTAssertEqual(panel.tracks[0].mixerGainDB, -6)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(panel.tracks[0].mixerGainDB)
        XCTAssertNil(panel.tracks[0].mixerPan)
        XCTAssertTrue(editor.redo())
        XCTAssertTrue(panel.keyDown(EditorKey(.char("m"))))
        XCTAssertTrue(editor.isTrackMuted(track.id))
        XCTAssertTrue(editor.undo())
        XCTAssertFalse(editor.isTrackMuted(track.id))
        XCTAssertTrue(panel.keyDown(EditorKey(.char("s"))))
        XCTAssertEqual(panel.tracks[0].soloed, true)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(panel.tracks[0].soloed)
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertEqual(panel.tracks[0].mixerGainDB, -5)
        XCTAssertFalse(editor.setTrackMixer(track.id, gainDB: .nan, pan: 0))
    }
}
