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

/// Stage outlines that mark a media item's bounds are square and pixel-aligned (user decision; docs/FEATURES.md §4).
final class StageOutlineTests: XCTestCase {
    func testPixelAlignedSnapsEdgesToDevicePixels() {
        XCTAssertEqual(PlayerView.pixelAligned(CanvasRect(x: 10.3, y: 20.6, width: 50.4, height: 9.8), scale: 1),
                       CanvasRect(x: 10, y: 21, width: 51, height: 9))
        XCTAssertEqual(PlayerView.pixelAligned(CanvasRect(x: 10.3, y: 20.6, width: 50.4, height: 9.8), scale: 2),
                       CanvasRect(x: 10.5, y: 20.5, width: 50, height: 10))
    }

    #if os(Linux)
    /// Paints nothing over the stage surface, so outline pixels sit on one flat colour.
    final class FlatSource: FrameSource {
        func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement]) {}
    }

    let size = CanvasSize(1016, 592)
    func makeView() -> PlayerView {
        let v = PlayerView(playback: PlaybackState(duration: 10))
        v.canvasSize = CanvasSize(1000, 500)
        v.frameSource = FlatSource()
        v.now = { 100 }
        // Fractional boxes: the outlines must still land on whole pixels.
        v.elements = [StageElement(id: "a", name: "A", rect: CanvasRect(x: 100.3, y: 100.4, width: 200.2, height: 100.4), kind: .video),
                      StageElement(id: "b", name: "B", rect: CanvasRect(x: 500.6, y: 250.2, width: 150.1, height: 120.5), kind: .image)]
        return v
    }
    func render(_ v: PlayerView) -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(size.width), height: Int(size.height))
        v.draw(t.canvas, size: size)
        return t
    }
    func rgb(_ t: CairoImageTarget, _ x: Int, _ y: Int) -> [Int] { let p = t.pixel(x, y); return [Int(p.r), Int(p.g), Int(p.b)] }
    var stage: [Int] { let s = PlayerView.canvasSurface; return [Int((s.r * 255).rounded()), Int((s.g * 255).rounded()), Int((s.b * 255).rounded())] }
    /// Element `id`'s box in view px, snapped like the outline.
    func box(_ v: PlayerView, _ id: String) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let e = v.elements.first { $0.id == id }!
        let b = PlayerView.pixelAligned(v.viewElement(e, in: size).visibleRect, scale: 1)
        return (Int(b.x), Int(b.y), Int(b.maxX) - 1, Int(b.maxY) - 1)
    }

    /// The four corner pixels are inked exactly like the middle of the top edge (square, not rounded), the line is
    /// `width` px thick with nothing bleeding outside or past it (no half-pixel blur).
    func assertSquare(_ t: CairoImageTarget, _ b: (x0: Int, y0: Int, x1: Int, y1: Int), width: Int, outside: [Int]?,
                      corners: Bool = true, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let mid = b.x0 + 30, edge = rgb(t, mid, b.y0)   // clear of corner dots and midpoint knobs
        XCTAssertNotEqual(edge, stage, "\(what): top edge is drawn", file: file, line: line)
        for (x, y) in [(b.x0, b.y0), (b.x1, b.y0), (b.x0, b.y1), (b.x1, b.y1)] where corners {
            XCTAssertEqual(rgb(t, x, y), edge, "\(what): corner (\(x),\(y)) drawn square", file: file, line: line)
        }
        XCTAssertEqual(rgb(t, mid, b.y0 + width - 1), edge, "\(what): full-strength across its width", file: file, line: line)
        XCTAssertEqual(rgb(t, mid, b.y0 + width), stage, "\(what): stops sharply inside", file: file, line: line)
        if let o = outside { XCTAssertEqual(rgb(t, mid, b.y0 - 1), o, "\(what): no bleed outside", file: file, line: line) }
    }

    func testStageAndCropOutlinesAreSquare() {
        let v = makeView()
        let f = v.frameRect(in: size)
        let fb = (Int(f.x), Int(f.y), Int(f.maxX) - 1, Int(f.maxY) - 1)
        let bg = rgb(render(v), 2, Int(f.y) + 10)   // viewport surface beside the stage
        assertSquare(render(v), fb, width: 1, outside: bg, "stage frame")

        v.selection = "a"; v.cropActive = true
        let t = render(v), b = box(v, "a")
        assertSquare(t, b, width: 1, outside: nil, "crop frame")
        XCTAssertEqual(rgb(t, b.x0 - 1, b.y0 - 1), stage, "nothing rounds outside the crop corner")

        v.cropActive = false
        let s = render(v)
        // The 12px corner handle dots cover the very corners; the edge between them is a crisp 2px line and each
        // dot is centred on the square corner. The same box without handles (hover, group, flash) is checked below.
        assertSquare(s, b, width: 2, outside: stage, corners: false, "selection (edge)")
        for (x, y) in [(b.x0, b.y0), (b.x1, b.y0), (b.x0, b.y1), (b.x1, b.y1)] {
            XCTAssertEqual(rgb(s, x, y), [255, 255, 255], "handle dot sits on the square corner (\(x),\(y))")
        }
        // Cropped selection: same square outline.
        v.elements[0].crop = CropInsets(top: 10, right: 10, bottom: 10, left: 10)
        assertSquare(render(v), box(v, "a"), width: 2, outside: stage, corners: false, "cropped selection (edge)")
    }

    func testHoverGroupDropAndFlashOutlinesAreSquare() {
        let v = makeView()
        v.hoveredElement = "b"
        assertSquare(render(v), box(v, "b"), width: 2, outside: stage, "hover")

        v.hoveredElement = nil; v.selectedIds = ["a", "b"]
        let gb = PlayerView.pixelAligned(v.groupBounds(in: size)!, scale: 1)
        assertSquare(render(v), (Int(gb.x), Int(gb.y), Int(gb.maxX) - 1, Int(gb.maxY) - 1), width: 2, outside: stage, "group box")

        v.selectedIds = []; v.zOrderFlash = ("b", 100)
        assertSquare(render(v), box(v, "b"), width: 2, outside: stage, "z-order flash")

        v.zOrderFlash = nil; v.assetDropActive = true
        let f = v.frameRect(in: size)
        let t = render(v)
        let fb = (Int(f.x), Int(f.y), Int(f.maxX) - 1, Int(f.maxY) - 1)
        let edge = rgb(t, (fb.0 + fb.2) / 2, fb.1)
        for (x, y) in [(fb.0, fb.1), (fb.2, fb.1), (fb.0, fb.3), (fb.2, fb.3)] { XCTAssertEqual(rgb(t, x, y), edge, "drop target corner (\(x),\(y))") }
    }

    func testCropMaskIsSquareAndPixelAligned() {
        let t = CairoImageTarget(width: 100, height: 50)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 100, height: 50), CanvasColor(r: 0, g: 0, b: 0))
        let img = CanvasImage(width: 2, height: 1, rgba: [255, 255, 255, 255, 255, 255, 255, 255])
        let layer = PreviewLayer(clipId: "x", source: "/x", kind: .image, start: 0, end: 1, sourceIn: 0,
                                 box: CanvasRect(x: 0, y: 0, width: 200, height: 100), crop: CropInsets(top: 20.6, right: 30.2, bottom: 20.6, left: 30.2))
        PreviewPainter.draw(layer, image: img, on: t.canvas, frame: CanvasRect(x: 0, y: 0, width: 100, height: 50), scale: 0.5)
        // visible box in view px: x 15.1…84.9, y 10.3…39.7 → snapped 15…85, 10…40.
        func lum(_ x: Int, _ y: Int) -> Int { Int(t.pixel(x, y).r) }
        for (x, y) in [(15, 10), (84, 10), (15, 39), (84, 39)] { XCTAssertEqual(lum(x, y), 255, "mask corner (\(x),\(y)) square and full") }
        for (x, y) in [(14, 20), (85, 20), (50, 9), (50, 40)] { XCTAssertEqual(lum(x, y), 0, "nothing past the mask edge at (\(x),\(y))") }
    }
    #endif
}
