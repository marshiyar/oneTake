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

/// Export output targets.
final class ExportOutputTargetsTests: XCTestCase {
    func testOffersCommonPresets() {
        let expected: [(String, Double, Double, String)] = [
            ("hd-720", 1280, 720, "16:9"), ("full-hd", 1920, 1080, "16:9"), ("qhd", 2560, 1440, "16:9"),
            ("uhd-4k", 3840, 2160, "16:9"), ("uhd-8k", 7680, 4320, "16:9"), ("vertical-full-hd", 1080, 1920, "9:16"),
            ("vertical-8k", 4320, 7680, "9:16"), ("square-full-hd", 1080, 1080, "1:1"), ("social-4-5", 1080, 1350, "4:5"),
            ("classic-4-3", 2880, 2160, "4:3"), ("cinema-21-9", 5120, 2160, "64:27")]
        for (k, w, h, r) in expected {
            let info = ExportResolutionPreset(rawValue: k)!.info
            XCTAssertEqual(info.width, w, k); XCTAssertEqual(info.height, h, k); XCTAssertEqual(info.ratio, r, k)
        }
    }
    func testCapsCustomOutputAt8KLongEdgeAnd4KShortEdge() {
        XCTAssertTrue(isValidExportOutputDimensions(dimsJSON(7680, 4320)))
        XCTAssertTrue(isValidExportOutputDimensions(dimsJSON(4320, 7680)))
        XCTAssertTrue(isValidExportOutputDimensions(dimsJSON(4320, 4320)))
        XCTAssertFalse(isValidExportOutputDimensions(dimsJSON(7682, 4320)))
        XCTAssertFalse(isValidExportOutputDimensions(dimsJSON(4322, 4322)))
    }
    func testRejectsUnusableCustomDimensions() {
        for (w, h) in [(0.0, 1080.0), (1920, -2), (1920.5, 1080), (1919, 1080), (.nan, 1080)] {
            XCTAssertFalse(isValidExportOutputDimensions(dimsJSON(w, h)), "\(w)x\(h)")
        }
    }
    func testLabelsExactAndCustomAspectRatios() {
        XCTAssertEqual(exportAspectRatioLabel(.init(width: 1920, height: 1080)), "16:9")
        XCTAssertEqual(exportAspectRatioLabel(.init(width: 1080, height: 1350)), "4:5")
        XCTAssertEqual(exportAspectRatioLabel(.init(width: 2048, height: 1080)), "256:135")
    }
    func testResolvesAutoFixedPresetsAndCustomDimensions() {
        let authored = ExportDimensions(width: 1920, height: 1080)
        XCTAssertEqual(resolveExportTargetDimensions(.scale(.auto), authored), authored)
        XCTAssertEqual(resolveExportTargetDimensions(.preset(.uhd8k), authored), .init(width: 7680, height: 4320))
        XCTAssertEqual(resolveExportTargetDimensions(.custom, authored, .init(width: 2048, height: 1080)), .init(width: 2048, height: 1080))
        XCTAssertNil(resolveExportTargetDimensions(.custom, authored, .init(width: 7682, height: 4320)))
    }
}
