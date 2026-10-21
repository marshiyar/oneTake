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
import Foundation
import XCTest
@testable import MpvfxShared

/// `GradeCurve`, the one grade-curve evaluator: hand-derived values of its cubic Hermite with Fritsch–Butland
/// tangents, and the properties every curve keeps (no overshoot, monotone between points, end points pinned,
/// through every point, periodic hue curves continuous across 0°/360°).
final class GradeCurveTests: XCTestCase {
    /// Values worked out by hand from the Hermite basis h00 = 2u³−3u²+1, h10 = u³−2u²+u, h01 = −2u³+3u², h11 = u³−u²
    /// (at u = 0.5: 0.5, 0.125, 0.5, −0.125) and the tangents' formulas (comments give each step).
    func testHandDerivedValues() {
        // Two points: both tangents are the segment's slope 0.6, so the cubic is the line.
        let line = GradeCurve.normalizedRGB([[0, 0.2], [1, 0.8]])
        XCTAssertEqual(GradeCurve.valueRGB(line, at: 0.25), 0.35, accuracy: 1e-12)
        XCTAssertEqual(GradeCurve.valueRGB(line, at: 0.75), 0.65, accuracy: 1e-12)
        // (0,0) (0.5,1) (1,1): slopes 2 and 0. Start tangent ((2·0.5+0.5)·2 − 0.5·0)/1 = 3 (not limited: 3 ≤ 3·2);
        // the interior tangent is 0 (a flat neighbour); the end tangent ((1.5)·0 − 0.5·2)/1 = −1 has the wrong sign: 0.
        // At 0.25 (u 0.5 of the first span 0.5): 0.125·0.5·3 + 0.5·1 = 0.6875; the second segment is flat at 1.
        let knee: [[Double]] = [[0, 0], [0.5, 1], [1, 1]]
        XCTAssertEqual(GradeCurve.tangents(knee), [3, 0, 0])
        XCTAssertEqual(GradeCurve.valueRGB(knee, at: 0.25), 0.6875, accuracy: 1e-12)
        XCTAssertEqual(GradeCurve.valueRGB(knee, at: 0.75), 1, accuracy: 1e-12)
        // Interior tangent, a weighted harmonic mean: spans 0.25 and 0.75, slopes 2 and 2/3; weights 2·0.75+0.25 =
        // 1.75 and 0.75+2·0.25 = 1.25; (1.75+1.25)/(1.75/2 + 1.25/(2/3)) = 3/2.75 = 12/11.
        XCTAssertEqual(GradeCurve.tangents([[0, 0], [0.25, 0.5], [1, 1]])[1], 12.0 / 11.0, accuracy: 1e-12)
        // Points on the diagonal give the identity everywhere.
        let diagonal: [[Double]] = [[0, 0], [0.3, 0.3], [0.5, 0.5], [1, 1]]
        for k in 0...20 { XCTAssertEqual(GradeCurve.valueRGB(diagonal, at: Double(k) / 20), Double(k) / 20, accuracy: 1e-12) }
    }

    /// The shapes the renderer accepts: 2…16 points after the end points are added; a shared input, a non-finite
    /// value or too many points render the identity.
    func testNormalizationLimits() {
        XCTAssertEqual(GradeCurve.normalizedRGB([[0.5, 0.5]]), GradeCurve.identity)
        XCTAssertEqual(GradeCurve.normalizedRGB([[0, 0], [0.5, 0.2], [0.5, 0.8], [1, 1]]), GradeCurve.identity)
        XCTAssertEqual(GradeCurve.normalizedRGB([[0, 0], [Double.nan, 0.2], [1, 1]]), GradeCurve.identity)
        let sixteen = (0..<16).map { [Double($0) / 15, 0.5] }
        XCTAssertEqual(GradeCurve.normalizedRGB(sixteen), sixteen)
        let inside = (1...15).map { [Double($0) / 16, 0.5] }   // 15 points + both ends = 17
        XCTAssertEqual(GradeCurve.normalizedRGB(inside), GradeCurve.identity)
        XCTAssertEqual(GradeCurve.normalizedHue([[0, 0.1], [120, 0.2]], limit: -1...1), [])
        XCTAssertEqual(GradeCurve.normalizedHue([[0, 0.1], [360, 0.2], [120, 0]], limit: -1...1), [], "360 wraps onto 0")
    }

