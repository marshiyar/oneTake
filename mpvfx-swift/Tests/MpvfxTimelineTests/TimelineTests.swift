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

final class TimelineGeometryTests: XCTestCase {
    func testLayoutParity() {
        XCTAssertEqual(TimelineLayout.contentOrigin, 264)
        XCTAssertEqual(TimelineLayout.rowTop(0), 40); XCTAssertEqual(TimelineLayout.rowTop(2), 136)
        XCTAssertEqual(TimelineLayout.playheadLeft(time: 2, pps: 100), 264 + 200 - 4.5)
        XCTAssertEqual(TimelineLayout.playheadLeft(time: .nan, pps: 100), 259.5)
        XCTAssertEqual(TimelineLayout.playheadLeft(time: -1, pps: 100), 259.5)
    }
    func testMajorInterval() {
        XCTAssertEqual(TimelineRuler.majorInterval(duration: 12, pps: 90), 1)
        XCTAssertEqual(TimelineRuler.majorInterval(duration: 12, pps: 10), 10)
        XCTAssertEqual(TimelineRuler.majorInterval(duration: 12, pps: nil), 2)
        XCTAssertEqual(TimelineRuler.majorInterval(duration: 12, pps: 0.001), 3600)
        XCTAssertEqual(TimelineRuler.majorInterval(duration: 12, pps: 500, frameRate: 30), 6.0 / 30, accuracy: 1e-9)
    }
    func testMinorSubdivisions() {
        XCTAssertEqual(TimelineRuler.minorSubdivisions(major: 1, pps: 90), 4)
        XCTAssertEqual(TimelineRuler.minorSubdivisions(major: 1, pps: 20), 2)
        XCTAssertEqual(TimelineRuler.minorSubdivisions(major: 1, pps: 10), 0)
    }
    func testLineSnapping() {
        XCTAssertEqual(TimelineView.snappedLineLeft(centre: 480), 480)    // [479.5,480.5) -> pixel 480
        XCTAssertEqual(TimelineView.snappedLineLeft(centre: 480.4), 480)
        XCTAssertEqual(TimelineView.snappedLineLeft(centre: 480.6), 480)   // left 480.1 -> 480
        XCTAssertEqual(TimelineView.snappedLineLeft(centre: 481.2), 481)   // left 480.7 -> 481
    }
    func testLabels() {
        XCTAssertEqual(TimelineRuler.label(65, duration: 100, major: 5), "01:05")
        XCTAssertEqual(TimelineRuler.label(1.25, duration: 100, major: 0.5), "00:01.3")
        XCTAssertEqual(TimelineRuler.label(1.25, duration: 100, major: 0.05), "00:01.25")
        XCTAssertEqual(TimelineRuler.label(3725, duration: 4000, major: 60), "1:02:05")
        XCTAssertEqual(TimelineRuler.label(.nan, duration: 1, major: 1), "00:00")
    }
    func testTimecode() {
        XCTAssertEqual(TimelineRuler.timecode(0, frameRate: 30), "00:00:00")
        XCTAssertEqual(TimelineRuler.timecode(6.5, frameRate: 30), "00:06:15")
        XCTAssertEqual(TimelineRuler.timecode(65.48, frameRate: 25), "01:05:12")
        XCTAssertEqual(TimelineRuler.timecode(0.6 / 30, frameRate: 30), "00:00:01", "rounds to the nearest frame")
        XCTAssertEqual(TimelineRuler.timecode(1, frameRate: 29.97), "00:01:00", "frames count at the nominal 30")
        XCTAssertEqual(TimelineRuler.timecode(3725, frameRate: 30), "01:02:05:00", "hours appear from an hour on")
        XCTAssertEqual(TimelineRuler.timecode(5, frameRate: 30, hours: true), "00:00:05:00")
        XCTAssertEqual(TimelineRuler.timecode(3600, frameRate: 29.97), "00:59:56:12", "hours follow real time at 29.97")
        XCTAssertEqual(TimelineRuler.timecode(3600, frameRate: 23.976), "00:59:56:10", "hours follow real time at 23.976")
        XCTAssertEqual(TimelineRuler.timecode(3599, frameRate: 29.97), "59:55:12")
        XCTAssertEqual(TimelineRuler.timecode(3599.99, frameRate: 30), "01:00:00:00", "rounding up into the hour")
        XCTAssertEqual(TimelineRuler.timecode(-2, frameRate: 30), "00:00:00")
        XCTAssertEqual(TimelineRuler.timecode(.nan, frameRate: 30), "00:00:00")
        XCTAssertEqual(TimelineRuler.timecode(1, frameRate: 0, hours: true), "00:00:00:00")
    }
}

