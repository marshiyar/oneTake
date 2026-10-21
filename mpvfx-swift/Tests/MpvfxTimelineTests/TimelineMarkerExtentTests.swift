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

final class TimelineMarkerExtentTests: XCTestCase {
    func rig(_ editor: TimelineEditor) -> (TimelineView, PlaybackState, TimelineController) {
        let view = TimelineView(tracks: [], duration: 0), playback = PlaybackState(duration: 0)
        let controller = TimelineController(view: view, playback: playback, editor: editor)
        controller.viewport = CanvasSize(1200, 300)
        controller.relayout()
        return (view, playback, controller)
    }

    func testImportedAndEditedMarkersExtendNavigationWithoutChangingCompositionEnd() throws {
        let original = try TimelineEditor(json: TimelineEditor.demoJSON)
        var doc = original.document
        let authoredFrames = original.duration * original.fps
        doc.sequence.durationFrames = authoredFrames
        doc.sequence.markers = [.init(id: "tail", time: original.duration + 10, name: "Tail")]
        let editor = TimelineEditor(document: try parseNativeProjectDocument(doc))
        let (view, playback, controller) = rig(editor)
        let time = try XCTUnwrap(editor.document.sequence.markers?.first?.time)
        XCTAssertEqual(editor.duration, time)
        XCTAssertEqual(view.duration, time)
        XCTAssertEqual(playback.duration, time)
        playback.seek(time); controller.syncFromPlayback()
        XCTAssertEqual(playback.currentTime, time)
        XCTAssertGreaterThanOrEqual(view.rulerEnd, time)
        XCTAssertLessThan(view.x(for: time), controller.viewport.width)
        XCTAssertEqual(editor.document.sequence.durationFrames, authoredFrames)
        var marker = try XCTUnwrap(editor.document.sequence.markers?.first)
        marker.time += 20
        XCTAssertTrue(editor.updateMarker(marker))
        XCTAssertEqual(view.duration, marker.time)
        playback.seek(marker.time)
        XCTAssertEqual(playback.currentTime, marker.time)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(view.duration, time)
        XCTAssertEqual(playback.currentTime, time, "Undoing a later marker clamps the playhead to the shorter extent")
        XCTAssertTrue(editor.deleteMarker(marker.id))
        XCTAssertEqual(view.duration, original.duration)
        XCTAssertEqual(playback.currentTime, original.duration)
        XCTAssertEqual(editor.document.sequence.durationFrames, authoredFrames)
    }

    func testEmptyProjectAndZeroMarkerRemainNavigable() throws {
        let source = try TimelineEditor(json: TimelineEditor.demoJSON)
        var doc = source.document
        doc.sequence.durationFrames = nil; doc.sequence.tracks = []
        let editor = TimelineEditor(document: try parseNativeProjectDocument(doc))
        let (view, playback, controller) = rig(editor)
        XCTAssertEqual(editor.duration, 0)
        XCTAssertNotNil(editor.addMarker(at: 0))
        XCTAssertEqual(editor.duration, 0)
        XCTAssertNotNil(editor.addMarker(at: 12))
        XCTAssertEqual(editor.duration, 12)
        XCTAssertEqual(view.duration, 12)
        playback.seek(12); controller.syncFromPlayback()
        XCTAssertEqual(view.currentTime, 12)
        XCTAssertGreaterThanOrEqual(view.rulerEnd, 12)
        XCTAssertNil(editor.document.sequence.durationFrames)
    }

    func testClipTrimAndDeletePreserveMarkerReachabilityAndUndo() throws {
        let source = try TimelineEditor(json: TimelineEditor.demoJSON)
        var doc = source.document
        doc.sequence.durationFrames = nil
        let track = try XCTUnwrap(doc.sequence.tracks.first)
        let clip = try XCTUnwrap(track.clips.first)
        doc.sequence.tracks = [track]
        doc.sequence.tracks[0].clips = [clip]
        let editor = TimelineEditor(document: try parseNativeProjectDocument(doc))
        let (_, playback, controller) = rig(editor)
        let time = editor.duration
        XCTAssertNotNil(editor.addMarker(at: time))
        let address = try XCTUnwrap(editor.address(clipId: clip.id))
        XCTAssertTrue(editor.apply(.trimOut(address: address, endFrameExclusive: clip.startFrame + max(1, clip.durationFrames / 2).rounded())))
        XCTAssertEqual(editor.duration, time)
        XCTAssertTrue(editor.apply(.delete(address: address)))
        XCTAssertEqual(editor.duration, time)
        playback.seek(time); controller.syncFromPlayback()
        XCTAssertEqual(playback.currentTime, time)
        XCTAssertTrue(editor.undo()); XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document.sequence.tracks[0].clips, [clip])
        XCTAssertEqual(editor.document.sequence.markers?.count, 1)
    }

    func testTailMarkersDrawColoredRulerFlagsAtTheirTimes() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON)
        let time = editor.duration + 20
        XCTAssertNotNil(editor.addMarker(at: time, color: "#12ABEF"))
        let (view, _, controller) = rig(editor)
        let canvas = RecordingCanvas()
        view.draw(canvas, size: controller.viewport)
        XCTAssertTrue(canvas.fills.contains { fill in
            fill.color == .documentColor("#12ABEF") && abs(fill.bounds.centerX - view.x(for: time)) < 0.001
                && fill.bounds.y >= 0 && fill.bounds.maxY <= TimelineLayout.rulerHeight
        }, "The tail marker must be painted in its own color inside the visible ruler")
        XCTAssertLessThan(view.x(for: time), controller.viewport.width)
    }
}
