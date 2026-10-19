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
import MpvfxCanvas
import MpvfxShared

/// Track headers: names (TimelineLanes trackLabel), FX count (TimelineFxButton), and header click routing.
final class TimelineHeaderTests: XCTestCase {
    // demoJSON display order: v2 [logo], v1 [a, b], a1 [music].
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(percent: 600)
        return (c, e)
    }
    func centre(_ c: TimelineController, row: Int, _ control: TimelineHeaderControl) -> (Double, Double)? {
        c.view.headerControls(row: row).first { $0.control == control }.map { ($0.rect.centerX, $0.rect.centerY) }
    }

    func testEnabledFxNodeCountParsesLightly() {
        XCTAssertEqual(TimelineEditor.enabledFxNodeCount(nil), 0)
        XCTAssertEqual(TimelineEditor.enabledFxNodeCount("not json"), 0)
        XCTAssertEqual(TimelineEditor.enabledFxNodeCount(#"{"version":1,"nodes":[]}"#), 0)
        XCTAssertEqual(TimelineEditor.enabledFxNodeCount(#"{"version":1,"nodes":[{"id":"a","type":"eq"},{"id":"b","type":"comp","enabled":false},{"id":"c","type":"gate","enabled":true}]}"#), 2)
    }

    func testTracksAreNamedAfterTheirFirstClipElseTrackN() throws {
        let (c, e) = try make()
        XCTAssertEqual(e.tracks.map(\.name), ["logo.png", "clip_001.mp4", "music.wav"])
        XCTAssertNotNil(e.addTrack(kind: .audio))
        XCTAssertEqual(e.tracks.last?.name, "Track 4", "empty track: 1-based display position")
        XCTAssertEqual(c.view.tracks.map(\.name).last, "Track 4")
    }

    func testFxButtonShowsEnabledNodeCountAndOpensThePanel() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setClipFxChain(clipId: "clip:music", #"{"version":1,"nodes":[{"id":"n1","type":"eq"},{"id":"n2","type":"comp","enabled":false}]}"#))
        XCTAssertEqual(c.view.tracks[2].clips[0].fxCount, 1)
        var opened: String?
        c.onOpenClipFx = { id, rect in opened = id; XCTAssertGreaterThan(rect.width, 0) }
        guard let (x, y) = centre(c, row: 2, .fx(clipId: "clip:music")) else { return XCTFail("no FX button on a single-audio-clip track") }
        XCTAssertEqual(c.hitTest(x: x, y: y), .header(row: 2))
        c.pointerDown(x: x, y: y)
        XCTAssertEqual(opened, "clip:music")
        XCTAssertEqual(c.view.selection, ["clip:music"])
        XCTAssertEqual(c.lastHeaderAction, .openedFx(clipId: "clip:music"))
        // Video rows carry no FX button.
        XCTAssertFalse(c.view.headerControls(row: 1).contains { if case .fx = $0.control { return true }; return false })
    }

    func testEyeHidesVideoTracksAndSpeakerMutesAudioTracks() throws {
        let (c, e) = try make()
        guard let (ex, ey) = centre(c, row: 1, .visibility), let (sx, sy) = centre(c, row: 2, .visibility) else { return XCTFail() }
        c.pointerDown(x: ex, y: ey); c.pointerUp(x: ex, y: ey)
        XCTAssertEqual(e.document.sequence.tracks.first { $0.id == "track:v1" }?.hidden, true)
        XCTAssertEqual(c.lastHeaderAction, .toggledHidden(row: 1))
        c.pointerDown(x: sx, y: sy); c.pointerUp(x: sx, y: sy)
        XCTAssertTrue(e.isTrackMuted("track:a1"))
        XCTAssertEqual(c.lastHeaderAction, .toggledMuted(row: 2))
        XCTAssertNil(e.document.sequence.tracks.first { $0.id == "track:a1" }?.hidden, "speaker mutes, it doesn't hide")
        c.pointerDown(x: sx, y: sy); c.pointerUp(x: sx, y: sy)
        XCTAssertFalse(e.isTrackMuted("track:a1"))
    }

    func testEyeOnAnEmptyTrackDoesNothing() throws {
        let (c, e) = try make()
        XCTAssertNotNil(e.addTrack(kind: .video))
        guard let (x, y) = centre(c, row: 3, .visibility) else { return XCTFail("spacer keeps the column") }
        XCTAssertNil(c.headerClick(x: x, y: y, row: 3))
        XCTAssertNil(e.document.sequence.tracks.first { $0.id == c.view.tracks[3].id }?.hidden)
    }

    func testGroupPointerGroupsTheWholeTrack() throws {
        let (c, e) = try make()
        XCTAssertNotNil(e.insertClip(assetId: "asset:music", at: 12, trackId: "track:a1", durationFrames: 30))
        XCTAssertEqual(c.view.tracks[2].clips.count, 2)
        guard let (x, y) = centre(c, row: 2, .groupPointer) else { return XCTFail("several ungrouped audio clips get the group pointer") }
        // With a name dialog wired, the click only asks.
        var asked: (Int, String)?
        c.onRequestGroupName = { asked = ($0, $1) }
        c.pointerDown(x: x, y: y)
        XCTAssertEqual(asked?.0, 2); XCTAssertEqual(asked?.1, "music.wav")
        XCTAssertNil(e.document.sequence.audioGroups)
        XCTAssertEqual(c.view.selection.count, 2)
        XCTAssertNotNil(c.groupSelectedAudio(label: "Voiceover"))
        XCTAssertEqual(e.document.sequence.audioGroups?.first?.label, "Voiceover")
        XCTAssertNil(c.view.headerControls(row: c.view.tracks.firstIndex { $0.id == "track:a1" }!).first { $0.control == .groupPointer },
                     "a grouped track loses the pointer")
    }

    func testGroupPointerWithoutDialogGroupsUnderTheTrackName() throws {
        let (c, e) = try make()
        XCTAssertNotNil(e.insertClip(assetId: "asset:music", at: 12, trackId: "track:a1", durationFrames: 30))
        guard let (x, y) = centre(c, row: 2, .groupPointer) else { return XCTFail() }
        c.pointerDown(x: x, y: y)
        XCTAssertEqual(e.document.sequence.audioGroups?.first?.label, "music.wav")
    }
}
