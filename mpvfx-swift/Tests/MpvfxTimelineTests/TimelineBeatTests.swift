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
import MpvfxShared
import MpvfxCanvas

final class TimelineBeatTests: XCTestCase {
    static let json = """
    {"schemaVersion":1,"mediaEngine":"native","id":"beats","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":36,"background":"#000000"},
     "assets":[{"id":"music","kind":"audio","name":"music","source":"music.wav","durationFrames":900}],
     "sequence":{"id":"seq","name":"Main","tracks":[{"id":"a1","kind":"audio","clips":[
       {"id":"a","assetId":"music","startFrame":30,"durationFrames":240,"sourceInFrame":60,"effects":[],"parameterTracks":[]}]}]}}
    """
    func make() throws -> (TimelineController, TimelineEditor) {
        let editor = try TimelineEditor(json: Self.json)
        let controller = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 20), editor: editor)
        controller.view.selection = ["a"]; controller.viewport = CanvasSize(1000, 300)
        controller.playback.seek(2)
        return (controller, editor)
    }
    func testA1BUsesAudioClockBetweenVideoTicksAndAddsOneUndoStep() throws {
        let (c, e) = try make()
        c.playback.play(); c.playback.externalClock = { 2.42 }
        XCTAssertTrue(c.keyDown(EditorKey(.char("b"))))
        XCTAssertEqual(e.clip("a")?.clip.beats?.frames, [103])
        XCTAssertEqual(c.view.beats.first?.time ?? 0, 2.42, accuracy: 1 / 30)
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertTrue(e.undo())
        XCTAssertNil(e.clip("a")?.clip.beats)
    }
    func testA2MovingAndTrimmingKeepMarksOnTheirSourceFrames() throws {
        let (c, e) = try make()
        XCTAssertTrue(c.addSelectedBeat())
        let address = try XCTUnwrap(e.address(clipId: "a"))
        XCTAssertTrue(e.apply(.move(address: address, destination: .init(trackId: "a1", startFrame: 90))))
        XCTAssertEqual(c.view.beats.map(\.time), [4])
        XCTAssertTrue(e.apply(.trimIn(address: address, startFrame: 105)))
        XCTAssertEqual(e.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(c.view.beats.map(\.time), [4])
        XCTAssertTrue(e.apply(.trimIn(address: address, startFrame: 135)))
        XCTAssertTrue(c.view.beats.isEmpty, "trim hides the mark but keeps the source frame")
        XCTAssertEqual(e.clip("a")?.clip.beats?.frames, [90])
    }
    func testA3ClipEdgeSnapsExactlyToBeat() throws {
        let (c, _) = try make(); XCTAssertTrue(c.addSelectedBeat())
        let targets = TimelineSnapping.targets(clips: [], playhead: 0, beats: c.view.beats.map(\.time))
        XCTAssertTrue(targets.contains { $0.time == 2 && $0.type == .beat })
        let target = TimelineSnapping.targets(clips: [], playhead: nil, beats: [61.0 / 30])[0]
        XCTAssertEqual(TimelineSnapping.snap(2.04, [target], thresholdSecs: 0.1).time, 61.0 / 30)
    }
    func testA4RoundTripAndLegacyByteIdentity() throws {
        let (c, e) = try make()
        let before = try serializeNativeProjectDocument(e.document)
        XCTAssertFalse(before.contains("\"beats\":"))
        XCTAssertEqual(before, try serializeNativeProjectDocument(try NativeJSONValue.parse(before)))
        XCTAssertTrue(c.addSelectedBeat())
        let saved = try serializeNativeProjectDocument(e.document)
        let reopened = try TimelineEditor(json: saved)
        XCTAssertEqual(reopened.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(saved, try serializeNativeProjectDocument(reopened.document))
    }
    func testDragDeleteAndJumpUseOneUndoStepEach() throws {
        let (c, e) = try make(); XCTAssertTrue(c.addSelectedBeat())
        let rect = c.view.clipRect(track: 0, c.view.tracks[0].clips[0])
        c.pointerDown(x: c.view.x(for: 2), y: rect.centerY)
        c.pointerMove(x: c.view.x(for: 3), y: rect.centerY)
        XCTAssertEqual(e.undoStack.count, 1, "no transient document writes")
        c.pointerUp(x: c.view.x(for: 3), y: rect.centerY)
        XCTAssertEqual(e.undoStack.count, 2)
        XCTAssertEqual(c.view.beats.map(\.time), [3])
        XCTAssertTrue(c.keyDown(EditorKey(.char("."), alt: true)))
        XCTAssertEqual(c.playback.currentTime, 3)
        c.pointerDown(x: c.view.x(for: 3), y: rect.centerY, alt: true)
        XCTAssertTrue(c.view.beats.isEmpty); XCTAssertEqual(e.undoStack.count, 3)
        XCTAssertTrue(e.undo()); XCTAssertEqual(c.view.beats.map(\.time), [3])
    }
    func testDuplicateAndLockedEditsAreRefused() throws {
        let (c, e) = try make(); XCTAssertTrue(c.addSelectedBeat()); XCTAssertFalse(c.addSelectedBeat())
        XCTAssertTrue(e.setTrackLocked("a1", true)); let count = e.undoStack.count
        XCTAssertFalse(e.editBeat(clipId: "a", sourceFrame: 90, to: nil))
        XCTAssertEqual(e.undoStack.count, count)
    }
    func testSpeedAndRampProjectMarksBackToTheSameSourceFrame() throws {
        let (_, e) = try make()
        var clip = try XCTUnwrap(e.clip("a")?.clip)
        clip.playbackRate = NativePlaybackRate(numerator: 1, denominator: 2)
        XCTAssertEqual(clip.beatSourceFrame(atTimelineFrame: 60), 75)
        XCTAssertEqual(clip.beatTimelineFrame(sourceFrame: 75), 60)
        clip.speedRamp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 60, speed: 2)])
        let source = clip.beatSourceFrame(atTimelineFrame: 60)
        XCTAssertEqual(source, 97.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clip.beatTimelineFrame(sourceFrame: source)), 60, accuracy: 1e-9)
    }
    func testFractionalSourceInNeverCreatesAnInvisibleRoundedMark() throws {
        let (_, e) = try make(); var d = e.document
        d.sequence.tracks[0].clips[0].sourceInFraction = NativePlaybackRate(numerator: 1, denominator: 4)
        let editor = TimelineEditor(document: try parseNativeProjectDocument(d))
        XCTAssertFalse(editor.addBeat(clipId: "a", at: 1), "source frame 60 is before source-in 60.25")
        XCTAssertTrue(editor.addBeat(clipId: "a", at: 2))
        XCTAssertEqual(editor.clip("a")?.clip.beats?.frames, [90])
        XCTAssertEqual(editor.tracks[0].clips[0].beatTimes[0], 1.9916666667, accuracy: 1e-9)
    }
    func testFutureVersionRetainsUnknownDataAndAddsOneOpenNotice() throws {
        let (_, e) = try make(); var raw = try NativeJSONValue.from(e.document)
        var sequence = raw["sequence"]!; var tracks = sequence["tracks"]!.arrayValue!
        var clips = tracks[0]["clips"]!.arrayValue!
        clips[0]["beats"] = .object(["v": .number(2), "kind": .string("future"), "payload": .array([.number(9)])])
        tracks[0]["clips"] = .array(clips); sequence["tracks"] = .array(tracks); raw["sequence"] = sequence
        let parsed = try parseNativeProjectDocument(raw)
        XCTAssertTrue(parsed.sequence.tracks[0].clips[0].visibleBeatFrames.isEmpty)
        XCTAssertEqual(parsed.undrawnContentNotices.count, 1)
        XCTAssertEqual(try NativeJSONValue.from(parsed)["sequence"]?["tracks"]?.arrayValue?[0]["clips"]?.arrayValue?[0]["beats"], clips[0]["beats"])
    }
    func testValidatorRejectsUnsortedDuplicateNegativeAndOutOfSourceMarks() throws {
        let (_, e) = try make()
        for frames in [[5.0, 4], [4, 4], [-1], [900], [0.5]] {
            var d = e.document; d.sequence.tracks[0].clips[0].beats = NativeClipBeats(frames: frames)
            XCTAssertFalse(validateNativeProjectDocument(try NativeJSONValue.from(d)).isEmpty)
        }
    }
}
