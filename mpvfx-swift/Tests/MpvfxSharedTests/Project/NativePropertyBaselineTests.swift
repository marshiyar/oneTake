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
// Property baselines.
import XCTest
@testable import MpvfxShared

final class NativePropertyBaselineTests: XCTestCase {
    func close(_ v: Double?, _ e: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let v else { return XCTFail("missing", file: file, line: line) }
        XCTAssertEqual(v, e, accuracy: 0.5e-8, file: file, line: line)   // toBeCloseTo(e, 8)
    }
    func testDecomposesExistingCSSMatrix() {
        let rad = 25 * Double.pi / 180
        let t = "matrix(\(1.2 * cos(rad)), \(1.2 * sin(rad)), \(-0.8 * sin(rad)), \(0.8 * cos(rad)), 40, -12)"
        let r = readNativePropertyBaselines(.init(computedStyles: ["transform": t, "opacity": "0.65", "width": "640px", "height": "360px"],
                                                  boundingBox: (600, 320)))
        close(r["x"], 40); close(r["y"], -12); close(r["rotation"], 25); close(r["rotationZ"], 25)
        close(r["scaleX"], 1.2); close(r["scaleY"], 0.8); XCTAssertNil(r["scale"])
        close(r["opacity"], 0.65); close(r["autoAlpha"], 0.65)
        XCTAssertEqual(r["width"], 640); XCTAssertEqual(r["height"], 360)
    }
    func testIdentityAndUniformScale() {
        let r = readNativePropertyBaselines(.init(computedStyles: ["transform": "matrix(2, 0, 0, 2, 0, 0)"], boundingBox: (100, 50)))
        let expected: [String: Double] = ["x": 0, "y": 0, "rotation": 0, "scale": 2, "scaleX": 2, "scaleY": 2, "width": 100, "height": 50]
        for (k, v) in expected { XCTAssertEqual(r[k], v, k) }
    }
    func testMalformedStylesOmitted() {
        let r = readNativePropertyBaselines(.init(computedStyles: ["transform": "not-a-matrix", "opacity": "NaN", "width": "auto", "height": "0px"],
                                                  boundingBox: (320, 180)))
        XCTAssertEqual(r, ["width": 320, "height": 180])
    }
    func testIndividualTranslateRotateScale() {
        let r = readNativePropertyBaselines(.init(computedStyles: ["transform": "none", "translate": "12px -8px", "rotate": "25deg", "scale": "1.25 0.8"],
                                                  boundingBox: (640, 360)))
        let expected: [String: Double] = ["x": 12, "y": -8, "rotation": 25, "rotationZ": 25, "scaleX": 1.25, "scaleY": 0.8]
        for (k, v) in expected { XCTAssertEqual(r[k], v, k) }
    }
}
