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

/// `setZoom(pixelsPerSecond:)` gives exactly the scale asked for (within the zoom limits) at any viewport, and keeps
/// the time under the anchor in place.
final class TimelineAbsoluteZoomTests: XCTestCase {
    func make(width: Double) throws -> TimelineController {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(width, 300)
        return c
    }

    func testTheScaleIsExactWhenItIsNotAWholePercentOfTheFit() throws {
        let c = try make(width: 1200)
        XCTAssertNotEqual((100 / c.fitPixelsPerSecond * 100).truncatingRemainder(dividingBy: 1), 0, "the case Codex found on #226")
        c.setZoom(pixelsPerSecond: 100)
        XCTAssertEqual(c.view.pixelsPerSecond, 100, accuracy: 1e-9)
        c.relayout()
        XCTAssertEqual(c.view.pixelsPerSecond, 100, accuracy: 1e-9, "a relayout keeps it")
    }

    func testTheScaleStaysWithinTheZoomLimits() throws {
        let c = try make(width: 1200)
        let fit = c.fitPixelsPerSecond
        c.setZoom(pixelsPerSecond: 1e9)
        XCTAssertEqual(c.view.pixelsPerSecond, fit * TimelineZoom.maxPercent(fit: fit) / 100, accuracy: 1e-6)
        c.setZoom(pixelsPerSecond: 1e-9)
        XCTAssertEqual(c.view.pixelsPerSecond, fit * TimelineZoom.minPercent / 100, accuracy: 1e-9)
    }

    func testTheTimeUnderTheAnchorStaysPut() throws {
        let c = try make(width: 1200)
        let t = c.view.time(forX: 700)
        c.setZoom(pixelsPerSecond: 100, anchorX: 700)
        XCTAssertEqual(c.view.x(for: t), 700, accuracy: 1e-6)
    }
}
