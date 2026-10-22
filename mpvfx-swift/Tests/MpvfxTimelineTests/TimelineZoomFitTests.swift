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

/// docs/TIMELINE.md "Zoom": fit spans the sequence end plus its margin, fit is the zoom-out limit, buttons and keys
/// zoom about the playhead, pointer gestures about the pointer.
final class TimelineZoomFitTests: XCTestCase {
    static let width = 1266.0

    static func make(playhead: Double = 0) throws -> TimelineController {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())   // 11 s of clips
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(Self.width, 300)
        c.relayout()
        c.playback.seek(playhead); c.syncFromPlayback()
        return c
    }

    func testFitSpansTheSequenceEndPlusItsMargin() {
        XCTAssertEqual(TimelineZoom.endMargin(41), 2.05, accuracy: 1e-9, "5% of the end")
        XCTAssertEqual(TimelineZoom.endMargin(4), 1, "at least 1 s")
        XCTAssertEqual(TimelineZoom.span(duration: 41), 43.05, accuracy: 1e-9)
        XCTAssertEqual(TimelineZoom.span(duration: 0), TimelineZoom.minFitSpan, "an empty sequence still gets a ruler")
        XCTAssertEqual(TimelineZoom.span(duration: .nan), TimelineZoom.minFitSpan)
        XCTAssertEqual(TimelineZoom.fitPixelsPerSecond(viewportWidth: 1266, duration: 41, contentOrigin: 264), 1000 / 43.05, accuracy: 1e-9)
        XCTAssertEqual(TimelineZoom.fitPixelsPerSecond(viewportWidth: 200, duration: 41, contentOrigin: 264), 100, "no lanes visible")
    }

    func testFitShowsTheWholeSequenceAndNothingPastItsMargin() throws {
        let c = try make()
        XCTAssertEqual(c.zoomMode, .fit)
        XCTAssertEqual(c.view.x(for: c.view.rulerEnd), Self.width - 2, accuracy: 1e-6, "end + margin at the right edge")
        XCTAssertLessThan(c.view.x(for: c.view.duration), Self.width - 2, "the sequence end is on screen")
    }

    func testFitIsTheZoomOutLimit() throws {
        XCTAssertEqual(TimelineZoom.clamp(10, fit: 20), 100)
        XCTAssertEqual(TimelineZoom.next(false, mode: .fit, manual: 100, fit: 20), 100)
        XCTAssertEqual(TimelineZoom.pinch(deltaY: 500, mode: .manual, manual: 150, fit: 20), 100, "a pinch out stops at fit")
        let c = try make()
        c.zoom(in: false); c.zoom(in: false)
        XCTAssertEqual(c.view.pixelsPerSecond, c.fitPixelsPerSecond, accuracy: 1e-9)
        XCTAssertGreaterThan(c.view.x(for: c.view.rulerEnd), c.view.x(for: c.view.duration), "room after the end to drop a clip")
    }

    func testButtonsAndKeysZoomAboutThePlayhead() throws {
        let c = try make(playhead: 8)
        let before = c.view.x(for: 8)
        c.zoom(in: true)
        XCTAssertEqual(c.view.x(for: 8), before, accuracy: 0.5, "+ keeps the playhead where it was")
        XCTAssertTrue(c.keyDown(EditorKey(.char("="), ctrl: true)))
        XCTAssertEqual(c.view.x(for: 8), before, accuracy: 0.5, "⌘+ too")
        XCTAssertTrue(c.keyDown(EditorKey(.char("-"), meta: true)))
        XCTAssertEqual(c.view.x(for: 8), before, accuracy: 0.5, "⌘− too")
    }

    func testAPlayheadOutOfViewZoomsAboutTheMiddleOfTheLanes() throws {
        let c = try make(playhead: 0)
        c.setZoom(percent: 800, anchorX: Self.width)          // scrolled to the end, playhead off the left edge
        XCTAssertLessThan(c.view.x(for: 0), TimelineLayout.contentOrigin)
        let middle = (TimelineLayout.contentOrigin + Self.width) / 2, t = c.view.time(forX: middle)
        c.zoom(in: true)
        XCTAssertEqual(c.view.x(for: t), middle, accuracy: 0.5)
    }

    func testPointerZoomAnchorsAtThePointer() throws {
        let c = try make(playhead: 1)
        let t = c.view.time(forX: 900)
        c.scroll(dx: 0, dy: -60, x: 900, ctrl: true, shift: false)
        XCTAssertGreaterThan(c.view.pixelsPerSecond, c.fitPixelsPerSecond)
        XCTAssertEqual(c.view.x(for: t), 900, accuracy: 0.5)
    }

    func testScrollingStopsAtTheRulerEnd() throws {
        let c = try make()
        c.setZoom(percent: 400)
        c.scroll(dx: 1e6, dy: 0, x: 700, ctrl: false, shift: false)
        XCTAssertEqual(c.view.x(for: c.view.rulerEnd), Self.width, accuracy: 1e-6)
    }
}
