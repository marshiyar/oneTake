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

/// The transport loop:
/// the range is in point (else 0) to out point (else the end), wrapping to the start at the end frame.
final class TimelineLoopTests: XCTestCase {
    func make(_ d: Double = 3) -> PlaybackState { let p = PlaybackState(duration: d, fps: 30); return p }

    func testToggleStateAndInOutTurnLoopOn() {
        let p = make()
        XCTAssertFalse(p.loopEnabled, "off on open (kept in memory only)")
        p.keyDown(EditorKey(.char("L"), shift: true)); XCTAssertTrue(p.loopEnabled)
        p.keyDown(EditorKey(.char("L"), shift: true)); XCTAssertFalse(p.loopEnabled)
        p.seek(1); p.keyDown(EditorKey(.char("i"))); XCTAssertEqual(p.inPoint, 1); XCTAssertTrue(p.loopEnabled, "setting an in point turns loop on")
        p.loopEnabled = false
        p.seek(2); p.keyDown(EditorKey(.char("o"))); XCTAssertEqual(p.outPoint, 2); XCTAssertTrue(p.loopEnabled)
        p.seek(0.5); p.keyDown(EditorKey(.char("o"))); XCTAssertEqual(p.outPoint, 0.5); XCTAssertNil(p.inPoint, "an out point at or before the in point drops it")
        p.keyDown(EditorKey(.char("i"), shift: true)); XCTAssertTrue(p.loopEnabled, "clearing a point leaves the toggle alone")
    }

    func testRangeFallsBackToWholeTimeline() {
        let p = make()
        XCTAssertEqual(p.loopStart, 0); XCTAssertEqual(p.loopEnd, 3)
        p.inPoint = 1; p.outPoint = 2.5
        XCTAssertEqual(p.loopStart, 1); XCTAssertEqual(p.loopEnd, 2.5)
        p.outPoint = 9; XCTAssertEqual(p.loopEnd, 3, "out point clamps to the duration")
        p.duration = 0.5; XCTAssertEqual(p.loopStart, 0); XCTAssertEqual(p.loopEnd, 0.5, "an empty range means the whole timeline")
    }

    func testForwardWrapsAtTheEndFrameToTheStartAndKeepsPlaying() {
        let p = make()
        p.loopEnabled = true
        p.seek(2.9); p.play()
        p.tick(0.05); XCTAssertEqual(p.currentTime, 2.95, accuracy: 1e-9); XCTAssertTrue(p.isPlaying)
        p.tick(0.05); XCTAssertEqual(p.currentTime, 0, "wraps exactly to the loop start at the end"); XCTAssertTrue(p.isPlaying)
        p.inPoint = 1; p.outPoint = 2
        p.seek(1.95); p.tick(0.04); XCTAssertEqual(p.currentTime, 1.99, accuracy: 1e-9)
        p.tick(0.02); XCTAssertEqual(p.currentTime, 1); XCTAssertTrue(p.isPlaying)
        // Scrubbed past the out point while playing: the next tick wraps.
        p.seek(2.7); p.tick(0.01); XCTAssertEqual(p.currentTime, 1)
        // Three wraps in a row stay on time: every crossing lands on the start.
        var wraps = 0, last = p.currentTime
        for _ in 0..<200 { p.tick(1.0 / 60); if p.currentTime < last { wraps += 1; XCTAssertEqual(p.currentTime, 1) }; last = p.currentTime }
        XCTAssertEqual(wraps, 3, "200 ticks of 1/60 s over a 1 s loop starting at 1.0 wrap three times")
    }

    func testLoopOffStopsAtTheOutPointAndPlayFromTheEndRestartsAtTheInPoint() {
        let p = make()
        p.outPoint = 2; p.loopEnabled = false
        p.seek(1.9); p.play(); p.tick(0.2)
        XCTAssertEqual(p.currentTime, 2); XCTAssertFalse(p.isPlaying, "loop off: playback stops at the out point")
        p.outPoint = nil; p.inPoint = 0.5; p.loopEnabled = false
        p.seek(3); p.play(); XCTAssertEqual(p.currentTime, 0.5, "play from the very end starts at the in point")
        p.inPoint = nil; p.seek(3); p.play(); XCTAssertEqual(p.currentTime, 0)
        p.seek(2.95); p.tick(0.1); XCTAssertEqual(p.currentTime, 3); XCTAssertFalse(p.isPlaying)
    }

    func testReverseAndShuttleWrapOrStopAtTheLoopStart() {
        let p = make()
        p.inPoint = 1; p.outPoint = 2   // loop on
        p.seek(1.05); p.keyDown(EditorKey(.char("j")))   // reverse 1x
        p.tick(0.1); XCTAssertEqual(p.currentTime, 2, "reverse wraps to the loop end"); XCTAssertTrue(p.isPlaying)
        p.loopEnabled = false
        p.seek(1.05); p.tick(0.1); XCTAssertEqual(p.currentTime, 1, "loop off: reverse stops at the loop start"); XCTAssertFalse(p.isPlaying)
        // Forward shuttle (2x) wraps like 1x.
        p.loopEnabled = true; p.seek(1.9)
        p.keyDown(EditorKey(.char("l"))); p.keyUp(EditorKey(.char("l"))); p.keyDown(EditorKey(.char("l")))
        XCTAssertEqual(p.playbackRate, 2)
        p.tick(0.1); XCTAssertEqual(p.currentTime, 1)
        // Reverse from 0 starts at the end (playBackward).
        let q = make(); q.keyDown(EditorKey(.char("j"))); XCTAssertEqual(q.currentTime, 3)
    }

    func testExternalClockWrapIsFollowed() {
        let p = make()
        p.loopEnabled = true; p.inPoint = 1; p.outPoint = 2
        var clock = 1.9
        p.externalClock = { clock }
        p.seek(1.8); p.play()
        p.tick(0.016); XCTAssertEqual(p.currentTime, 1.9, accuracy: 1e-9)
        clock = 1.02   // the device wrapped
        XCTAssertTrue(p.tick(0.016)); XCTAssertEqual(p.currentTime, 1.02, accuracy: 1e-9); XCTAssertTrue(p.isPlaying)
        clock = 1.05; p.tick(0.016); XCTAssertEqual(p.currentTime, 1.05, accuracy: 1e-9)
    }
}
