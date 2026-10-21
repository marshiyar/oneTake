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
import MpvfxShared
import OneTakeKeyframes

/// The Easing panel draws its curves with `KeyframeEase`; these tests hold it to what the keyframe engine renders, so
/// the curve on screen is the motion in the preview and the export.
final class KeyframeEaseParityTests: XCTestCase {
    private func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> NativeInterpolation {
        .cubicBezier(CubicBezierControlPoints(x1: x1, y1: y1, x2: x2, y2: y2))
    }

    /// Curves the panel offers or a user can drag to: the presets, easy ease, overshoots both ways, a steep step.
    private var curves: [NativeInterpolation] {
        [.linear, .hold, cubic(0.42, 0, 1, 1), cubic(0, 0, 0.58, 1), cubic(0.42, 0, 0.58, 1), cubic(1.0 / 3, 0, 2.0 / 3, 1),
         cubic(0.34, 1.56, 0.64, 1), cubic(0.36, -0.6, 0.7, -0.4), cubic(0.9, 0, 0.1, 1), cubic(0, 2, 1, -1), cubic(0.001, 0, 0.999, 1)]
    }

    private func engineValues(_ e: KeyframeEngine, _ ease: NativeInterpolation, from a: Double, to b: Double, frames n: Double) throws -> [Double] {
        let track = KeyframeTrack(valueType: .number, keyframes: [
            .init(frame: 0, value: .number(a), outgoing: ease), .init(frame: n, value: .number(b), outgoing: .linear),
        ])
        return try e.sample(track, firstFrame: 0, count: Int(n) + 1)
    }

    func testProgressMatchesTheEngineOnEveryFrame() throws {
        let e = try KeyframeRuntime()
        for ease in curves {
            for (a, b, n) in [(0.0, 100.0, 100.0), (-350, 10, 120), (1, 0.5, 7)] {
                let values = try engineValues(e, ease, from: a, to: b, frames: n)
                for (f, v) in values.enumerated() {
                    let mine = a + (b - a) * KeyframeEase.progress(ease, at: Double(f) / n)
                    XCTAssertEqual(mine, v, accuracy: 1e-9 * max(1, abs(b - a)), "\(ease) frame \(f) of \(n)")
                }
            }
        }
    }

    func testTheRecordedEaseInGoldenHolds() throws {
        // The engine's recorded value (EngineBackedProjectTests.testCubicBezierTiming): ease-in, 0 → 100, frame 50.
        XCTAssertEqual(100 * KeyframeEase.progress(cubic(0.42, 0, 1, 1), at: 0.5), 31.5357, accuracy: 0.0005)
        let engineValue = try engineValues(KeyframeRuntime(), cubic(0.42, 0, 1, 1), from: 0, to: 100, frames: 100)[50]
        XCTAssertEqual(engineValue, 31.5357, accuracy: 0.0005)
    }

    func testSlopeIsTheEngineSpeed() throws {
        // Central differences of engine values over a long segment approach the analytic slope × the linear speed.
        let e = try KeyframeRuntime(), n = 3000.0
        for ease in curves where ease != .hold {
            let values = try engineValues(e, ease, from: 0, to: n, frames: n)
            for f in stride(from: 150, to: Int(n) - 150, by: 150) {
                let fd = (values[f + 1] - values[f - 1]) / 2
                XCTAssertEqual(KeyframeEase.slope(ease, at: Double(f) / n), fd, accuracy: 1e-3 * max(1, abs(fd)), "\(ease) frame \(f)")
            }
        }
    }
}
