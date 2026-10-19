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
@testable import MpvfxPlayer
import MpvfxTimeline
import MpvfxCanvas
import MpvfxPanels

final class PlayerGeometryTests: XCTestCase {
    func testLetterboxToolbarAndButtons() {
        let v = PlayerView(playback: PlaybackState(duration: 10))
        let size = CanvasSize(1032, 640)
        let vp = v.viewportRect(in: size)
        XCTAssertEqual(vp, CanvasRect(x: 0, y: 36, width: 1032, height: 640 - 36 - 40), "tools bar h-9 above, transport h-10 below")
        let f = v.frameRect(in: size)
        XCTAssertEqual(f.width / f.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertLessThanOrEqual(f.maxY, 640 - 40 - 8, "stage sits above the 40px controls")
        XCTAssertEqual(f.y - (36 + 8), 640 - 40 - 8 - f.maxY, accuracy: 1, "letterbox is centred vertically")
        XCTAssertEqual(v.buttonRect(.play, in: size), CanvasRect(x: 500, y: 604, width: 32, height: 32))
        // Right cluster, right to left: shortcuts, fullscreen, loop, speed, volume.
        XCTAssertEqual(v.buttonRect(.shortcuts, in: size).maxX, 1020)
        XCTAssertEqual(v.buttonRect(.fullscreen, in: size).maxX, v.buttonRect(.shortcuts, in: size).x)
        XCTAssertEqual(v.buttonRect(.loop, in: size).maxX, v.buttonRect(.fullscreen, in: size).x)
        XCTAssertEqual(v.buttonRect(.speed, in: size).width, SpeedPopover.triggerSize.width)
        XCTAssertEqual(v.buttonRect(.mute, in: size).maxX, v.buttonRect(.speed, in: size).x)
        XCTAssertEqual(v.button(at: .init(516, 620), in: size), .play)
        v.isFullscreen = true
        XCTAssertEqual(v.viewportRect(in: size).y, 0, "fullscreen drops the tools bar")
    }

    func testControllerPlayLoopSelectMoveResize() {
        let pb = PlaybackState(duration: 10)
        let v = PlayerView(playback: pb); v.canvasSize = CanvasSize(1000, 500)
        v.toolbar.snapEnabled = false
        v.elements = [StageElement(id: "e", name: "E", rect: CanvasRect(x: 100, y: 100, width: 200, height: 100), kind: .element)]
        let c = PlayerController(view: v); c.size = CanvasSize(1016, 36 + 516 + 40)   // frame 1000×500 at (8, 44), scale 1
        let f = v.frameRect(in: c.size)
        XCTAssertEqual(f, CanvasRect(x: 8, y: 44, width: 1000, height: 500))
        XCTAssertEqual(v.scale(in: c.size), 1, accuracy: 1e-9)
        let play = v.buttonRect(.play, in: c.size)
        c.pointerDown(x: play.x + 16, y: play.y + 16); XCTAssertTrue(pb.isPlaying)
        let loop = v.buttonRect(.loop, in: c.size)
        c.pointerDown(x: loop.x + 5, y: loop.y + 5); XCTAssertTrue(pb.loopEnabled)
        c.pointerDown(x: f.x + 192, y: f.y + 142); XCTAssertEqual(v.selection, "e")
        c.pointerMove(x: f.x + 202, y: f.y + 162); c.pointerUp(x: f.x + 202, y: f.y + 162)
        XCTAssertEqual(v.elements[0].rect, CanvasRect(x: 110, y: 120, width: 200, height: 100))
        c.pointerDown(x: f.x + 310, y: f.y + 220)   // se handle
        c.pointerMove(x: f.x + 330, y: f.y + 240); c.pointerUp(x: 0, y: 0)
        XCTAssertEqual(v.elements[0].rect, CanvasRect(x: 110, y: 120, width: 220, height: 120))
        c.pointerDown(x: f.x + 900, y: f.y + 400); XCTAssertNil(v.selection, "click on empty stage clears selection")
    }
}

#if os(Linux)
final class PlayerRenderTests: XCTestCase {
    func testChromePixels() {
        let pb = PlaybackState(duration: 10)
        let v = PlayerView(playback: pb); v.canvasSize = CanvasSize(1000, 500)
        v.elements = [StageElement(id: "e", name: "E", rect: CanvasRect(x: 100, y: 100, width: 200, height: 100), kind: .element)]
        v.selection = "e"
        let size = CanvasSize(1016, 592)
        let t = CairoImageTarget(width: 1016, height: 592)
        v.draw(t.canvas, size: size)
        func rgb(_ x: Int, _ y: Int) -> [Int] { let p = t.pixel(x, y); return [Int(p.r), Int(p.g), Int(p.b)] }
        XCTAssertEqual(rgb(5, 590), [29, 29, 29], "transport row on the shell surface")
        XCTAssertEqual(rgb(5, 20), [20, 20, 20], "tools bar on the viewport surface")
        XCTAssertEqual(rgb(3, 300), [20, 20, 20], "viewport surface")
        XCTAssertEqual(rgb(8 + 100, 44 + 100), [255, 255, 255], "nw handle dot centre is white")
        let border = rgb(8 + 200, 44 + 101); XCTAssertGreaterThan(border[2], 150, "accent (blue) selection border")
        let play = v.buttonRect(.play, in: size)
        XCTAssertEqual(rgb(Int(play.x) + 14, Int(play.y) + 16), [250, 250, 250], "play triangle #FAFAFA")
        // Pause: the morph runs 280 ms; once finished the bars have a gap in the middle.
        var clock = 100.0
        v.now = { clock }
        v.draw(t.canvas, size: size)
        pb.play(); v.draw(t.canvas, size: size)
        clock += 0.5; v.draw(t.canvas, size: size)
        XCTAssertEqual(rgb(Int(play.x) + 15, Int(play.y) + 16), [29, 29, 29], "pause glyph has a gap in the middle")
    }
}
#endif
