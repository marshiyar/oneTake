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

/// Export frame rates.
final class ExportFrameRateTests: XCTestCase {
    func testSupportsTheFrameRatesExposedByTheEditor() { XCTAssertEqual(SUPPORTED_EXPORT_FRAME_RATES, [24, 30, 60]) }
    func testTurnsDurationIntoFrames() {
        let cases: [(Double, ExportFrameRate, Double)] = [(1, .fps24, 24), (1, .fps30, 30), (1, .fps60, 60), (1.001, .fps30, 31), (1.00001, .fps30, 30)]
        for (d, fps, n) in cases { XCTAssertEqual(exportFrameCount(d, fps), n, "\(d)@\(fps.rawValue)") }
    }
    func testReturnsZeroFramesForInvalidDuration() {
        for d in [0, -1, Double.nan, .infinity] { XCTAssertEqual(exportFrameCount(d, .fps30), 0) }
    }
}
