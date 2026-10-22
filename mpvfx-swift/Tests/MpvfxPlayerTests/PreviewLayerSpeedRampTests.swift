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
import MpvfxShared
@testable import MpvfxPlayer

/// The source frame a ramped layer shows: export asks `sourceTime(at:)` for every output frame.
final class PreviewLayerSpeedRampTests: XCTestCase {
    private func layer(rate: Double = 1, ramp: NativeSpeedRamp? = nil) -> PreviewLayer {
        var l = PreviewLayer(clipId: "c", source: "/x.mov", kind: .video, start: 2, end: 12, sourceIn: 5, rate: rate,
                             box: CanvasRect(x: 0, y: 0, width: 10, height: 10))
        l.speedRamp = ramp; l.timelineFPS = 30
        return l
    }

    func testConstantTwoXRampShowsTheSameSourceFramesAsPlaybackRateTwo() {
        let ramped = layer(ramp: NativeSpeedRamp(points: [.init(t: 0, speed: 2)])), plain = layer(rate: 2)
        for frame in 0..<300 {
            let t = 2 + Double(frame) / 30
            XCTAssertEqual(ramped.sourceTime(at: t), plain.sourceTime(at: t), accuracy: 1e-9, "frame \(frame)")
        }
    }

    func testRampedLayerListsTheSourceFramesOfItsTimeMap() {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 30, speed: 3)])
        let l = layer(ramp: ramp)
        for frame in [0, 1, 15, 30, 45, 90] {
            let expected = 5 + ramp.sourcePosition(atClipFrame: Double(frame)) / 30
            XCTAssertEqual(l.sourceTime(at: 2 + Double(frame) / 30), expected, accuracy: 1e-9)
        }
    }
}
