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
import MpvfxCanvas
import MpvfxShared

/// Export frames are painted by the preview's composition and painter on the engine's raster canvas.
final class ExportFramePainterTests: XCTestCase {
    func pixel(_ img: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * img.width + x) * 4
        return Array(img.rgba[i..<i + 4])
    }

    func painter(_ w: Int, _ h: Int, pad: CanvasColor = CanvasColor(r: 0, g: 0, b: 0)) throws -> ExportFramePainter {
        try ExportFramePainter(composition: PreviewCompositorTests.composition(try PreviewCompositorTests.document()),
                               width: w, height: h, pad: pad)
    }

    func testTopLayerCoversTheCanvasAtTheOutputScale() throws {
        let p = try painter(400, 200)
        var asked: [(String, Double, Int, Int)] = []
        let img = try p.paint(time: 0.3) { layer, t, w, h in
            asked.append((layer.clipId, t, w, h))
            return layer.clipId == "B" ? PreviewCompositorTests.solid(0, 255, 0) : PreviewCompositorTests.solid(255, 0, 0)
        }
        XCTAssertEqual(img.width, 400); XCTAssertEqual(img.height, 200)
        XCTAssertEqual(pixel(img, 200, 100), [0, 255, 0, 255], "B (lane 2) is drawn over A (lane 1)")
        XCTAssertEqual(asked.map(\.0), ["A", "B"])
        let b = try XCTUnwrap(asked.last)
        XCTAssertEqual(b.1, 0.4 + 0.3, accuracy: 1e-9, "the provider is asked for the source time")
        XCTAssertEqual(b.2, 400); XCTAssertEqual(b.3, 200, "decode size is the drawn size in output pixels")
    }

    func testUndecodedLayersShowTheLayersBelowAndTheBackground() throws {
        let p = try painter(200, 100)
        let a = try p.paint(time: 0) { layer, _, _, _ in layer.clipId == "A" ? PreviewCompositorTests.solid(255, 0, 0) : nil }
        XCTAssertEqual(pixel(a, 100, 50), [255, 0, 0, 255])
        XCTAssertEqual(pixel(a, 10, 10), [0x10, 0x20, 0x30, 255], "the square picture is contained in the 2:1 box")
        let none = try p.paint(time: 0) { _, _, _, _ in nil }
        XCTAssertEqual(pixel(none, 10, 10), [0x10, 0x20, 0x30, 255], "the project background")
    }

    func testOtherAspectRatiosArePaddedAndCentred() throws {
        let p = try painter(200, 200, pad: CanvasColor(r: 0, g: 0, b: 0, a: 0))
        XCTAssertEqual(p.frame.rect, CanvasRect(x: 0, y: 50, width: 200, height: 100))
        let img = try p.paint(time: 0) { _, _, _, _ in PreviewCompositorTests.solid(255, 0, 0) }
        XCTAssertEqual(pixel(img, 100, 20), [0, 0, 0, 0], "transparent pad above the canvas")
        XCTAssertEqual(pixel(img, 100, 100), [255, 0, 0, 255])
        XCTAssertEqual(pixel(img, 100, 180), [0, 0, 0, 0])
    }

    /// When the project canvas covers the whole output, the opaque background is painted in one pass (issue #98): the
    /// frame is byte-identical to painting the pad and then the background over it, with and without layers on top.
    func testTheOnePassBackgroundPaintsTheSameBytesAsPadThenBackground() throws {
        let layers: [String: CanvasImage] = ["A": PreviewCompositorTests.solid(255, 0, 0, 90), "B": PreviewCompositorTests.solid(0, 0, 255, 128)]
        for (w, h) in [(400, 200), (64, 32), (1920, 960), (1000, 500)] {
            for pad in [CanvasColor(r: 0, g: 0, b: 0), CanvasColor.transparent] {
                let fast = try painter(w, h, pad: pad), reference = try painter(w, h, pad: pad)
                reference.singlePassBackground = false
                XCTAssertTrue(fast.fillsTheOutput(fast.frame.rect), "\(w)x\(h) takes the one-pass path")
                for provider in [{ (_: PreviewLayer) -> CanvasImage? in nil }, { layers[$0.clipId] }] {
                    let a = try fast.paint(time: 0) { layer, _, _, _ in provider(layer) }
                    let b = try reference.paint(time: 0) { layer, _, _, _ in provider(layer) }
                    XCTAssertTrue(a.rgba == b.rgba, "\(w)x\(h) pad \(pad): the frames differ")
                }
            }
        }
        let padded = try painter(200, 200)
        XCTAssertFalse(padded.fillsTheOutput(padded.frame.rect), "a 1:1 output of the 2:1 canvas shows the pad")
    }

    func testHalfTransparentLayerBlendsOverTheOneBelow() throws {
        let p = try painter(200, 100)
        let img = try p.paint(time: 0) { layer, _, _, _ in
            layer.clipId == "B" ? PreviewCompositorTests.solid(0, 0, 255, 128) : PreviewCompositorTests.solid(255, 0, 0)
        }
        let c = pixel(img, 100, 50)
        XCTAssertEqual(Int(c[0]), 127, accuracy: 1); XCTAssertEqual(Int(c[2]), 128, accuracy: 1); XCTAssertEqual(c[3], 255)
    }

    #if os(Linux) || os(Windows)   // text drawn by Cairo/Pango or DirectWrite
    func testRasterCanvasDrawsTextThroughItsTransform() throws {
        let c = try RasterCanvas(width: 120, height: 40)
        c.translate(10, 5)
        c.drawText("Hello", at: CanvasPoint(0, 0), font: CanvasFont(size: 20), color: CanvasColor(r: 1, g: 1, b: 1))
        let img = c.image()
        let ink = stride(from: 3, to: img.rgba.count, by: 4).filter { img.rgba[$0] > 128 }.count
        XCTAssertGreaterThan(ink, 40, "glyphs were drawn")
        XCTAssertEqual(pixel(img, 2, 2)[3], 0, "nothing left of the translated origin")
        XCTAssertEqual(c.measureText("Hello", font: CanvasFont(size: 20)).width, try TextBitmap.measure("Hello", font: CanvasFont(size: 20)).width)
    }
    #endif
}
