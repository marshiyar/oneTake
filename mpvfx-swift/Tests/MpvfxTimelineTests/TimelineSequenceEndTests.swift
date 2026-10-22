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
import MpvfxTheme

/// docs/TIMELINE.md "Ruler and sequence end": ticks stop at the end plus its margin, labels carry hours, a marker sits
/// at the end and the space after it is shaded.
final class TimelineSequenceEndTests: XCTestCase {
    /// The owner's project: 41 s of clips on a 1440 px window at 20 px/s.
    func view(duration: Double = 41) -> TimelineView {
        TimelineView(tracks: [TimelineTrackModel(name: "Video 1", clips: [TimelineClipModel(name: "a.mp4", start: 6, duration: duration - 6)])],
                     duration: duration, pixelsPerSecond: 20)
    }

    func testTicksStopAtTheEndPlusItsMargin() {
        let v = view()
        let ticks = v.rulerTicks(width: 1440)
        XCTAssertEqual(ticks.major.first, 0)
        XCTAssertEqual(ticks.major.last, 40, "major every 5 s up to 43.05 s, not on to the viewport edge")
        XCTAssertTrue(ticks.minor.allSatisfy { $0 <= v.rulerEnd }, "\(ticks.minor.filter { $0 > v.rulerEnd })")
        XCTAssertEqual(ticks.minor.last ?? 0, 43, accuracy: 1e-9, "minor every 1 s (5 parts of 150 frames), the last within the margin")
    }

    func testRulerLabelsAlwaysCarryHours() {
        let v = view(), r = RecordingCanvas()
        v.draw(r, size: CanvasSize(1440, 200))
        let labels = r.texts.filter { $0.hasPrefix("00:00:") && $0.count == 11 }
        XCTAssertEqual(labels, ["00:00:00:00", "00:00:05:00", "00:00:10:00", "00:00:15:00", "00:00:20:00",
                                "00:00:25:00", "00:00:30:00", "00:00:35:00", "00:00:40:00"],
                       "40 s reads 00:00:40:00, never a minute that looks like an hour: \(r.texts)")
        XCTAssertFalse(r.texts.contains("01:00:00"))
    }

    func testTheEndMarkerSitsOnTheSequenceEnd() {
        let v = view()
        XCTAssertEqual(v.sequenceEndLineLeft, TimelineView.snappedLineLeft(centre: TimelineLayout.contentOrigin + 41 * 20))
        XCTAssertNil(view(duration: 0).sequenceEndLineLeft, "an empty sequence has no end to mark")
    }

    func testEndTokensReadOnTheLanesInBothModes() {
        for mode in [ThemeMode.dark, .light] {
            let marker = ThemeTokens.timelineEndMarkerPair.value(mode), row = ThemeTokens.timelineRowPair.value(mode)
            XCTAssertGreaterThanOrEqual(marker.contrast(row), 3, "\(mode): the marker is a 3:1 line")
        }
    }

    #if os(Linux)   // CairoImageTarget is the Linux canvas backend; the pixel checks run there only
    func testTheMarkerIsDrawnAndTheSpaceAfterTheEndIsShaded() {
        let v = view(), t = CairoImageTarget(width: 1440, height: 200)
        v.draw(t.canvas, size: CanvasSize(1440, 200))
        func rgb(_ x: Double, _ y: Double) -> [UInt8] { let p = t.pixel(Int(x), Int(y)); return [p.r, p.g, p.b] }
        let lx = v.sequenceEndLineLeft ?? 0, lane = TimelineLayout.rowTop(0) + TimelineLayout.defaultTrackHeight + 4
        XCTAssertEqual(rgb(lx, lane), [140, 140, 140], "end marker #8C8C8C through the lanes")
        XCTAssertEqual(rgb(lx, 12), [140, 140, 140], "and the ruler")
        XCTAssertEqual(rgb(lx - 3, 1), [140, 140, 140], "the flag points back into the sequence")
        let inside = rgb(lx - 40, lane), after = rgb(lx + 40, lane)
        XCTAssertEqual(inside, [29, 29, 29], "inside the sequence the lane keeps #1D1D1D")
        XCTAssertLessThan(Int(after[0]), Int(inside[0]) - 5, "after the end the lane is shaded: \(after)")
    }
    #endif
}
