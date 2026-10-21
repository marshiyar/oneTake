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
    func testA1HalfWidthHardRectangleHasOnePixelAccurateEdge() {
        let mask = NativeClipMask(id: "half", kind: "rectangle", x: 0.25, y: 0.5, width: 0.5, height: 1)
        let c = MaskCoverageRasterizer.coverage(width: 100, height: 1, masks: [mask])
        XCTAssertTrue(c[0..<50].allSatisfy { $0 == 1 })
        XCTAssertTrue(c[50..<100].allSatisfy { $0 == 0 })
    }

    func testA2TwentyPixelFeatherIsGaussianAtEdgeAndOffsets() {
        let mask = NativeClipMask(id: "soft", kind: "linear", x: 0.5, feather: 20)
        let c = MaskCoverageRasterizer.coverage(width: 101, height: 1, masks: [mask])
        XCTAssertEqual(c[50], 0.5, accuracy: 0.02)
        XCTAssertEqual(c[30], 0.97725, accuracy: 0.025)
        XCTAssertEqual(c[70], 0.02275, accuracy: 0.025)
    }

    func testA3AddSubtractIntersectAndInvertTruthTable() {
        let left = NativeClipMask(id: "left", kind: "linear", x: 0.5)
        let top = NativeClipMask(id: "top", kind: "linear", mode: "add", x: 0.5, angle: 90)
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
            let mask = NativeClipMask(id: "animated", kind: "linear", x: 0.5, feather: feather)
            let preview = MaskCoverageRasterizer.applying([mask], to: white)
            let export = MaskCoverageRasterizer.applying([mask], to: white)
            for i in stride(from: 3, to: preview.rgba.count, by: 4) {
                XCTAssertLessThanOrEqual(abs(Int(preview.rgba[i]) - Int(export.rgba[i])), 1)
            }
        }
    }

    func testA5CoverageRasterizerEstimatedPreviewBudget() throws {
        let masks = [NativeClipMask(id: "bench", kind: "ellipse", width: 0.7, height: 0.7, feather: 20)]
        let start = ContinuousClock.now
        _ = MaskCoverageRasterizer.coverage(width: 1920, height: 1080, masks: masks)
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1), "1080p mask rasterization exceeds the conservative one-second CI budget")
    }
}
