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

/// Export output dimensions.
final class ExportDimensionsTests: XCTestCase {
    func testClassifiesAspect() {
        XCTAssertEqual(compositionAspect(.init(width: 1920, height: 1080)), .landscape)
        XCTAssertEqual(compositionAspect(.init(width: 1080, height: 1920)), .portrait)
        XCTAssertEqual(compositionAspect(.init(width: 1080, height: 1080)), .square)
    }
    func testRejectsInvalidDimensions() {
        for (w, h) in [(0.0, 1080.0), (-1, 1080), (1920.5, 1080), (.nan, 1080), (1920, .infinity)] {
            XCTAssertFalse(isValidExportDimensions(dimsJSON(w, h)), "\(w)x\(h)")
        }
    }
    func testResolvesPresetAndNativeOutputDimensions() {
        XCTAssertEqual(resolveExportDimensions(.mp4, .k4, .init(width: 1920, height: 1080)), .init(width: 3840, height: 2160))
        XCTAssertEqual(resolveExportDimensions(.webm, .k4, .init(width: 1919, height: 1079)), .init(width: 1919, height: 1079))
    }
    func testPadsH264RejectsOddWebMAndLeavesMovUnchanged() {
        XCTAssertEqual(resolveEncodedDimensions(.mp4, .init(width: 1919, height: 1079)), .init(width: 1920, height: 1080))
        XCTAssertNil(resolveEncodedDimensions(.webm, .init(width: 1919, height: 1079)))
        XCTAssertEqual(resolveEncodedDimensions(.mov, .init(width: 1919, height: 1079)), .init(width: 1919, height: 1079))
    }
}
