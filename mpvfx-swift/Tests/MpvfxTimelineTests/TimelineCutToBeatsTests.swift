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
import OneTakeKeyframes
import XCTest

@testable import MpvfxTimeline

/// Cut to beats (#291, ⇧⌘B): the selected clips laid end to end with every cut on a beat mark of the music under them.
internal final class TimelineCutToBeatsTests: XCTestCase {
    /// A video track of clips `(id, start, duration)` over a 30 fps music clip from frame 0 with a mark every 15 frames
    /// (every 0.5 s) in its source, plus whatever else `extra` adds.
    private func project(clips: [(String, Double, Double)], marks: [Double]? = nil, musicStart: Double = 0,
                         locked: Bool = false, extraTrack: String = "") -> String {
        let beats = marks ?? Array(stride(from: 15.0, through: 885.0, by: 15.0))
        let list = clips.map { id, start, duration in
            #"{"id":"\#(id)","name":"\#(id)","assetId":"video","startFrame":\#(Int(start)),"durationFrames":\#(Int(duration)),"sourceInFrame":0,"effects":[],"parameterTracks":[]}"#
        }.joined(separator: ",")
        let marksJSON = beats.isEmpty ? "" : #","beats":{"v":1,"frames":[\#(beats.map { String(Int($0)) }.joined(separator: ","))]}"#
        return """
        {"schemaVersion":1,"mediaEngine":"native","id":"cut","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"video","kind":"video","name":"video","source":"v.mp4","durationFrames":900},
                   {"id":"music","kind":"audio","name":"music","source":"m.wav","durationFrames":900}],
         "sequence":{"id":"seq","name":"Main","tracks":[
           {"id":"v1","kind":"video"\(locked ? #","locked":true"# : ""),"clips":[\(list)]},\(extraTrack)
           {"id":"a1","kind":"audio","clips":[
             {"id":"m","assetId":"music","startFrame":\(Int(musicStart)),"durationFrames":900,"sourceInFrame":0,"effects":[],"parameterTracks":[]\(marksJSON)}]}]}}
        """
    }

