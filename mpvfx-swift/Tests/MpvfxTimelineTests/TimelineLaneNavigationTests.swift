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
import OneTakeKeyframes

/// Lane header ‹ ◆ › (PropertyGroupNavigation / getKeyframeNavigationState), track lock on property and crop
/// edits, the audio-group header FX hooks, and the beat-grid density gate.
final class TimelineLaneNavigationTests: XCTestCase {
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 400)
        return (c, e)
    }

    func testNavigationStateFollowsTheNavigationRules() {
        let s = TimelineKeyframeNavigation.state(frames: [30, 0, 60], currentFrame: 30)
        XCTAssertEqual(s, .init(prev: 0, current: 30, next: 60))
        XCTAssertEqual(TimelineKeyframeNavigation.state(frames: [0, 60], currentFrame: 45), .init(prev: 0, current: nil, next: 60))
        XCTAssertEqual(TimelineKeyframeNavigation.state(frames: [10], currentFrame: 10), .init(prev: nil, current: 10, next: nil))
        XCTAssertEqual(TimelineKeyframeNavigation.state(frames: [], currentFrame: 3), .init())
    }

    func testLaneArrowsSeekAndDiamondToggles() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 0))
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 2))
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 4))
        XCTAssertFalse(c.view.expandedClips.contains("clip:a"), "#201: starts with its summary row, not one row per property")
        let lane = c.view.tracks[1].clips[0].lanes.firstIndex { $0.group == "position" }!

        c.playback.seek(3)
        XCTAssertEqual(c.laneNavigation(clipId: "clip:a", lane: lane), .init(prev: 60, current: nil, next: 120))
        XCTAssertTrue(c.laneControlClick(clipId: "clip:a", lane: lane, control: .next))
        XCTAssertEqual(c.playback.currentTime, 4, accuracy: 1e-9)
        XCTAssertEqual(c.laneNavigation(clipId: "clip:a", lane: lane).current, 120)
        XCTAssertFalse(c.laneControlClick(clipId: "clip:a", lane: lane, control: .next), "no next keyframe")
        XCTAssertTrue(c.laneControlClick(clipId: "clip:a", lane: lane, control: .prev))
        XCTAssertEqual(c.playback.currentTime, 2, accuracy: 1e-9)

        // ◆ at a keyframe removes it; ◇ elsewhere keys the group at its current value.
        XCTAssertTrue(c.laneControlClick(clipId: "clip:a", lane: lane, control: .toggle))
        XCTAssertFalse(e.positionKeyframeActive(clipId: "clip:a", time: 2))
        XCTAssertEqual(e.undoLabel, "Edit property")
        XCTAssertTrue(c.laneControlClick(clipId: "clip:a", lane: lane, control: .toggle))
        XCTAssertTrue(e.positionKeyframeActive(clipId: "clip:a", time: 2))

        // Clicks land through the drawn header: the ‹ glyph on the first lane row.
        c.playback.seek(3); c.syncFromPlayback()
        let laneTop = try XCTUnwrap(c.view.laneHit(track: 1, y: c.view.rowTop(1) + c.view.trackHeight + 1)).laneTop
        let prev = TimelineView.laneControlRects(laneTop: laneTop)[0].1
        c.pointerDown(x: prev.centerX, y: prev.centerY); c.pointerUp(x: prev.centerX, y: prev.centerY)
        XCTAssertEqual(c.playback.currentTime, 2, accuracy: 1e-9)

        // Locked track: the arrows still navigate, the diamond does nothing.
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        XCTAssertFalse(c.laneControlClick(clipId: "clip:a", lane: lane, control: .toggle))
        XCTAssertTrue(c.laneControlClick(clipId: "clip:a", lane: lane, control: .next))
    }

    func testLockedTrackRefusesPropertyAndCropEdits() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        XCTAssertFalse(e.applyTransform(clipId: "clip:a", time: 1, ClipTransform(x: 10, y: 20)))
        XCTAssertEqual(e.lastPropertyFailure?.message, "Track is locked")
        XCTAssertFalse(e.togglePositionKeyframe(clipId: "clip:a", time: 1))
        XCTAssertFalse(e.setCrop(clipId: "clip:a", NativeClipCrop(top: 0.1, right: 0, bottom: 0, left: 0)))
        XCTAssertNil(e.crop(clipId: "clip:a"))
        XCTAssertTrue(e.setTrackLocked("track:v1", false))
        XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 1, ClipTransform(x: 10, y: 20)))
        XCTAssertTrue(e.setCrop(clipId: "clip:a", NativeClipCrop(top: 0.1, right: 0, bottom: 0, left: 0)))
    }

    func testGroupHeaderFxCountAndHooks() throws {
        let (c, e) = try make()
        let gid = try XCTUnwrap(e.createAudioGroup(clipIds: ["clip:a", "clip:b", "clip:music"], label: "Bus"))
        XCTAssertTrue(e.setAudioGroupFxChain(gid, #"{"nodes":[{"type":"eq"},{"type":"comp","enabled":false},{"type":"reverb"}]}"#))
        let g = try XCTUnwrap(c.view.groups.first { $0.id == gid })
        XCTAssertEqual(g.fxCount, 2, "enabled nodes only")
        var opened: (String, CanvasRect)?, rack: String?
        c.onOpenGroupFx = { opened = ($0, $1) }
        c.onOpenGroupFxRack = { rack = $0 }
        let top = try XCTUnwrap(c.view.groupHeaderTop(gid))
        let fx = c.view.groupFxRect(g, top: top)
        c.pointerDown(x: fx.centerX, y: fx.centerY); c.pointerUp(x: fx.centerX, y: fx.centerY)
        XCTAssertEqual(opened?.0, gid); XCTAssertEqual(opened?.1, fx)
        XCTAssertEqual(c.lastHeaderAction, .openedGroupFx(groupId: gid))
        let name = c.view.groupNameRect(top: top)
        c.pointerDown(x: name.x + 30, y: name.centerY); c.pointerUp(x: name.x + 30, y: name.centerY)
        XCTAssertEqual(rack, gid)
        let r = RecordingCanvas(); c.view.draw(r, size: CanvasSize(1266, 400))
        XCTAssertTrue(r.texts.contains("FX 2"))
    }

    func testLaneHeaderDrawsArrowsAndDiamondState() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 1))
        c.playback.seek(1); c.syncFromPlayback()
        // The summary row's ◆ is the accent mark (every kind); filled on a key, outlined elsewhere.
        let top = try XCTUnwrap(c.view.laneHit(track: 1, y: c.view.rowTop(1) + c.view.trackHeight + 1)).laneTop
        let toggle = try XCTUnwrap(TimelineView.laneControlRects(laneTop: top).first { $0.0 == .toggle }).1
        var r = RecordingCanvas(); c.view.draw(r, size: CanvasSize(1266, 400))
        XCTAssertTrue(r.texts.contains("‹")); XCTAssertTrue(r.texts.contains("›"))
        XCTAssertTrue(r.painted(c.view.theme.accent, at: CanvasPoint(toggle.centerX, toggle.centerY)), "filled on a keyframe")
        c.playback.seek(3); c.syncFromPlayback()
        r = RecordingCanvas(); c.view.draw(r, size: CanvasSize(1266, 400))
        XCTAssertFalse(r.painted(c.view.theme.accent, at: CanvasPoint(toggle.centerX, toggle.centerY)))
        XCTAssertTrue(r.painted(c.view.theme.accent, at: CanvasPoint(toggle.centerX, toggle.centerY), stroke: true), "hollow away from a keyframe")
    }
}
