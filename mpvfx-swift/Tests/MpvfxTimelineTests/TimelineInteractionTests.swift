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
@testable import MpvfxTimeline
import MpvfxCanvas

final class TimelineZoomTests: XCTestCase {
    func testFitAndClamp() {
        XCTAssertEqual(TimelineZoom.fitPixelsPerSecond(viewportWidth: 1266, duration: 10, contentOrigin: 264), 1000.0 / 60)  // min extent 60s
        XCTAssertEqual(TimelineZoom.fitPixelsPerSecond(viewportWidth: 200, duration: 10, contentOrigin: 264), 100)
        XCTAssertEqual(TimelineZoom.maxPercent(fit: 10), 14400)
        XCTAssertEqual(TimelineZoom.clamp(3, fit: 10), 10)
        XCTAssertEqual(TimelineZoom.next(true, mode: .fit, manual: 500, fit: 10), 200)
        XCTAssertEqual(TimelineZoom.next(false, mode: .manual, manual: 15, fit: 10), 10)
        XCTAssertEqual(TimelineZoom.pinch(deltaY: 0, mode: .manual, manual: 300, fit: 10), 300)
        XCTAssertEqual(TimelineZoom.pinch(deltaY: -50, mode: .manual, manual: 100, fit: 10), (100 * exp(0.7)).rounded())
    }
    func testSnapping() {
        let t = TimelineSnapping.targets(clips: [("a", 0, 2), ("b", 2, 1)], playhead: 2, beats: [1], excluding: ["b"])
        XCTAssertEqual(t, [.init(time: 0, type: .clipEdge), .init(time: 1, type: .beat), .init(time: 2, type: .playhead)])
        XCTAssertEqual(TimelineSnapping.snap(1.05, t, thresholdSecs: 0.08).time, 1)
        XCTAssertNil(TimelineSnapping.snap(1.5, t, thresholdSecs: 0.08).target)
        let m = TimelineSnapping.snapMove(start: 0.97, duration: 3, t, pps: 100, timelineDuration: 100)
        XCTAssertEqual(m.start, 1); XCTAssertEqual(m.snap?.type, .beat)
        let clamped = TimelineSnapping.snapMove(start: 0.05, duration: 3, [.init(time: 0.02, type: .beat)], pps: 100, timelineDuration: 100)
        XCTAssertEqual(clamped.start, 0.02)
    }
}

final class PlaybackTests: XCTestCase {
    func testKeysAndTick() {
        let p = PlaybackState(duration: 10, fps: 30)
        p.keyDown(EditorKey(.right)); XCTAssertEqual(p.currentTime, 1.0 / 30, accuracy: 1e-9)
        p.keyDown(EditorKey(.right, shift: true)); XCTAssertEqual(p.currentTime, 11.0 / 30, accuracy: 1e-9)
        p.keyDown(EditorKey(.left, shift: true)); p.keyDown(EditorKey(.left, shift: true)); XCTAssertEqual(p.currentTime, 0)
        XCTAssertFalse(p.keyDown(EditorKey(.space, ctrl: true)), "modifier chords are ignored")
        p.keyDown(EditorKey(.space)); XCTAssertTrue(p.isPlaying)
        p.tick(0.5); XCTAssertEqual(p.currentTime, 0.5, accuracy: 1e-9)
        p.keyDown(EditorKey(.char("l"))); p.keyUp(EditorKey(.char("l"))); p.keyDown(EditorKey(.char("l")))
        XCTAssertEqual(p.playbackRate, 2)
        p.keyDown(EditorKey(.char("j"))); XCTAssertEqual(p.playbackRate, 1); XCTAssertEqual(p.direction, -1)
        p.tick(1); XCTAssertEqual(p.currentTime, 0); XCTAssertFalse(p.isPlaying)
        p.keyDown(EditorKey(.char("k"))); p.keyDown(EditorKey(.char("l"))); XCTAssertEqual(p.currentTime, 1.0 / 30, accuracy: 1e-9, "K held + L steps a frame")
        p.keyUp(EditorKey(.char("k"))); p.keyUp(EditorKey(.char("l")))
        p.seek(2); p.keyDown(EditorKey(.char("i"))); p.seek(4); p.keyDown(EditorKey(.char("o")))
        XCTAssertTrue(p.loopEnabled, "setting in/out turns loop on (playerStore setInPoint/setOutPoint)")
        p.keyDown(EditorKey(.char("L"), shift: true)); XCTAssertFalse(p.loopEnabled)
        p.keyDown(EditorKey(.char("L"), shift: true)); XCTAssertTrue(p.loopEnabled)
        p.keyDown(EditorKey(.char("a"))); XCTAssertEqual(p.currentTime, 2)
        p.play(); p.tick(1.5); XCTAssertEqual(p.currentTime, 3.5, accuracy: 1e-9)
        p.tick(1); XCTAssertEqual(p.currentTime, 2, "loops inside in/out: wraps exactly to the in point at the out point")
        XCTAssertTrue(p.isPlaying)
        p.keyDown(EditorKey(.char("m"))); XCTAssertTrue(p.audioMuted)
        p.keyDown(EditorKey(.char("I"), shift: true)); XCTAssertNil(p.inPoint)
        p.keyDown(EditorKey(.char("e"))); XCTAssertEqual(p.currentTime, 4)
    }
}

