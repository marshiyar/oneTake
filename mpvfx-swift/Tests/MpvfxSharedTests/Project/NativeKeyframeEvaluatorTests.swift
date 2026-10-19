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
// Keyframe evaluator.
// Engine-valued cases live in Tests/MpvfxSharedEngineTests (EngineKeyframeEvaluatorTests).
import XCTest
@testable import MpvfxShared

final class NativeKeyframeEvaluatorTests: XCTestCase {
    func testRejectsFractionalEvaluationFrames() throws {
        let engine = KeyframeEngineStandIn()
        let track = try createNativeParameterTrack(.init(id: "track:integer-time", parameterId: "transform.rotation", valueType: .number,
            frameRate: .init(numerator: 30, denominator: 1),
            keyframes: [NativeKeyframe(id: "start", frame: 0, value: .number(0), outgoing: .linear)]), engine: engine)
        XCTAssertThrowsError(try evaluateNativeParameterTrack(track, projectFrame: 0.5, engine: engine)) {
            XCTAssertTrue("\($0)".lowercased().contains("integer project frame"))
        }
    }
}