    private func make(_ json: String, selecting: Set<String>) throws -> (TimelineController, TimelineEditor) {
        let editor = try TimelineEditor(json: json, engine: KeyframeRuntime())
        let controller = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 30), editor: editor)
        controller.viewport = CanvasSize(1_000, 300)
        controller.view.selection = selecting
        return (controller, editor)
    }

    private func layout(_ e: TimelineEditor, _ ids: [String]) -> [[Double]] {
        let all = e.document.sequence.tracks.flatMap(\.clips)
        return ids.compactMap { id in all.first { $0.id == id }.map { [$0.startFrame, $0.durationFrames] } }
    }

    private static let five: [(String, Double, Double)] = [("c1", 0, 90), ("c2", 100, 90), ("c3", 200, 90), ("c4", 300, 90), ("c5", 400, 90)]
    private static let ids = ["c1", "c2", "c3", "c4", "c5"]

    // A1
    internal func testFiveThreeSecondClipsOverHalfSecondMarksEachCutLandsOnAMark() throws {
        let (_, e) = try make(project(clips: Self.five), selecting: Set(Self.ids))
        let plan = try XCTUnwrap(e.cutToBeats(clipIds: Set(Self.ids)))
        XCTAssertEqual(layout(e, Self.ids), [[0, 90], [90, 90], [180, 90], [270, 90], [360, 90]])
        XCTAssertTrue(plan.items.allSatisfy(\.onBeat))
        let marks = Set(stride(from: 15.0, through: 885.0, by: 15.0))
        for item in plan.items { XCTAssertTrue(marks.contains(item.startFrame + item.durationFrames), "\(item.clipId) ends on a mark") }
        XCTAssertLessThanOrEqual(plan.items.map(\.durationFrames).reduce(0, +), Self.five.map(\.2).reduce(0, +), "never longer than the clips were")
    }

    internal func testAnOffBeatStartTrimsTheFirstClipToTheLastMarkInsideIt() throws {
        let clips: [(String, Double, Double)] = [("c1", 7, 90), ("c2", 120, 90)]
        let (_, e) = try make(project(clips: clips), selecting: ["c1", "c2"])
        XCTAssertNotNil(e.cutToBeats(clipIds: ["c1", "c2"]))
        XCTAssertEqual(layout(e, ["c1", "c2"]), [[7, 83], [90, 90]], "the first cut is on the mark at 90; the clip is trimmed at its out point")
    }

    // A2
    internal func testAClipShorterThanTheNextBeatKeepsItsLengthAndTheToastNamesIt() throws {
        let clips: [(String, Double, Double)] = [("c1", 0, 90), ("Short", 100, 10), ("c3", 120, 90)]
        let (_, e) = try make(project(clips: clips), selecting: ["c1", "Short", "c3"])
        var notices: [String] = []
        e.onNotice = { notices.append($0) }
        let plan = try XCTUnwrap(e.cutToBeats(clipIds: ["c1", "Short", "c3"]))
        XCTAssertEqual(layout(e, ["c1", "Short", "c3"]), [[0, 90], [90, 10], [100, 80]], "Short keeps its 10 frames, the next cut is back on a mark at 180")
        XCTAssertEqual(plan.keptLength, ["Short"])
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("Short"), notices[0])
    }

    // A3
    internal func testOneUndoStepRestoresPositionsAndTrims() throws {
        let (_, e) = try make(project(clips: Self.five), selecting: Set(Self.ids))
        let before = e.document
        XCTAssertNotNil(e.cutToBeats(clipIds: Set(Self.ids)))
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Cut to beats")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(layout(e, Self.ids), Self.five.map { [$0.1, $0.2] })
        XCTAssertTrue(e.redo())
        XCTAssertEqual(layout(e, Self.ids), [[0, 90], [90, 90], [180, 90], [270, 90], [360, 90]])
    }

    internal func testTrimmedClipsKeepTheirMediaAndNeverGrow() throws {
        let clips: [(String, Double, Double)] = [("c1", 7, 90), ("c2", 120, 100)]
        let (_, e) = try make(project(clips: clips), selecting: ["c1", "c2"])
        XCTAssertNotNil(e.cutToBeats(clipIds: ["c1", "c2"]))
        for clip in e.document.sequence.tracks[0].clips { XCTAssertEqual(clip.sourceInFrame, 0, "\(clip.id): only the out point moved") }
        XCTAssertLessThanOrEqual(layout(e, ["c2"])[0][1], 100)
    }

    // A4
    internal func testWithNoMusicUnderTheSelectionTheCommandIsDisabledWithAReason() throws {
        let (c, e) = try make(project(clips: Self.five, marks: []), selecting: Set(Self.ids))
        let before = e.document
        XCTAssertEqual(c.cutToBeatsRefusal, "No music clip with beat marks under the selected clips")
        var refused: [String] = []
        c.onEditRefused = { refused.append($0) }
        XCTAssertFalse(c.keyDown(EditorKey(.char("b"), shift: true, meta: true)))
        XCTAssertEqual(refused, ["No music clip with beat marks under the selected clips"])
        XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.undoStack.isEmpty)
        c.openClipMenu("c1", x: 10, y: 10)
        let row = c.view.clipMenu?.entries.compactMap { entry -> TimelineClipMenu.Item? in
            if case .item(let i) = entry, i.action == .cutToBeats { return i }; return nil
        }.first
        XCTAssertEqual(row?.enabled, false)
        XCTAssertEqual(row?.hint, "No music clip with beat marks under the selected clips", "the menu row says why")
    }

    internal func testMarksOutsideTheSelectedSpanDoNotCount() throws {
        let clips: [(String, Double, Double)] = [("c1", 0, 60)]
        let (_, e) = try make(project(clips: clips, marks: [600, 615]), selecting: ["c1"])
        XCTAssertEqual(e.beatCutRefusal(clipIds: ["c1"]), "No music clip with beat marks under the selected clips")
    }

    internal func testASelectedMusicClipIsNotItsOwnGrid() throws {
        let (_, e) = try make(project(clips: Self.five), selecting: ["c1", "m"])
        XCTAssertEqual(e.beatCutRefusal(clipIds: ["c1", "m"]), "Select clips on one track to cut them to the beat")
        XCTAssertEqual(e.beatCutRefusal(clipIds: []), "Select the clips to cut to the beat")
    }

    internal func testTheShortcutRunsTheCutAndSelectsNothingElse() throws {
        let (c, e) = try make(project(clips: Self.five), selecting: Set(Self.ids))
        XCTAssertNil(c.cutToBeatsRefusal)
        XCTAssertTrue(c.keyDown(EditorKey(.char("B"), shift: true, meta: true)))
        XCTAssertEqual(layout(e, Self.ids)[4], [360, 90])
        XCTAssertEqual(c.view.selection, Set(Self.ids))
        XCTAssertFalse(c.keyDown(EditorKey(.char("b"), shift: true, alt: true, meta: true)), "⌥⇧⌘B is not the command")
    }

    internal func testALockedTrackAndAClipInTheWayRefuseTheCut() throws {
        let (_, locked) = try make(project(clips: Self.five, locked: true), selecting: Set(Self.ids))
        XCTAssertEqual(locked.beatCutRefusal(clipIds: Set(Self.ids)), "Track is locked")
        let clips: [(String, Double, Double)] = [("c1", 0, 60), ("x", 70, 20), ("c3", 100, 90)]
        let (_, e) = try make(project(clips: clips), selecting: ["c1", "c3"])
        let before = e.document
        XCTAssertNil(e.cutToBeats(clipIds: ["c1", "c3"]))
        XCTAssertEqual(e.lastFailure?.message, "A clip between the selected clips is in the way")
        XCTAssertEqual(e.document, before)
    }

    internal func testClipsAlreadyOnTheBeatsAreLeftAlone() throws {
        let clips: [(String, Double, Double)] = [("c1", 0, 90), ("c2", 90, 90)]
        let (_, e) = try make(project(clips: clips), selecting: ["c1", "c2"])
        XCTAssertNil(e.cutToBeats(clipIds: ["c1", "c2"]))
        XCTAssertEqual(e.lastFailure?.message, "The clips already cut on the beats")
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    internal func testTheMarksFollowTheMusicClipWhereItSits() throws {
        // The music starts at frame 10: its marks fall at 25, 40, ... so the cut after a 90 frame clip from 0 is at 85.
        let clips: [(String, Double, Double)] = [("c1", 0, 90)]
        let (_, e) = try make(project(clips: clips, musicStart: 10), selecting: ["c1"])
        XCTAssertNotNil(e.cutToBeats(clipIds: ["c1"]))
        XCTAssertEqual(layout(e, ["c1"]), [[0, 85]])
    }
}