final class TimelineControllerTests: XCTestCase {
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300)   // fit = (1266 - 264 - 2) / 60 px/s
        c.setZoom(percent: 600)              // 100 px/s
        return (c, e)
    }
    func clip(_ e: TimelineEditor, _ id: String) -> (track: String, start: Double, dur: Double)? {
        for t in e.document.sequence.tracks { if let c = t.clips.first(where: { $0.id == id }) { return (t.id, c.startFrame, c.durationFrames) } }
        return nil
    }

    func testModelFromDocument() throws {
        let (c, e) = try make()
        XCTAssertEqual(c.view.tracks.map(\.id), ["track:v2", "track:v1", "track:a1"], "displayTrack order")
        XCTAssertEqual(e.duration, 11)
        XCTAssertEqual(c.view.pixelsPerSecond, 100, accuracy: 1e-9)
        XCTAssertEqual(TimelineView.originGapColor(c.view.tracks[0].clips, theme: .default), CanvasColor(hex: "#3B82F6"))
        XCTAssertEqual(TimelineView.originGapColor(c.view.tracks[1].clips, theme: .default), CanvasColor(hex: "#FF5353"))
    }

    func testHitTestAndScrub() throws {
        let (c, _) = try make()
        let rowY = TimelineLayout.rowTop(1) + 20
        XCTAssertEqual(c.hitTest(x: 264 + 100, y: rowY), .clip(id: "clip:a", row: 1, edge: nil))
        XCTAssertEqual(c.hitTest(x: 264 + 5, y: rowY), .clip(id: "clip:a", row: 1, edge: .start))
        XCTAssertEqual(c.hitTest(x: 264 + 595, y: rowY), .clip(id: "clip:a", row: 1, edge: .end))
        XCTAssertEqual(c.hitTest(x: 264 + 610, y: rowY), .empty(row: 1))
        XCTAssertEqual(c.hitTest(x: 100, y: rowY), .header(row: 1))
        c.pointerDown(x: 264 + 250, y: 10); XCTAssertTrue(c.view.scrubbing)
        c.pointerMove(x: 264 + 300, y: 10); XCTAssertEqual(c.playback.currentTime, 3, accuracy: 1e-9)
        c.pointerUp(x: 264 + 300, y: 10); XCTAssertFalse(c.view.scrubbing)
    }

    func testSelectMoveAcrossTrackAndUndo() throws {
        let (c, e) = try make()
        let y1 = TimelineLayout.rowTop(1) + 20
        c.pointerDown(x: 264 + 700, y: y1)            // clip:b body (starts 6.5s)
        XCTAssertEqual(c.view.selection, ["clip:b"])
        c.pointerMove(x: 264 + 700 + 1, y: y1)          // under threshold: no drag
        XCTAssertNil(c.view.drag)
        c.pointerMove(x: 264 + 900, y: y1)            // +2s
        c.pointerUp(x: 264 + 900, y: y1)
        XCTAssertEqual(clip(e, "clip:b")?.start, 255)  // (6.5+2)*30
        XCTAssertTrue(e.undo()); XCTAssertEqual(clip(e, "clip:b")?.start, 195)
        XCTAssertTrue(e.redo()); XCTAssertEqual(clip(e, "clip:b")?.start, 255)
    }

    func testMoveSnapsToClipEdge() throws {
        let (c, e) = try make()
        let y1 = TimelineLayout.rowTop(1) + 20
        c.pointerDown(x: 264 + 700, y: y1)
        c.pointerMove(x: 264 + 700 - 47, y: y1)       // 6.03s, within 8px of clip:a end (6.0)
        if case .move(_, _, _, let snap)? = c.view.drag { XCTAssertEqual(snap, 6) } else { XCTFail("no drag") }
        c.pointerUp(x: 0, y: y1)
        XCTAssertEqual(clip(e, "clip:b")?.start, 180)
    }

    func testTrimEndAndStart() throws {
        let (c, e) = try make()
        let y1 = TimelineLayout.rowTop(1) + 20
        c.pointerDown(x: 264 + 597, y: y1)            // clip:a end handle
        c.pointerMove(x: 264 + 450, y: y1); c.pointerUp(x: 264 + 450, y: y1)
        XCTAssertEqual(clip(e, "clip:a")?.dur, 135)
        c.pointerDown(x: 264 + 3, y: y1)
        c.pointerMove(x: 264 + 100, y: y1); c.pointerUp(x: 264 + 100, y: y1)
        XCTAssertEqual(clip(e, "clip:a")?.start, 30); XCTAssertEqual(clip(e, "clip:a")?.dur, 105)
    }

    func testKeyboardDeleteSplitZoom() throws {
        let (c, e) = try make()
        c.playback.seek(2)
        c.view.selection = ["clip:a"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("s"))))
        XCTAssertEqual(e.document.sequence.tracks.first { $0.id == "track:v1" }?.clips.count, 3)
        c.view.selection = ["clip:music"]
        XCTAssertTrue(c.keyDown(EditorKey(.delete)))
        XCTAssertNil(clip(e, "clip:music")); XCTAssertTrue(c.view.selection.isEmpty)
        XCTAssertTrue(c.keyDown(EditorKey(.char("z"), ctrl: true))); XCTAssertNotNil(clip(e, "clip:music"))
        let pps = c.view.pixelsPerSecond
        c.keyDown(EditorKey(.char("="), ctrl: true)); XCTAssertEqual(c.view.pixelsPerSecond, pps * 2, accuracy: 1e-6)
        c.keyDown(EditorKey(.char("0"), ctrl: true)); XCTAssertEqual(c.zoomMode, .fit)
        XCTAssertTrue(c.keyDown(EditorKey(.space))); XCTAssertTrue(c.playback.isPlaying, "playback keys fall through")
    }

    func testWheelZoomKeepsAnchorAndScrolls() throws {
        let (c, _) = try make()
        let ax = 264.0 + 400
        let before = c.view.time(forX: ax)
        c.scroll(dx: 0, dy: -50, x: ax, ctrl: true, shift: false)
        XCTAssertEqual(c.view.time(forX: ax), before, accuracy: 0.02)
        c.scroll(dx: 0, dy: 120, x: 0, ctrl: false, shift: true)
        XCTAssertGreaterThan(c.view.scrollX, 0)
    }
}