/// Clip durations and the ruler read as timecode (docs/DESIGN.md Principle 5).
final class TimelineTimecodeTextTests: XCTestCase {
    func texts(trackHeight: Double) -> [String] {
        let v = TimelineView(tracks: [TimelineTrackModel(name: "Video 1", clips: [TimelineClipModel(name: "a.mp4", start: 0.5, duration: 2.5)])],
                             duration: 4, pixelsPerSecond: 100)
        v.trackHeight = trackHeight
        let r = RecordingCanvas()
        v.draw(r, size: CanvasSize(1200, 200))
        return r.texts
    }

    func testClipDurationAndRulerLabelsAreTimecode() {
        let t = texts(trackHeight: TimelineLayout.defaultTrackHeight)
        XCTAssertTrue(t.contains("a.mp4"))
        XCTAssertTrue(t.contains("00:02:15"), "2.5 s clip at 30 fps: \(t)")
        XCTAssertEqual(t.filter { $0.hasPrefix("00:0") && $0 != "00:02:15" }, ["00:00:00", "00:01:00", "00:02:00", "00:03:00", "00:04:00"],
                       "ruler ticks every second")
    }

    func testShortRowsLeaveTheTimecodeOut() {
        let t = texts(trackHeight: TimelineLayout.minTrackHeight)
        XCTAssertTrue(t.contains("a.mp4"), "the name stays in the header")
        XCTAssertFalse(t.contains("00:02:15"), "no room below the header: \(t)")
    }
}

#if os(Linux)
final class TimelineRenderTests: XCTestCase {
    func testRendersThemeColors() {
        let v = TimelineView.demo()
        let t = CairoImageTarget(width: 1200, height: 260)
        v.draw(t.canvas, size: CanvasSize(1200, 260))
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { let p = t.pixel(x, y); return [p.r, p.g, p.b] }
        XCTAssertEqual(rgb(1150, 30), [29, 29, 29], "top pad = timeline surface #1D1D1D")
        XCTAssertEqual(rgb(200, 60), [33, 33, 33], "label column = gutter #212121")
        XCTAssertEqual(rgb(1150, 60), [29, 29, 29], "empty row = #1D1D1D")
        // Playhead at t=2.4, pps 90 -> centre x = 264 + 216 = 480.
        // Playhead line is one opaque pixel (snapped like Chromium), not two 50% AA pixels.
        let line = t.pixel(480, 200); XCTAssertEqual([line.r, line.g, line.b], [90, 152, 240], "accent line")
        XCTAssertEqual(rgb(479, 200), [29, 29, 29], "no AA bleed left of the line")
        XCTAssertEqual(rgb(481, 200), [29, 29, 29], "no AA bleed right of the line")
        let headCentre = rgb(480, 6); XCTAssertNotEqual(headCentre, [90, 152, 240], "head is outline-only at rest")
        v.scrubbing = true; v.draw(t.canvas, size: CanvasSize(1200, 260))
        XCTAssertEqual(rgb(480, 6), [90, 152, 240], "head filled while scrubbing")
    }
}
#endif
