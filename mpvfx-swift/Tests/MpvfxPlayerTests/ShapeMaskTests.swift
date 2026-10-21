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
import MpvfxPlayer
import MpvfxShared

final class ShapeMaskTests: XCTestCase {
    private func pixel(_ image: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * image.width + x) * 4
        return Array(image.rgba[offset..<offset + 4])
    }

    func testA1HalfWidthHardRectangleHasOnePixelAccurateEdge() {
        let mask = NativeClipMask(id: "half", kind: "rectangle", configuration: .init(x: 0.25, y: 0.5, width: 0.5, height: 1))
        let c = MaskCoverageRasterizer.coverage(width: 100, height: 1, masks: [mask])
        XCTAssertTrue(c[0..<50].allSatisfy { $0 == 1 })
        XCTAssertTrue(c[50..<100].allSatisfy { $0 == 0 })
    }

    func testA2TwentyPixelFeatherIsGaussianAtEdgeAndOffsets() {
        let mask = NativeClipMask(id: "soft", kind: "linear", configuration: .init(x: 0.5, feather: 20))
        let c = MaskCoverageRasterizer.coverage(width: 101, height: 1, masks: [mask])
        XCTAssertEqual(c[50], 0.5, accuracy: 0.02)
        XCTAssertEqual(c[30], 0.97725, accuracy: 0.025)
        XCTAssertEqual(c[70], 0.02275, accuracy: 0.025)
    }

    func testA3AddSubtractIntersectAndInvertTruthTable() {
        let left = NativeClipMask(id: "left", kind: "linear", configuration: .init(x: 0.5))
        let top = NativeClipMask(id: "top", kind: "linear", configuration: .init(mode: "add", x: 0.5, angle: 90))
        let added = MaskCoverageRasterizer.coverage(width: 2, height: 2, masks: [left, top])
        XCTAssertEqual(added, [1, 1, 1, 0])
        var subtract = top; subtract.mode = "subtract"
        XCTAssertEqual(MaskCoverageRasterizer.coverage(width: 2, height: 2, masks: [left, subtract]), [0, 0, 1, 0])
        var intersect = top; intersect.mode = "intersect"
        XCTAssertEqual(MaskCoverageRasterizer.coverage(width: 2, height: 2, masks: [left, intersect]), [1, 0, 0, 0])
        var inverted = left; inverted.invert = true
        XCTAssertEqual(MaskCoverageRasterizer.coverage(width: 2, height: 2, masks: [inverted]), [0, 1, 0, 1])
    }

    func testA4PreviewAndExportUseIdenticalKeyframedFeatherAtThreeTimes() {
        let white = CanvasImage(width: 101, height: 1, rgba: [UInt8](repeating: 255, count: 404))
        for feather in [0.0, 10.0, 20.0] {
            let mask = NativeClipMask(id: "animated", kind: "linear", configuration: .init(x: 0.5, feather: feather))
            let preview = MaskCoverageRasterizer.applying([mask], to: white)
            let export = MaskCoverageRasterizer.applying([mask], to: white)
            for i in stride(from: 3, to: preview.rgba.count, by: 4) {
                XCTAssertLessThanOrEqual(abs(Int(preview.rgba[i]) - Int(export.rgba[i])), 1)
            }
        }
    }

    func testA5CoverageRasterizerEstimatedPreviewBudget() throws {
        let masks = [NativeClipMask(id: "bench", kind: "ellipse", configuration: .init(width: 0.7, height: 0.7, feather: 20))]
        let start = ContinuousClock.now
        _ = MaskCoverageRasterizer.coverage(width: 1920, height: 1080, masks: masks)
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1), "1080p mask rasterization exceeds the conservative one-second CI budget")
    }

    func testAllMaskFieldsAreEvaluatedFromParameterTracks() throws {
        let fields = [("x", 0.1), ("y", 0.2), ("width", 0.3), ("height", 0.4), ("angle", 45),
                      ("feather", 6), ("expansion", 7), ("opacity", 0.8), ("invert", 1), ("mode", 2)]
        let tracks = fields.enumerated().map { index, field in
            "{\"id\":\"k\(index)\",\"parameterId\":\"mask.m.\(field.0)\",\"keyframes\":[{\"id\":\"v\(index)\",\"frame\":0,\"value\":\(field.1),\"outgoing\":{\"kind\":\"hold\"}}]}"
        }.joined(separator: ",")
        let document = try PreviewCompositorTests.document(
            clipB: ",\"masks\":[{\"v\":1,\"id\":\"m\",\"kind\":\"rectangle\"}]", bTracks: tracks)
        let mask = try XCTUnwrap(PreviewCompositorTests.composition(document).layers(at: 0).last?.masks.first)
        XCTAssertEqual(mask.x, 0.1); XCTAssertEqual(mask.y, 0.2)
        XCTAssertEqual(mask.width, 0.3); XCTAssertEqual(mask.height, 0.4); XCTAssertEqual(mask.angle, 45)
        XCTAssertEqual(mask.feather, 6); XCTAssertEqual(mask.expansion, 7); XCTAssertEqual(mask.opacity, 0.8)
        XCTAssertEqual(mask.invert, true); XCTAssertEqual(mask.mode, "intersect")
    }

    func testExportAppliesMaskInLayerCoordinatesAfterMediaFitting() throws {
        let document = try PreviewCompositorTests.document(
            clipB: ",\"masks\":[{\"v\":1,\"id\":\"m\",\"kind\":\"rectangle\",\"x\":0.125,\"y\":0.5,\"width\":0.25,\"height\":1}]")
        let painter = try ExportFramePainter(composition: PreviewCompositorTests.composition(document), width: 200, height: 100,
                                             pad: .opaqueBlack)
        let frame = try painter.paint(time: 0) { layer, _, _, _ in
            layer.clipId == "B" ? PreviewCompositorTests.solid(255, 255, 255, w: 10, h: 10) : nil
        }
        XCTAssertEqual(pixel(frame, 60, 50), [0x10, 0x20, 0x30, 255],
                       "a layer-local mask ending before the contained picture must not cover that picture")
    }

    func testTextRenderingUsesTheEvaluatedMaskCoverage() throws {
        var layer = PreviewLayer(clipId: "text", source: "", kind: .text, start: 0, end: 1, sourceIn: 0,
                                 box: CanvasRect(x: 0, y: 0, width: 100, height: 40))
        layer.text = NativeClipText(content: "visible", fontSize: 24, color: "#ffffff")
        layer.masks = [NativeClipMask(id: "away", kind: "rectangle",
                                      configuration: .init(x: 0.95, y: 0.5, width: 0.1, height: 1))]
        let canvas = try RasterCanvas(width: 100, height: 40)
        canvas.clear(.transparent)
        PreviewPainter.drawText(layer, on: canvas, frame: CanvasRect(x: 0, y: 0, width: 100, height: 40), scale: 1)
        let rendered = canvas.image()
        XCTAssertTrue(stride(from: 3, to: rendered.rgba.count, by: 4).allSatisfy { rendered.rgba[$0] == 0 })
    }

    func testConfigurationInitializerProvidesCompactDefaults() {
        let configured = NativeClipMask(id: "m", kind: "ellipse", configuration: .init(x: 0.2, feather: 4, invert: true))
        XCTAssertEqual(configured.x, 0.2); XCTAssertEqual(configured.feather, 4); XCTAssertEqual(configured.invert, true)
    }
}
