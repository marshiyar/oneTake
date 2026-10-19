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
}

#if os(Linux)
final class TimelineRenderTests: XCTestCase {
    func testRendersThemeColors() {
        let v = TimelineView.demo()
        let t = CairoImageTarget(width: 1200, height: 260)
        v.draw(t.canvas, size: CanvasSize(1200, 260))
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { let p = t.pixel(x, y); return [p.r, p.g, p.b] }
        XCTAssertEqual(rgb(1150, 30), [10, 10, 11], "top pad = shell #0A0A0B")
        XCTAssertEqual(rgb(200, 60), [14, 15, 18], "label column = gutter #0E0F12")
        XCTAssertEqual(rgb(1150, 60), [16, 16, 20], "empty row = #101014")
        // Playhead at t=2.4, pps 90 -> centre x = 264 + 216 = 480.
        // Playhead line is one opaque pixel (snapped like Chromium), not two 50% AA pixels.
        let line = t.pixel(480, 200); XCTAssertEqual([line.r, line.g, line.b], [60, 230, 172], "accent line")
        XCTAssertEqual(rgb(479, 200), [10, 10, 11], "no AA bleed left of the line")
        XCTAssertEqual(rgb(481, 200), [10, 10, 11], "no AA bleed right of the line")
        let headCentre = rgb(480, 6); XCTAssertNotEqual(headCentre, [60, 230, 172], "head is outline-only at rest")
        v.scrubbing = true; v.draw(t.canvas, size: CanvasSize(1200, 260))
        XCTAssertEqual(rgb(480, 6), [60, 230, 172], "head filled while scrubbing")
    }
}
#endif