#if os(Linux)
final class TimelineVisualTests: XCTestCase {
    func testHandlesSquareCornerPreRollAndBeats() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(percent: 600)
        c.view.selection = ["clip:b"]
        c.view.beats = [TimelineBeat(time: 8.5, strength: 1), TimelineBeat(time: 9.5, strength: 1)]   // showBeats needs two
        let t = CairoImageTarget(width: 1264, height: 300)
        c.view.draw(t.canvas, size: CanvasSize(1264, 300))
        let rowA = Int(TimelineLayout.rowTop(1))
        func rgb(_ x: Int, _ y: Int) -> [Int] { let p = t.pixel(x, y); return [Int(p.r), Int(p.g), Int(p.b)] }
        XCTAssertEqual(rgb(240, rowA + 20), [255, 83, 83], "video pre-roll #FF5353")
        XCTAssertNotEqual(rgb(264, rowA + 3), [29, 29, 29], "clip at t=0 has a square top-left corner")
        let row0 = Int(TimelineLayout.rowTop(0))
        let squareCorner = rgb(264, rowA + 3), roundCorner = rgb(264 + 50, row0 + 3)   // unselected logo clip at 0.5s
        XCTAssertLessThan(roundCorner[0], squareCorner[0], "clip away from t=0 has an antialiased rounded corner")
        // Selected clip:b: handle bar at left+4..6, top+6.
        let bar = rgb(264 + 650 + 4, rowA + 3 + 20), body = rgb(264 + 650 + 20, rowA + 3 + 20)
        XCTAssertGreaterThan(bar[0], body[0], "trim handle bar visible on the selected clip")
        let beat = rgb(264 + 950, 280); XCTAssertGreaterThan(beat[1], beat[0] + 50, "beat line is green")
    }
}
#endif

