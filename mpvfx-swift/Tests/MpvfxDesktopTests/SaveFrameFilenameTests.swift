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
import MpvfxShared
import XCTest

@testable import MpvfxDesktop

internal final class SaveFrameFilenameTests: XCTestCase {
    internal func testNTSCFractionalFrameRateUsesRationalDivision() {
        let rate: RationalFrameRate = RationalFrameRate(numerator: 30_000, denominator: 1_001)
        XCTAssertEqual(EditorSession.saveFrameTimecode(1, frameRate: rate), "00-00-01-00")
        XCTAssertEqual(EditorSession.saveFrameTimecode(0.97, frameRate: rate), "00-00-00-29")
    }

    internal func testIntegerFrameRateRetainsExistingFilenameTimecode() {
        let rate: RationalFrameRate = RationalFrameRate(numerator: 30, denominator: 1)
        XCTAssertEqual(EditorSession.saveFrameTimecode(1.5, frameRate: rate), "00-00-01-15")
    }
}
