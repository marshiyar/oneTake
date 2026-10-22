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
import OneTakeKeyframes
import MpvfxShared
import MpvfxCanvas
@testable import MpvfxTimeline

final class TimelineSceneSplitTests: XCTestCase {
    func editor(_ json: String = TimelineSlipRollTests.json) throws -> TimelineEditor {
        try TimelineEditor(json: json, engine: KeyframeRuntime())
    }

    func testSourceCutsSplitOnceAndRoundTripWithOneUndo() throws {
        let editor = try editor(), original = try self.editor().document
        XCTAssertTrue(editor.splitScenes(clipId: "clip:a", sourceTimes: [3, 2, 2, 0, 5, .nan]))
        let track = try XCTUnwrap(editor.document.sequence.tracks.first { $0.id == "track:v1" })
        let pieces = track.clips.filter { $0.startFrame < 120 }.sorted { $0.startFrame < $1.startFrame }
        XCTAssertEqual(pieces.map(\.startFrame), [0, 30, 60])
        XCTAssertEqual(pieces.map(\.durationFrames), [30, 30, 60])
        XCTAssertEqual(pieces.map(\.sourceInFrame), [30, 60, 90])
        XCTAssertEqual(editor.undoLabel, "Split at scene changes")
        let json = try serializeNativeProjectDocument(editor.document, engine: editor.engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(json), engine: editor.engine), editor.document)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, original); XCTAssertFalse(editor.canUndo)
    }

    func testRateAndFractionalSourceOffsetMapToTimelineFrames() throws {
        let json = TimelineSlipRollTests.json.replacingOccurrences(of: "\"sourceInFrame\":30,",
            with: "\"sourceInFrame\":30,\"sourceInFraction\":{\"numerator\":1,\"denominator\":2},\"playbackRate\":{\"numerator\":2,\"denominator\":1},")
        let editor = try editor(json)
        XCTAssertTrue(editor.splitScenes(clipId: "clip:a", sourceTimes: [60.5 / 30, 120.5 / 30]))
        let track = try XCTUnwrap(editor.document.sequence.tracks.first { $0.id == "track:v1" })
        XCTAssertEqual(track.clips.filter { $0.startFrame < 120 }.map(\.startFrame).sorted(), [0, 15, 45])
    }

    func testLockedMissingAndOutOfRangeCutsLeaveDocumentAndHistoryUntouched() throws {
        let editor = try editor(), original = editor.document
        XCTAssertFalse(editor.splitScenes(clipId: "clip:l1", sourceTimes: [4]))
        XCTAssertFalse(editor.splitScenes(clipId: "missing", sourceTimes: [2]))
        XCTAssertFalse(editor.splitScenes(clipId: "clip:a", sourceTimes: [0, 1, 5, .infinity]))
        XCTAssertEqual(editor.document, original); XCTAssertFalse(editor.canUndo)
    }

    func testToolbarThresholdAndCancelRemainUsableAfterSelectionChanges() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let controller = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: editor)
        let toolbar = TimelineToolbar(controller: controller)
        var calls = 0
        toolbar.onSplitScenes = { calls += 1 }
        XCTAssertFalse(toolbar.isEnabled(.splitScenes))
        controller.view.selection = ["clip:a"]
        toolbar.activate(.splitScenes); XCTAssertEqual(calls, 1)
        toolbar.adjustSceneThreshold(increase: true); XCTAssertEqual(toolbar.sceneThreshold, 0.4)
        toolbar.adjustSceneThreshold(increase: false); XCTAssertEqual(toolbar.sceneThreshold, 0.3)
        toolbar.sceneProgress = 0.5; controller.view.selection = []
        XCTAssertFalse(toolbar.isEnabled(.sceneThreshold))
        toolbar.activate(.splitScenes); XCTAssertEqual(calls, 2, "active button cancels without a selection")
        XCTAssertTrue(toolbar.tooltip(.splitScenes).contains("50%"))
    }
}