final class KeyframeKeyTests: XCTestCase {
    func testKTogglesPositionKeyframeWhenStageSelected() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = e.tracks.flatMap(\.clips).first { $0.kind != .audio }!
        let k = EditorKey(.char("k"))
        XCTAssertFalse(KeyframeKeyboard.handle(k, editor: e, stageSelection: nil, kind: nil, time: c.start), "no selection -> playback pause")
        XCTAssertFalse(KeyframeKeyboard.handle(k, editor: e, stageSelection: c.id, kind: .audio, time: c.start), "audio not keyframeable")
        XCTAssertFalse(KeyframeKeyboard.handle(EditorKey(.char("k"), ctrl: true), editor: e, stageSelection: c.id, kind: c.kind, time: c.start))
        XCTAssertTrue(KeyframeKeyboard.handle(k, editor: e, stageSelection: c.id, kind: c.kind, time: c.start), "\(String(describing: e.lastPropertyFailure))")
        XCTAssertTrue(e.positionKeyframeActive(clipId: c.id, time: c.start))
        XCTAssertTrue(KeyframeKeyboard.handle(k, editor: e, stageSelection: c.id, kind: c.kind, time: c.start))
        XCTAssertFalse(e.positionKeyframeActive(clipId: c.id, time: c.start))
        XCTAssertTrue(e.undo()); XCTAssertTrue(e.positionKeyframeActive(clipId: c.id, time: c.start))
    }

    func testKPausesInPlaybackContext() {
        let p = PlaybackState(duration: 10); p.play()
        XCTAssertTrue(p.keyDown(EditorKey(.char("k")))); XCTAssertFalse(p.isPlaying)
    }
}

final class ExternalClockTests: XCTestCase {
    func testVideoFollowsAudioClockAtForwardOneX() {
        let p = PlaybackState(duration: 10)
        var audio: Double? = 1.25
        p.externalClock = { audio }
        p.play()
        XCTAssertTrue(p.tick(0.016)); XCTAssertEqual(p.currentTime, 1.25, accuracy: 1e-9, "audio clock wins over dt")
        audio = 1.0
        XCTAssertFalse(p.tick(0.016), "never runs backwards while the device catches up"); XCTAssertEqual(p.currentTime, 1.25, accuracy: 1e-9)
        audio = nil
        p.tick(0.5); XCTAssertEqual(p.currentTime, 1.75, accuracy: 1e-9, "no device -> wall clock")
        audio = 99
        _ = p.keyDown(EditorKey(.char("l"))); _ = p.keyDown(EditorKey(.char("l")))   // 2× shuttle: wall clock
        XCTAssertFalse(p.wantsExternalClock)
    }
}

