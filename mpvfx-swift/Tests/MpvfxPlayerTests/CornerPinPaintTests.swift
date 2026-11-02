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
import OneTakeKeyframes

/// Corner-pin distort (#451): preview and export draw one perspective mapping through the one painter.
final class CornerPinPaintTests: XCTestCase {
    private func pixel(_ img: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * img.width + x) * 4
        return Array(img.rgba[i..<i + 4])
    }

    /// Top half blue, bottom half yellow, 200x100 so it fills the canvas box one to one.
    private func split() -> CanvasImage {
        var px: [UInt8] = []
        for y in 0..<100 { for _ in 0..<200 { px += y < 50 ? [0, 0, 255, 255] : [255, 255, 0, 255] } }
        return CanvasImage(width: 200, height: 100, rgba: px)
    }

    private func isRed(_ p: [UInt8]) -> Bool { p[0] > 240 && p[1] < 15 && p[2] < 15 }
    private func isYellow(_ p: [UInt8]) -> Bool { p[0] > 240 && p[1] > 240 && p[2] < 15 }

    /// The layer below: red over the whole canvas box.
    private func red() -> CanvasImage { PreviewCompositorTests.solid(255, 0, 0, w: 200, h: 100) }

    private let trapezoid = #","corners":{"tl":{"x":0.25,"y":0},"tr":{"x":-0.25,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}}"#

    private func export(_ clipB: String, tracks: String = "", engine: KeyframeEngine? = nil, time: Double = 0.2) throws -> (CanvasImage, PreviewComposition) {
        let doc = try PreviewCompositorTests.document(clipB: clipB, bTracks: tracks, engine: engine)
        let comp = PreviewCompositorTests.composition(doc, engine: engine)
        let painter = try ExportFramePainter(composition: comp, width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
        let img = try painter.paint(time: time) { layer, _, _, _ in
            layer.clipId == "B" ? self.split() : self.red()
        }
        return (img, comp)
    }

    func testCornerPlacementOfTheDrawnQuad() throws {
        let (img, _) = try export(trapezoid)
        // Top edge runs from x = 50 to x = 150; the bottom edge keeps the full width.
        XCTAssertGreaterThan(pixel(img, 100, 6)[2], 240, "inside the quad near the top: the picture (blue)")
        XCTAssertTrue(isRed(pixel(img, 20, 6)), "left of the pinned top-left corner: the layer below")
        XCTAssertTrue(isRed(pixel(img, 180, 6)), "right of the pinned top-right corner: the layer below")
        XCTAssertTrue(isYellow(pixel(img, 4, 95)), "the bottom-left corner stayed at the box corner")
        XCTAssertTrue(isYellow(pixel(img, 195, 95)), "the bottom-right corner stayed at the box corner")
        // The slanted left edge at y = 50 is x = 25.
        XCTAssertGreaterThan(pixel(img, 30, 50)[1], 240, "just inside the slanted edge at mid height")
        XCTAssertTrue(isRed(pixel(img, 20, 50)), "just outside the slanted edge at mid height")
    }

    func testPictureFollowsThePerspectiveMapping() throws {
        let (img, _) = try export(trapezoid)
        let pin = try XCTUnwrap(NativeClipCorners(tl: .init(x: 0.25), tr: .init(x: -0.25)).pin)
        // The picture's half-way line lands where the homography puts it, not at the middle of the box.
        let mid = pin.map(0.5, 0.5).y * 100
        XCTAssertGreaterThan(abs(mid - 50), 2, "a trapezoid is foreshortened, not an affine skew")
        XCTAssertGreaterThan(pixel(img, 100, Int(mid) - 4)[2], 240, "above the mapped half-way line: blue")
        XCTAssertGreaterThan(pixel(img, 100, Int(mid) + 4)[1], 240, "below the mapped half-way line: yellow")
    }

    func testPreviewAndExportDrawTheSamePixels() throws {
        let (exported, comp) = try export(trapezoid)
        // The preview path: the compositor's layers drawn by the painter on a raster canvas.
        let canvas = try RasterCanvas(width: 200, height: 100)
        canvas.clear(CanvasColor(r: 0x10 / 255, g: 0x20 / 255, b: 0x30 / 255))
        let frame = CanvasRect(x: 0, y: 0, width: 200, height: 100)
        for layer in comp.layers(at: 0.2) {
            PreviewPainter.draw(layer, image: layer.clipId == "B" ? split() : self.red(),
                                on: canvas, frame: frame, scale: 1)
        }
        XCTAssertEqual(canvas.image().rgba, exported.rgba, "the same layers through the same painter are byte-identical")
    }

    func testNoCornersDrawsExactlyAsBefore() throws {
        let (plain, comp) = try export("")
        XCTAssertNil(try XCTUnwrap(comp.layers(at: 0.2).first { $0.clipId == "B" }).corners)
        let (zero, _) = try export(#","corners":{"tl":{"x":0,"y":0},"tr":{"x":0,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}}"#)
        XCTAssertEqual(plain.rgba, zero.rgba, "all-zero corners are the plain box")
    }

    func testKeyframedCornersMoveWithTheFrame() throws {
        let track = #"{"schemaVersion":1,"id":"k","parameterId":"corners.tl.x","valueType":"number","frameRate":{"numerator":10,"denominator":1},"keyframes":[{"id":"k0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"k1","frame":10,"value":0.5,"outgoing":{"type":"linear"}}]}"#
        let engine = try KeyframeRuntime()
        let doc = try PreviewCompositorTests.document(clipB: "", bTracks: track, engine: engine)
        let comp = PreviewCompositorTests.composition(doc, engine: engine)
        let start = try XCTUnwrap(comp.layers(at: 0).first { $0.clipId == "B" })
        XCTAssertNil(start.corners, "no offset at the first key")
        let half = try XCTUnwrap(comp.layers(at: 0.5).first { $0.clipId == "B" })
        XCTAssertEqual(try XCTUnwrap(half.corners).tl.x, 0.25, accuracy: 1e-6)
        let (img, _) = try export("", tracks: track, engine: engine, time: 1.6)   // past the last key (frame 10): tl.x holds 0.5; the image clip has ended
        XCTAssertTrue(isRed(pixel(img, 60, 2)), "the top-left corner has moved to x = 100: the layer below shows at the top left")
        XCTAssertGreaterThan(pixel(img, 190, 2)[2], 240)
    }
}
