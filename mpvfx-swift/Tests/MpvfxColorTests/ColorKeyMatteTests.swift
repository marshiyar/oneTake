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
@testable import MpvfxColor

/// Issue #300 A1/A2: the matte view is what the key does to the picture (checked against the CPU reference shader pixel
/// by pixel), and the eyedropper's colour is the 5x5 average of the ungraded pixels.
final class ColorKeyMatteTests: XCTestCase {
    func testMatteEqualsTheAlphaTheReferenceShaderGivesForEveryPixel() {
        var params = ColorGradeParams()
        params.colorKey = .init(color: SIMD3(0.1, 0.8, 0.2), similarity: 0.06, smoothness: 0.2)
        var pixels: [UInt8] = []
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 51) { pixels += [UInt8(r), UInt8(g), UInt8(b), 255] }
            }
        }
        let count = pixels.count / 4
        let source = pixels
        ColorGradeRenderer(params: params).apply(&pixels, width: count, height: 1, time: 0)
        let matte = ColorKeyMatte.image(rgba: source, width: count, height: 1, key: params.colorKey!)
        var worst = 0
        for i in 0..<count {
            worst = max(worst, abs(Int(pixels[i * 4 + 3]) - Int(matte[i * 4])))
            XCTAssertEqual(matte[i * 4 + 1], matte[i * 4]); XCTAssertEqual(matte[i * 4 + 2], matte[i * 4]); XCTAssertEqual(matte[i * 4 + 3], 255)
        }
        XCTAssertLessThanOrEqual(worst, 2, "the Matte view and the keyed alpha differ by at most 2 levels")
    }

    func testTheMatteIsScaledBySourceAlphaAndIsBlackWhereKeyedOut() {
        let key = ColorGradeParams.ColorKey()
        let out = ColorKeyMatte.image(rgba: [0, 255, 0, 255, 200, 40, 40, 255, 200, 40, 40, 128], width: 3, height: 1, key: key)
        XCTAssertEqual(out[0], 0, "the key colour itself is keyed out")
        XCTAssertEqual(out[4], 255, "a red pixel is kept")
        XCTAssertEqual(out[8], 128, accuracy: 1, "half transparent: half white")
    }

    func testA1TheAverageIsTheFiveByFiveMeanOfAKnownFrameAndIgnoresTransparentPixels() {
        // 7 x 7: a 5 x 5 block of (50, 100, 150) with one pixel of (250, 100, 150) inside it, the rest transparent black.
        let w = 7, h = 7
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 1...5 { for x in 1...5 { let o = (y * w + x) * 4; px[o] = 50; px[o + 1] = 100; px[o + 2] = 150; px[o + 3] = 255 } }
        let o = (3 * w + 3) * 4; px[o] = 250
        let mean = ColorKeyMatte.average(rgba: px, width: w, height: h, x: 3, y: 3)
        let want = SIMD3(50.0 + 200.0 / 25, 100, 150) / 255
        XCTAssertEqual(try XCTUnwrap(mean).x, want.x, accuracy: 1e-9); XCTAssertEqual(try XCTUnwrap(mean).y, want.y, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(mean).z, want.z, accuracy: 1e-9)
        let corner = ColorKeyMatte.average(rgba: px, width: w, height: h, x: 0, y: 0)
        XCTAssertEqual(try XCTUnwrap(corner).x, 50.0 / 255, accuracy: 1e-9, "only the opaque pixels of the patch count")
        XCTAssertNil(ColorKeyMatte.average(rgba: [0, 0, 0, 0], width: 1, height: 1, x: 0, y: 0), "fully transparent: nothing to pick")
        XCTAssertNil(ColorKeyMatte.average(rgba: [], width: 0, height: 0, x: 0, y: 0))
    }
}