final class TimelineChunk4Tests: XCTestCase {
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300); c.setZoom(percent: 600)   // 100 px/s
        return (c, e)
    }
    func starts(_ e: TimelineEditor, _ track: String) -> [Double] {
        e.document.sequence.tracks.first { $0.id == track }!.clips.map(\.startFrame).sorted()
    }
    let rowY = [64.0, 112.0, 160.0]
    func x(_ t: Double) -> Double { 264 + 100 * t }

    func testRazorSplitsClickedClipAndShiftSplitsAll() throws {
        let (c, e) = try make()
        c.tool = .razor
        c.pointerMove(x: x(2), y: rowY[1]); XCTAssertEqual(c.view.razorGuideX, x(2))
        c.pointerDown(x: x(2), y: rowY[1]); c.pointerUp(x: x(2), y: rowY[1])
        XCTAssertEqual(starts(e, "track:v1"), [0, 60, 195])
        c.pointerDown(x: x(3), y: rowY[1], shift: true)
        XCTAssertEqual(starts(e, "track:v1"), [0, 60, 90, 195]); XCTAssertEqual(starts(e, "track:a1"), [0, 90])
        XCTAssertEqual(starts(e, "track:v2"), [15, 90], "logo (0.5–3.5s) is under 3s too")
    }

    func testMarqueeSelectsIntersectingClips() throws {
        let (c, _) = try make()
        c.pointerDown(x: x(10.8), y: 50)               // empty space right of everything, row 0
        c.pointerMove(x: x(10.8) - 2, y: 52)
        XCTAssertNil(c.view.marquee, "under the 4px threshold")
        c.pointerMove(x: x(5), y: rowY[2])
        XCTAssertEqual(c.view.marquee.map { $0.width }, x(10.8) - x(5))
        XCTAssertEqual(c.view.selection, ["clip:a", "clip:b", "clip:music"])
        c.pointerUp(x: x(5), y: rowY[2]); XCTAssertNil(c.view.marquee)
    }

    func testGapMenuCloseGapAndCloseAll() throws {
        let (c, e) = try make()
        c.secondaryClick(x: x(6.2), y: rowY[1])
        let m = try XCTUnwrap(c.view.gapMenu)
        XCTAssertEqual(m.gapWidth ?? 0, 0.5, accuracy: 1e-9); XCTAssertTrue(m.canCloseGap)
        c.pointerMove(x: m.x + 20, y: m.y + 10)
        XCTAssertEqual(c.view.gapHighlight.count, 1, "hovering Close gap highlights that gap")
        c.pointerDown(x: m.x + 20, y: m.y + 10)
        XCTAssertNil(c.view.gapMenu)
        XCTAssertEqual(starts(e, "track:v1"), [0, 180])
        XCTAssertTrue(e.undo()); XCTAssertEqual(starts(e, "track:v1"), [0, 195])
        XCTAssertTrue(e.closeAllGaps(trackId: "track:v2")); XCTAssertEqual(starts(e, "track:v2"), [0])
        c.secondaryClick(x: x(2), y: rowY[1]); XCTAssertNil(c.view.gapMenu, "clips get the clip menu, not the gap menu")
        c.secondaryClick(x: x(10.8), y: rowY[1]); XCTAssertEqual(c.view.gapMenu?.canCloseGap, false, "nothing to the right: no gap")
    }

    func testCopyPasteCutWithUndo() throws {
        let (c, e) = try make()
        c.view.selection = ["clip:b"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("c"), ctrl: true)))
        c.playback.seek(10.5)
        XCTAssertTrue(c.keyDown(EditorKey(.char("v"), ctrl: true)), "\(String(describing: e.lastFailure))")
        XCTAssertEqual(starts(e, "track:v1"), [0, 195, 315])
        XCTAssertEqual(c.view.selection, ["clip:b-copy"])
        XCTAssertTrue(e.undo()); XCTAssertEqual(starts(e, "track:v1"), [0, 195])
        c.view.selection = ["clip:logo"]
        XCTAssertTrue(c.keyDown(EditorKey(.char("x"), ctrl: true)))
        XCTAssertEqual(starts(e, "track:v2"), [])
    }

    func testSnapGuideColourByType() throws {
        let v = TimelineView(tracks: TimelineView.demo().tracks, duration: 11)
        v.pixelsPerSecond = 100
        v.drag = .move(clipIds: [], deltaSeconds: 0, trackDelta: 0, snapTime: 3)
        #if os(Linux)
        func px(_ type: TimelineSnapType) -> (UInt8, UInt8, UInt8) {
            v.snapType = type
            let t = CairoImageTarget(width: 900, height: 200); v.draw(t.canvas, size: CanvasSize(900, 200))
            let p = t.pixel(264 + 300, 190); return (p.r, p.g, p.b)
        }
        XCTAssertEqual(px(.playhead).1, 230)
        let edge = px(.clipEdge); XCTAssertGreaterThan(edge.0, 150); XCTAssertEqual(edge.0, edge.2)
        XCTAssertLessThan(px(.beat).0, 60, "no guide for beat snaps")
        #endif
    }
}