    /// Random curves (2…16 points anywhere around the range, outputs past it too): the curve stays in 0…1, passes
    /// through every normalized point, holds its end points, and between two neighbours is monotone and stays
    /// between their outputs (no overshoot).
    func testRandomRgbCurvesNeverOvershoot() {
        var rng = SeededRandom(7)
        for _ in 0..<400 {
            let raw = (0..<(2 + rng.int(15))).map { _ in [rng.next() * 1.4 - 0.2, rng.next() * 1.4 - 0.2] }
            let pts = GradeCurve.normalizedRGB(raw)
            guard pts != GradeCurve.identity || raw.count < 3 else { continue }
            for p in pts { XCTAssertEqual(GradeCurve.valueRGB(pts, at: p[0]), p[1], accuracy: 1e-9, "\(pts) at \(p)") }
            XCTAssertEqual(GradeCurve.valueRGB(pts, at: -0.5), pts[0][1], accuracy: 1e-12, "held below 0")
            XCTAssertEqual(GradeCurve.valueRGB(pts, at: 1.5), pts[pts.count - 1][1], accuracy: 1e-12, "held above 1")
            for (a, b) in zip(pts, pts.dropFirst()) {
                let v = (0...64).map { GradeCurve.valueRGB(pts, at: a[0] + (b[0] - a[0]) * Double($0) / 64) }
                let lo = min(a[1], b[1]) - 1e-9, hi = max(a[1], b[1]) + 1e-9
                XCTAssertTrue(v.allSatisfy { $0 >= lo && $0 <= hi }, "overshoot between \(a) and \(b) in \(pts)")
                let up = b[1] >= a[1]
                XCTAssertTrue(zip(v, v.dropFirst()).allSatisfy { up ? $1 >= $0 - 1e-12 : $1 <= $0 + 1e-12 }, "not monotone between \(a) and \(b)")
            }
        }
    }

    /// A wrapped hue is a fixed point of the wrap once it is in [0, 360): what an editor stores, the renderer keeps.
    func testWrappedHueIsAFixedPoint() {
        var rng = SeededRandom(3)
        for _ in 0..<5000 {
            let h = (rng.next() * 1440 - 720) * 1000
            let once = GradeCurve.wrapHue(h.rounded() / 1000), twice = GradeCurve.wrapHue(once)
            XCTAssertTrue((0..<360).contains(once), "\(h)")
            XCTAssertEqual(GradeCurve.wrapHue(twice), twice, "\(h)")
            if once >= 0 && h >= 0 { XCTAssertEqual(twice, once, "\(h)") }
        }
    }

    /// Random hue curves: in range, through every point, and continuous across 0°/360° (the periodic copy).
    func testRandomHueCurvesArePeriodicAndBounded() {
        var rng = SeededRandom(11)
        for _ in 0..<300 {
            let raw = (0..<(3 + rng.int(14))).map { _ in [rng.next() * 720 - 180, rng.next() * 3 - 1.5] }
            let pts = GradeCurve.normalizedHue(raw, limit: -1...1)
            guard !pts.isEmpty else { continue }
            for p in pts { XCTAssertEqual(GradeCurve.valueHue(pts, at: p[0], limit: -1...1), p[1], accuracy: 1e-9) }
            let v = (0..<720).map { GradeCurve.valueHue(pts, at: Double($0) / 2, limit: -1...1) }
            XCTAssertTrue(v.allSatisfy { (-1...1).contains($0) }, "\(pts)")
            let across = abs(GradeCurve.valueHue(pts, at: 0, limit: -1...1) - GradeCurve.valueHue(pts, at: 359.9999, limit: -1...1))
            XCTAssertLessThan(across, 1e-3, "continuous across 0/360: \(pts)")
        }
    }
}

/// A small deterministic generator (64-bit LCG), so every run checks the same curves.
struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func int(_ n: Int) -> Int { min(n - 1, Int(next() * Double(n))) }
}
