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
@testable import MpvfxColor
import MpvfxShared

/// The grade renders the curve `GradeCurve` evaluates (the curve the inspector graph draws), however the curve
/// reaches it.
final class CurveRenderingTests: XCTestCase {
    func params(_ s: String) throws -> ColorGradeParams {
        let v = try JSONDecoder().decode(NativeJSONValue.self, from: Data(s.utf8))
        guard case .object(let o) = v else { XCTFail("not an object: \(s)"); return ColorGradeParams() }
        return try XCTUnwrap(ColorGradeParams(json: o))
    }

    func graded(_ p: ColorGradeParams, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        ColorGradeRenderer(params: p, seedKey: "curves").gradeColor(rgb)
    }

    /// `curves` and `hueCurves` are public: a curve set on them directly, not normalized, renders as the same curve
    /// read from `project.json`. A curve the compiler rejected (no end points here) used to grade its channel black.
    func testCurvesSetDirectlyRenderAsTheGraphDraws() throws {
        let inward: [[Double]] = [[0.2, 0.9], [0.8, 0.1]]
        let wrapped: [[Double]] = [[0, -1], [120, -1], [400, -1]]   // 400 degrees is 40
        var direct = ColorGradeParams()
        direct.curves["red"] = inward
        direct.hueCurves["hueVsSaturation"] = wrapped
        let read = try params(#"{"curves":{"red":[[0.2,0.9],[0.8,0.1]]},"hueCurves":{"hueVsSaturation":[[0,-1],[120,-1],[400,-1]]}}"#)
        for c in [SIMD3<Float>(0.5, 0.3, 0.2), SIMD3(0.1, 0.8, 0.4), SIMD3(0.9, 0.9, 0.1)] {
            XCTAssertEqual(graded(direct, c), graded(read, c), "\(c)")
        }
        XCTAssertGreaterThan(graded(direct, SIMD3(0.5, 0.5, 0.5)).x, 0.3, "the red curve at 0.5 is about 0.5, not black")
    }

    /// Every grey level through a master curve lands within one 8-bit level of `GradeCurve`'s value: the 1024-entry
    /// table, its 8-bit texels and the shader's linear read keep the curve the graph draws.
    func testMasterCurveRendersTheEvaluatedCurve() throws {
        let raw: [[Double]] = [[0, 0], [0.58, 0], [0.62, 0.65], [1, 1]]
        let p = try params(#"{"curves":{"master":[[0,0],[0.58,0],[0.62,0.65],[1,1]]}}"#)
        let r = ColorGradeRenderer(params: p, seedKey: "curves")
        // The steep segment (0.58…0.62 rises 0.65) moves about 4 levels per input level, so the table's linear read
        // can differ from the cubic there by a few levels; elsewhere within one level.
        let worst = (0...255).map { v -> (Double, Double) in
            let x = Double(v) / 255, out = Double(r.gradeColor(SIMD3(repeating: Float(x))).x)
            let steep = x > 0.57 && x < 0.63
            return (abs(out - GradeCurve.valueRGB(GradeCurve.normalizedRGB(raw), at: x)) * 255, steep ? 5 : 1.01)
        }
        XCTAssertEqual(worst.filter { $0.0 > $0.1 }.map(\.0), [])
    }

    /// The compiled table is the evaluator sampled at 1024 inputs, stored as Float32.
    func testTableIsTheEvaluatorSampled() throws {
        let pts: [[Double]] = [[0, 0.05], [0.3, 0.2], [0.7, 0.85], [1, 0.95]]
        let table = try XCTUnwrap(ColorCurves.compile(pts))
        XCTAssertEqual(table.count, ColorCurves.lutSize)
        for i in stride(from: 0, to: table.count, by: 31) {
            XCTAssertEqual(table[i], Double(Float(GradeCurve.valueRGB(pts, at: Double(i) / 1023))), "entry \(i)")
        }
    }
}
