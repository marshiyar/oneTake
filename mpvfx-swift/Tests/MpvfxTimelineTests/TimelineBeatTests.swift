import MpvfxCanvas
import MpvfxShared
import MpvfxTheme
//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (controller) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
import OneTakeKeyframes
import XCTest

@testable import MpvfxTimeline

internal final class TimelineBeatTests: XCTestCase {
    private static let json: String = """
        {"schemaVersion":1,"mediaEngine":"native","id":"beats","revision":0,"frameRate":{"numerator":30,
         "denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"music","kind":"audio","name":"music","source":"music.wav","durationFrames":900}],
         "sequence":{"id":"seq","name":"Main","tracks":[{"id":"a1","kind":"audio","clips":[
           {"id":"a","assetId":"music","startFrame":30,"durationFrames":240,"sourceInFrame":60,"effects":[],
             "parameterTracks":[]}]}]}}
        """

    private func make() throws -> (TimelineController, TimelineEditor) {
        let editor: TimelineEditor = try TimelineEditor(json: Self.json, engine: KeyframeRuntime())
        let controller: TimelineController = TimelineController(
            view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 20), editor: editor)
        controller.view.selection = ["a"]
        controller.viewport = CanvasSize(1_000, 300)
        controller.playback.seek(2)
        return (controller, editor)
    }
    internal func testA1BUsesAudioClockBetweenVideoTicksAndAddsOneUndoStep() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        controller.playback.play()
        controller.playback.externalClock = { 2.42 }
        XCTAssertTrue(controller.keyDown(EditorKey(.char("b"))))
        XCTAssertEqual(editor.clip("a")?.clip.beats?.frames, [103])
        XCTAssertEqual(controller.view.beats.first?.time ?? 0, 2.42, accuracy: 1 / 30)
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("a")?.clip.beats)
    }
    internal func testA2MovingAndTrimmingKeepMarksOnTheirSourceFrames() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        let address = try XCTUnwrap(editor.address(clipId: "a"))
        XCTAssertTrue(editor.apply(.move(address: address, destination: .init(trackId: "a1", startFrame: 90))))
        XCTAssertEqual(controller.view.beats.map(\.time), [4])
        XCTAssertTrue(editor.apply(.trimIn(address: address, startFrame: 105)))
        XCTAssertEqual(editor.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(controller.view.beats.map(\.time), [4])
        XCTAssertTrue(editor.apply(.trimIn(address: address, startFrame: 135)))
        XCTAssertTrue(controller.view.beats.isEmpty, "trim hides the mark but keeps the source frame")
        XCTAssertEqual(editor.clip("a")?.clip.beats?.frames, [90])
    }
    internal func testA3ClipEdgeSnapsExactlyToBeat() throws {
        let (controller, _): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        let targets: [TimelineSnapTarget] = TimelineSnapping.targets(
            clips: [], playhead: 0, beats: controller.view.beats.map(\.time))
        XCTAssertTrue(targets.contains { $0.time == 2 && $0.type == .beat })
        let target: TimelineSnapTarget = TimelineSnapping.targets(clips: [], playhead: nil, beats: [61.0 / 30])[0]
        XCTAssertEqual(TimelineSnapping.snap(2.04, [target], thresholdSecs: 0.1).time, 61.0 / 30)
    }
    internal func testA4RoundTripAndLegacyByteIdentity() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        let before: String = try serializeNativeProjectDocument(editor.document)
        XCTAssertFalse(before.contains("\"beats\":"))
        XCTAssertEqual(before, try serializeNativeProjectDocument(try NativeJSONValue.parse(before)))
        XCTAssertTrue(controller.addSelectedBeat())
        let saved: String = try serializeNativeProjectDocument(editor.document)
        let reopened: TimelineEditor = try TimelineEditor(json: saved)
        XCTAssertEqual(reopened.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(saved, try serializeNativeProjectDocument(reopened.document))
    }
    internal func testDragDeleteAndJumpUseOneUndoStepEach() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        let rect: CanvasRect = controller.view.clipRect(track: 0, controller.view.tracks[0].clips[0])
        controller.pointerDown(x: controller.view.x(for: 2), y: rect.centerY)
        controller.pointerMove(x: controller.view.x(for: 3), y: rect.centerY)
        XCTAssertEqual(editor.undoStack.count, 1, "no transient document writes")
        controller.pointerUp(x: controller.view.x(for: 3), y: rect.centerY)
        XCTAssertEqual(editor.undoStack.count, 2)
        XCTAssertEqual(controller.view.beats.map(\.time), [3])
        XCTAssertTrue(controller.keyDown(EditorKey(.char("."), alt: true)))
        XCTAssertEqual(controller.playback.currentTime, 3)
        controller.pointerDown(x: controller.view.x(for: 3), y: rect.centerY, alt: true)
        XCTAssertTrue(controller.view.beats.isEmpty)
        XCTAssertEqual(editor.undoStack.count, 3)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(controller.view.beats.map(\.time), [3])
    }
    internal func testDuplicateAndLockedEditsAreRefused() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        XCTAssertFalse(controller.addSelectedBeat())
        XCTAssertTrue(editor.setTrackLocked("a1", true))
        let count = editor.undoStack.count
        XCTAssertFalse(editor.editBeat(clipId: "a", sourceFrame: 90, to: nil))
        XCTAssertEqual(editor.undoStack.count, count)
    }
    internal func testSpeedAndRampProjectMarksBackToTheSameSourceFrame() throws {
        let (_, editor): (TimelineController, TimelineEditor) = try make()
        var clip = try XCTUnwrap(editor.clip("a")?.clip)
        clip.playbackRate = NativePlaybackRate(numerator: 1, denominator: 2)
        XCTAssertEqual(clip.beatSourceFrame(atTimelineFrame: 60), 75)
        XCTAssertEqual(clip.beatTimelineFrame(sourceFrame: 75), 60)
        clip.speedRamp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 60, speed: 2)])
        let source: Double = clip.beatSourceFrame(atTimelineFrame: 60)
        XCTAssertEqual(source, 97.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clip.beatTimelineFrame(sourceFrame: source)), 60, accuracy: 1e-9)
    }
    internal func testFractionalSourceInNeverCreatesAnInvisibleRoundedMark() throws {
        let (_, originalEditor): (TimelineController, TimelineEditor) = try make()
        var d = originalEditor.document
        d.sequence.tracks[0].clips[0].sourceInFraction = NativePlaybackRate(numerator: 1, denominator: 4)
        let editor: TimelineEditor = TimelineEditor(document: try parseNativeProjectDocument(d))
        XCTAssertFalse(editor.addBeat(clipId: "a", at: 1), "source frame 60 is before source-in 60.25")
        XCTAssertTrue(editor.addBeat(clipId: "a", at: 2))
        XCTAssertEqual(editor.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(editor.tracks[0].clips[0].beatTimes[0], 1.9916666667, accuracy: 1e-9)
    }
    internal func testToolbarCallbackObservesPersistedBeatAndOneUndoEntry() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        let toolbar: TimelineToolbar = TimelineToolbar(controller: controller)
        var observedFrames: [Double] = []
        var historyCount: Int = 0
        toolbar.onAddBeat = { _ in
            observedFrames = editor.clip("a")?.clip.beats?.frames ?? []
            historyCount = editor.undoStack.count
        }
        toolbar.activate(.addBeat)
        XCTAssertEqual(observedFrames, [90])
        XCTAssertEqual(historyCount, 1)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip("a")?.clip.beats)
    }

    internal func testRepeatedBIsConsumedWithoutAddingMoreMarks() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        var clockTime: Double = 2
        controller.playback.externalClock = { clockTime }
        controller.playback.play()
        XCTAssertTrue(controller.keyDown(EditorKey(.char("b"))))
        clockTime = 3
        XCTAssertTrue(controller.keyDown(EditorKey(.char("b"), isRepeat: true)))
        XCTAssertEqual(editor.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(editor.undoStack.count, 1)
    }

    internal func testBWithoutAudioSelectionRetainsRazorShortcut() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        controller.view.selection = []
        XCTAssertTrue(controller.keyDown(EditorKey(.char("b"))))
        XCTAssertEqual(controller.tool, .razor)
        XCTAssertTrue(editor.undoStack.isEmpty)
    }

    internal func testRazorAtBeatSplitsInsteadOfDraggingMark() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        controller.tool = .razor
        let rect: CanvasRect = controller.view.clipRect(track: 0, controller.view.tracks[0].clips[0])
        controller.pointerDown(x: controller.view.x(for: 2), y: rect.centerY)
        controller.pointerUp(x: controller.view.x(for: 2), y: rect.centerY)
        XCTAssertNil(controller.beatDrag)
        XCTAssertEqual(editor.document.sequence.tracks[0].clips.count, 2)
    }

    internal func testKeyframeAtBeatKeepsTopmostHitPrecedence() throws {
        let (controller, editor): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        let address = try XCTUnwrap(editor.parameterAddress(clipId: "a", TimelineEditor.volumeId))
        XCTAssertTrue(
            editor.applyProperty(
                .atomic(.keyframe(.upsert(
                    address: address, valueType: .number,
                    frame: 30, value: .number(1), baselineValue: .number(1), outgoing: .linear)))))
        let rect: CanvasRect = controller.view.clipRect(track: 0, controller.view.tracks[0].clips[0])
        controller.pointerDown(x: controller.view.x(for: 2), y: rect.centerY)
        XCTAssertNil(controller.beatDrag)
        controller.pointerUp(x: controller.view.x(for: 2), y: rect.centerY)
        XCTAssertEqual(
            controller.view.selectedKeyframes,
            [
                TimelineKeyframeRef(clipId: "a", parameterId: TimelineEditor.volumeId, frame: 30)
            ])
    }

    internal func testBeatDragClearsOtherClipsKeyframeSelection() throws {
        let (controller, _): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        controller.view.selectedKeyframes = [
            TimelineKeyframeRef(clipId: "other", parameterId: "volume", frame: 30)
        ]
        let rect: CanvasRect = controller.view.clipRect(track: 0, controller.view.tracks[0].clips[0])
        controller.pointerDown(x: controller.view.x(for: 2), y: rect.centerY)
        XCTAssertNotNil(controller.beatDrag)
        XCTAssertEqual(controller.view.selection, ["a"])
        XCTAssertTrue(controller.view.selectedKeyframes.isEmpty)
    }

    internal func testMovingClipsDoNotSnapToTheirOwnBeatMarks() throws {
        let (controller, _): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        controller.view.beats.append(TimelineBeat(time: 4, clipId: "other"))
        controller.view.beats.append(TimelineBeat(time: 5))
        XCTAssertEqual(controller.beatSnapTimes(excluding: ["a"]), [4, 5])
        XCTAssertEqual(controller.beatSnapTimes(excluding: ["a", "other"]), [5])
        let rect: CanvasRect = controller.view.clipRect(track: 0, controller.view.tracks[0].clips[0])
        controller.playback.seek(8)
        controller.pointerDown(x: controller.view.x(for: 1.5), y: rect.centerY)
        controller.pointerMove(x: controller.view.x(for: 2.49), y: rect.centerY)
        guard case .move(_, let delta, _, let snapTime) = controller.view.drag else {
            return XCTFail("expected clip move preview")
        }
        XCTAssertNil(snapTime)
        XCTAssertEqual(delta, 1, accuracy: 1.0 / 30)
    }

    internal func testBeatPaintMovesWithClipPreview() throws {
        let (controller, _): (TimelineController, TimelineEditor) = try make()
        XCTAssertTrue(controller.addSelectedBeat())
        controller.view.drag = .move(clipIds: ["a"], deltaSeconds: 1, trackDelta: 0, snapTime: nil)
        let canvas: RecordingCanvas = RecordingCanvas()
        controller.view.draw(canvas, size: CanvasSize(1_000, 300))
        let clipRect: CanvasRect = controller.view.clipRect(track: 0, controller.view.tracks[0].clips[0])
        let markerColor: CanvasColor = CanvasColor(ThemeTokens.green500)
        let markerCenter: CanvasPoint = CanvasPoint(controller.view.x(for: 3), clipRect.centerY)
        XCTAssertTrue(canvas.painted(markerColor, at: markerCenter))
        XCTAssertFalse(canvas.painted(markerColor, at: CanvasPoint(controller.view.x(for: 2), clipRect.centerY)))
    }

    internal func testFutureVersionRetainsUnknownDataAndAddsOneOpenNotice() throws {
        let (_, editor): (TimelineController, TimelineEditor) = try make()
        var raw = try NativeJSONValue.from(editor.document)
        var sequence = raw["sequence"]!
        var tracks = sequence["tracks"]!.arrayValue!
        var clips = tracks[0]["clips"]!.arrayValue!
        clips[0]["beats"] = .object(["v": .number(2), "kind": .string("future"), "payload": .array([.number(9)])])
        tracks[0]["clips"] = .array(clips)
        sequence["tracks"] = .array(tracks)
        raw["sequence"] = sequence
        let parsed = try parseNativeProjectDocument(raw)
        XCTAssertTrue(parsed.sequence.tracks[0].clips[0].visibleBeatFrames.isEmpty)
        XCTAssertEqual(parsed.undrawnContentNotices.count, 1)
        XCTAssertEqual(
            try NativeJSONValue.from(parsed)["sequence"]?["tracks"]?.arrayValue?[0]["clips"]?.arrayValue?[0]["beats"],
            clips[0]["beats"])
    }
    internal func testValidatorRejectsUnsortedDuplicateNegativeAndOutOfSourceMarks() throws {
        let (_, editor): (TimelineController, TimelineEditor) = try make()
        for frames in [[5.0, 4], [4, 4], [-1], [900], [0.5]] {
            var d = editor.document
            d.sequence.tracks[0].clips[0].beats = NativeClipBeats(frames: frames)
            XCTAssertFalse(validateNativeProjectDocument(try NativeJSONValue.from(d)).isEmpty)
        }
    }
}
