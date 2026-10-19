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
@testable import MpvfxShared

/// Export resolution choices and presets.
final class ExportResolutionTests: XCTestCase {
    func testResolvesMp4Scales() {
        let cases: [(ExportScale, Double, Double, String)] = [
            (.p1080, 1920, 1080, "landscape"), (.k4, 1920, 1080, "landscape-4k"), (.p1080, 1080, 1920, "portrait"),
            (.k4, 1080, 1920, "portrait-4k"), (.p1080, 1080, 1080, "square"), (.k4, 1080, 1080, "square-4k")]
        for (s, w, h, r) in cases { XCTAssertEqual(resolveExportResolution(.mp4, s, .init(width: w, height: h)).rawValue, r) }
    }
    func testKeepsAutoAtAuthoredDimensions() {
        XCTAssertEqual(resolveExportResolution(.mp4, .auto, .init(width: 1440, height: 1080)), .auto)
    }
    func testForcesAlphaFormatsToNativeResolution() {
        for f in [ExportFormat.webm, .mov] {
            XCTAssertEqual(normalizeExportScaleForFormat(f, .k4), .auto)
            XCTAssertEqual(resolveExportResolution(f, .k4, .init(width: 1920, height: 1080)), .auto)
            XCTAssertFalse(exportScaleApplies(f, .k4, .init(width: 1920, height: 1080)))
        }
    }
    func testRejectsNonIntegerOrDownsampleScale() {
        for (w, h, s) in [(1280.0, 720.0, ExportScale.p1080), (3840, 2160, .p1080), (1000, 1000, .k4)] {
            XCTAssertFalse(exportScaleApplies(.mp4, s, .init(width: w, height: h)), "\(w)x\(h) \(s)")
        }
    }
}
