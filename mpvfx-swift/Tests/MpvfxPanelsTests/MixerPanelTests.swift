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
    func testClampedAndLockedKeysAreConsumedWithoutFallback() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let panel = MixerPanel(); panel.editor = editor
        let id = try XCTUnwrap(panel.tracks.first?.id)
        XCTAssertTrue(editor.setTrackMixer(id, gainDB: 12, pan: 1))
        let count = editor.undoStack.count
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertTrue(panel.keyDown(EditorKey(.right, shift: true)))
        XCTAssertEqual(editor.undoStack.count, count)
        XCTAssertTrue(editor.setTrackLocked(id, true))
        let locked = editor.document
        XCTAssertTrue(panel.keyDown(EditorKey(.left)))
        XCTAssertTrue(panel.keyDown(EditorKey(.char("m"))))
        XCTAssertEqual(editor.document, locked)
        XCTAssertFalse(panel.keyDown(EditorKey(.char("x"))))
    }
    func testToggleRepeatsAreConsumedWithoutExtraEdits() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let panel = MixerPanel(); panel.editor = editor
        for key in [Character("m"), Character("s")] {
            XCTAssertTrue(panel.keyDown(EditorKey(.char(key))))
            let snapshot = editor.document, count = editor.undoStack.count
            XCTAssertTrue(panel.keyDown(EditorKey(.char(key), isRepeat: true)))
            XCTAssertEqual(editor.document, snapshot)
            XCTAssertEqual(editor.undoStack.count, count)
        }
    }
    func testKeyboardSelectionRevealsTheNewTrack() throws {
        var document = try MixerPanelTests.audioDocument()
        let template = document.sequence.tracks[0]
        for i in 1...4 { var track = template; track.id = "audio-\(i)"; track.clips = []; track.lane = nil; document.sequence.tracks.append(track) }
        let editor = try TimelineEditor(json: String(decoding: try JSONEncoder().encode(document), as: UTF8.self))
        let panel = MixerPanel(); panel.editor = editor
        let canvas = PanelMeasureCanvas()
        panel.draw(canvas, size: CanvasSize(300, 112))
        for _ in 0..<4 { XCTAssertTrue(panel.keyDown(EditorKey(.down))) }
        canvas.reset(); panel.draw(canvas, size: CanvasSize(300, 112))
        XCTAssertTrue(canvas.drawnStrings.contains("audio-4"))
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertEqual(panel.tracks[4].mixerGainDB, 1)
        let count = editor.undoStack.count
        XCTAssertTrue(panel.keyDown(EditorKey(.char("m"))))
        XCTAssertEqual(editor.undoStack.count, count, "empty-track mute stays handled")
        for _ in 0..<4 { XCTAssertTrue(panel.keyDown(EditorKey(.up))) }
        canvas.reset(); panel.draw(canvas, size: CanvasSize(300, 112))
        XCTAssertTrue(canvas.drawnStrings.contains(template.id))
    }
    private static func audioDocument() throws -> NativeProjectDocument {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        var document = editor.document
        document.sequence.tracks = document.sequence.tracks.filter { $0.kind == .audio }
        document.sequence.tracks[0].lane = nil
        return document
    }

}
