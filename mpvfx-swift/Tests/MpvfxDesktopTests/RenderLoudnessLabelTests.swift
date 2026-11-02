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
@testable import MpvfxDesktop

/// The loudness line a history row shows: the target, and the measured value when the export recorded one.
final class RenderLoudnessLabelTests: XCTestCase {
    func testLabelShowsTargetAndMeasured() {
        XCTAssertEqual(RenderQueueState.loudnessLabel(target: -23, measured: -23.1), "-23.0 LUFS target, measured -23.1")
    }

    func testLabelWithoutMeasurementShowsTargetOnly() {
        XCTAssertEqual(RenderQueueState.loudnessLabel(target: -23, measured: nil), "-23.0 LUFS target")
    }

    func testNoTargetHasNoLabel() {
        XCTAssertNil(RenderQueueState.loudnessLabel(target: nil, measured: -23.1))
    }
}
