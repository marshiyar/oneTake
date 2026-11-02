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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxPanels

/// Tests for the speed graph model and input.
final class SpeedGraphTests: XCTestCase {
    /// A graph with two points over a 100-frame clip, drawn so the plot is set.
    func makeGraph() -> SpeedGraph {
        let g = SpeedGraph(points: [.init(t: 0, speed: 1), .init(t: 100, speed: 1)],
                           durationFrames: 100, playheadFrame: 40, fps: 30)
        g.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 200, height: SpeedGraph.height))
        return g
    }

    /// Applies actions the way the host will after the editor accepts them.
    func run(_ g: SpeedGraph, _ actions: [SpeedGraphAction]) {
        for a in actions { g.apply(a) }
    }

    // MARK: Log mapping

    /// The bounds map to the plot edges.
    func testMappingEndpoints() {
        let g = makeGraph()
        XCTAssertEqual(g.y(forSpeed: 0.1), g.y(forSpeed: 0.05), accuracy: 1e-9, "clamped below")
        XCTAssertEqual(g.y(forSpeed: 10), g.y(forSpeed: 99), accuracy: 1e-9, "clamped above")
        XCTAssertGreaterThan(g.y(forSpeed: 0.1), g.y(forSpeed: 10), "slow at the bottom")
        XCTAssertEqual(g.speed(forY: g.y(forSpeed: 0.1)), 0.1, accuracy: 1e-9)
        XCTAssertEqual(g.speed(forY: g.y(forSpeed: 10)), 10, accuracy: 1e-9)
    }

    /// 1x sits at the geometric middle of the plot.
    func testOneXInTheMiddle() {
        let g = makeGraph()
        let top = g.y(forSpeed: 10), bottom = g.y(forSpeed: 0.1), mid = g.y(forSpeed: 1)
        XCTAssertEqual(mid, (top + bottom) / 2, accuracy: 1e-9)
    }

    /// Speed round-trips through y.
    func testMappingRoundTrip() {
        let g = makeGraph()
        for s in [0.1, 0.25, 0.5, 1, 2, 4, 10] {
            XCTAssertEqual(g.speed(forY: g.y(forSpeed: s)), s, accuracy: 1e-9)
        }
    }

    // MARK: Keyboard

    /// Enter adds a point at the playhead at the ramp speed there.
    func testEnterAddsAtPlayhead() {
        let g = makeGraph()
        run(g, g.keyDown(EditorKey(.enter)))
        XCTAssertEqual(g.points.count, 3)
        XCTAssertEqual(g.points[1].t, 40, accuracy: 1e-9)
        XCTAssertEqual(g.points[1].speed, 1, accuracy: 1e-9)
        XCTAssertEqual(g.focused, 1)
    }

    /// Tab walks focus forward and back; leaving the end clears focus.
    func testTabWalksFocus() {
        let g = makeGraph()
        run(g, g.keyDown(EditorKey(.tab)))
        XCTAssertEqual(g.focused, 0)
        run(g, g.keyDown(EditorKey(.tab)))
        XCTAssertEqual(g.focused, 1)
        run(g, g.keyDown(EditorKey(.tab)))
        XCTAssertNil(g.focused)
        run(g, g.keyDown(EditorKey(.tab, shift: true)))
        XCTAssertEqual(g.focused, 1)
        run(g, g.keyDown(EditorKey(.tab, shift: true)))
        XCTAssertEqual(g.focused, 0)
    }

    /// Left/Right nudge by a frame, Shift by ten, staying ordered.
    func testArrowsNudgeFrames() {
        let g = makeGraph()
        g.focused = 1
        run(g, g.keyDown(EditorKey(.left)))
        XCTAssertEqual(g.points[1].t, 99, accuracy: 1e-9)
        run(g, g.keyDown(EditorKey(.right, shift: true)))
        XCTAssertEqual(g.points[1].t, 100, accuracy: 1e-9, "clamped to the clip end")
        g.focused = 0
        run(g, g.keyDown(EditorKey(.left)))
        XCTAssertEqual(g.points[0].t, 0, accuracy: 1e-9, "clamped to the clip start")
        run(g, g.keyDown(EditorKey(.right, shift: true)))
        XCTAssertEqual(g.points[0].t, 10, accuracy: 1e-9)
    }

    /// Up/Down nudge speed by 0.05x, Shift by ten steps, clamped to the bounds.
    func testArrowsNudgeSpeed() {
        let g = makeGraph()
        g.focused = 0
        run(g, g.keyDown(EditorKey(.up)))
        XCTAssertEqual(g.points[0].speed, 1.05, accuracy: 1e-9)
        run(g, g.keyDown(EditorKey(.down, shift: true)))
        XCTAssertEqual(g.points[0].speed, 0.55, accuracy: 1e-9)
        for _ in 0..<30 { run(g, g.keyDown(EditorKey(.down))) }
        XCTAssertEqual(g.points[0].speed, 0.1, accuracy: 1e-9, "clamped to the floor")
        for _ in 0..<300 { run(g, g.keyDown(EditorKey(.up))) }
        XCTAssertEqual(g.points[0].speed, 10, accuracy: 1e-9, "clamped to the ceiling")
    }

    /// Delete removes the focused point but never the last one.
    func testDeleteRemovesButKeepsOne() {
        let g = makeGraph()
        g.focused = 0
        run(g, g.keyDown(EditorKey(.delete)))
        XCTAssertEqual(g.points.count, 1)
        run(g, g.keyDown(EditorKey(.backspace)))
        XCTAssertEqual(g.points.count, 1, "the last point stays")
    }

    /// Digits are not used.
    func testDigitsDoNothing() {
        let g = makeGraph()
        for d in ["1", "2", "3", "4", "5", "6"] {
            XCTAssertEqual(g.keyDown(EditorKey(.char(Character(d)))), [])
        }
        XCTAssertEqual(g.points.count, 2)
    }

    // MARK: Pointer matches keyboard

    /// Tapping empty graph adds the same point the keys would move into place.
    func testPointerAddMatchesKeyboard() {
        let viaPointer = makeGraph(), viaKeys = makeGraph()
        let x = viaPointer.x(forFrame: 40), y = viaPointer.y(forSpeed: 1)
        run(viaPointer, viaPointer.pointerDown(CanvasPoint(x, y)))
        XCTAssertEqual(viaPointer.points.count, 3)
        run(viaKeys, viaKeys.keyDown(EditorKey(.enter)))
        XCTAssertEqual(viaPointer.points.map(\.t), viaKeys.points.map(\.t))
        XCTAssertEqual(viaPointer.points.map(\.speed), viaKeys.points.map(\.speed))
    }

    /// Dragging reports one move on release, matching a keyboard nudge path.
    func testPointerDragMatchesKeyboard() {
        let viaPointer = makeGraph()
        let start = CanvasPoint(viaPointer.x(forFrame: 0), viaPointer.y(forSpeed: 1))
        run(viaPointer, viaPointer.pointerDown(start))
        XCTAssertEqual(viaPointer.pointerMove(CanvasPoint(viaPointer.x(forFrame: 30), viaPointer.y(forSpeed: 2))), [],
                      "drag previews without actions until release")
        XCTAssertNotNil(viaPointer.draggingPreview)
        let end = CanvasPoint(viaPointer.x(forFrame: 30), viaPointer.y(forSpeed: 2))
        let released = viaPointer.pointerUp(end)
        XCTAssertEqual(released.count, 1)
        run(viaPointer, released)
        let viaKeys = makeGraph()
        viaKeys.focused = 0
        for _ in 0..<3 { run(viaKeys, viaKeys.keyDown(EditorKey(.right, shift: true))) }
        XCTAssertEqual(viaPointer.points[0].t, viaKeys.points[0].t, accuracy: 1e-9)
    }

    /// Pressing a point focuses it; Delete then removes it like the keys.
    func testPointerPressThenDelete() {
        let viaPointer = makeGraph(), viaKeys = makeGraph()
        let at = CanvasPoint(viaPointer.x(forFrame: 100), viaPointer.y(forSpeed: 1))
        run(viaPointer, viaPointer.pointerDown(at))
        XCTAssertEqual(viaPointer.focused, 1)
        run(viaPointer, viaPointer.keyDown(EditorKey(.delete)))
        viaKeys.focused = 1
        run(viaKeys, viaKeys.keyDown(EditorKey(.delete)))
        XCTAssertEqual(viaPointer.points, viaKeys.points)
    }

    // MARK: Hit testing

    /// hitPoint finds a point at its dot and nothing in empty space.
    func testHitPoint() {
        let g = makeGraph()
        XCTAssertEqual(g.hitPoint(at: CanvasPoint(g.x(forFrame: 0), g.y(forSpeed: 1))), 0)
        XCTAssertEqual(g.hitPoint(at: CanvasPoint(g.x(forFrame: 100), g.y(forSpeed: 1))), 1)
        XCTAssertNil(g.hitPoint(at: CanvasPoint(g.x(forFrame: 50), g.y(forSpeed: 1))))
    }

    // MARK: Formatting

    /// Speeds print with a × suffix, trimming integers.
    func testFormatSpeed() {
        XCTAssertEqual(SpeedGraph.formatSpeed(0.25), "0.25×")
        XCTAssertEqual(SpeedGraph.formatSpeed(2), "2×")
        XCTAssertEqual(SpeedGraph.formatSpeed(1.5), "1.5×")
    }

    /// Frames print as MM:SS:FF timecode.
    func testFormatTime() {
        XCTAssertEqual(SpeedGraph.formatTime(frame: 0, fps: 30), "00:00:00")
        XCTAssertEqual(SpeedGraph.formatTime(frame: 90, fps: 30), "00:03:00")
        XCTAssertEqual(SpeedGraph.formatTime(frame: 1890, fps: 30), "01:03:00")
    }

    // MARK: Focus validity

    /// Removing the focused point leaves focus on a live point.
    func testFocusedStaysValidAfterRemoval() {
        let g = makeGraph()
        run(g, g.keyDown(EditorKey(.enter)))
        g.focused = 2
        run(g, g.keyDown(EditorKey(.delete)))
        XCTAssertNotNil(g.focused)
        XCTAssertTrue(g.points.indices.contains(g.focused!))
        g.focused = 0
        run(g, g.keyDown(EditorKey(.delete)))
        XCTAssertTrue(g.points.indices.contains(g.focused!))
    }

    // MARK: Drawing

    /// Drawing emits the speed labels without crashing.
    func testDrawEmitsSpeedLabels() {
        let g = makeGraph()
        let c = PanelMeasureCanvas()
        g.draw(c, in: CanvasRect(x: 0, y: 0, width: 200, height: SpeedGraph.height))
        XCTAssertTrue(c.drawnStrings.contains(SpeedGraph.formatSpeed(1)))
        XCTAssertTrue(c.drawnStrings.contains("Speed"))
    }
}
