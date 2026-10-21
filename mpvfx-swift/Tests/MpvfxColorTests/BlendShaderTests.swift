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
import CMpvfxColorShared
import MpvfxShared
@testable import MpvfxColor

/// The CPU reference of the clip blend modes (`BlendShader`) against hand-computed values, and its agreement with
/// the shading body's mode numbers.
final class BlendShaderTests: XCTestCase {
    func testTheSeparableFunctionsMatchTheirDefinitions() {
        let cb: Float = 0.4, cs: Float = 0.7
        XCTAssertEqual(BlendShader.channel(.normal, cb, cs), cs)
        XCTAssertEqual(BlendShader.channel(.multiply, cb, cs), 0.28, accuracy: 1e-6)
        XCTAssertEqual(BlendShader.channel(.screen, cb, cs), 0.82, accuracy: 1e-6)
        XCTAssertEqual(BlendShader.channel(.add, cb, cs), 1, "the sum is clamped")
        XCTAssertEqual(BlendShader.channel(.add, 0.2, 0.3), 0.5, accuracy: 1e-6)
        XCTAssertEqual(BlendShader.channel(.darken, cb, cs), cb)
        XCTAssertEqual(BlendShader.channel(.lighten, cb, cs), cs)
        // Overlay is hard light with the layers swapped: multiply below the backdrop's midpoint, screen above it.
        XCTAssertEqual(BlendShader.channel(.overlay, 0.25, 0.6), 0.3, accuracy: 1e-6)
        XCTAssertEqual(BlendShader.channel(.overlay, 0.75, 0.6), 0.8, accuracy: 1e-6)
        // Soft light: darkens for a source under 0.5, lifts above it, and leaves a mid-grey source unchanged.
        XCTAssertEqual(BlendShader.channel(.softLight, 0.5, 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(BlendShader.channel(.softLight, 0.4, 0.3), 0.4 - 0.4 * 0.4 * 0.6, accuracy: 1e-6)
        XCTAssertEqual(BlendShader.channel(.softLight, 0.16, 0.9), 0.16 + 0.8 * (((16 * 0.16 - 12) * 0.16 + 4) * 0.16 - 0.16), accuracy: 1e-5)
        XCTAssertEqual(BlendShader.channel(.softLight, 0.49, 0.9), 0.49 + 0.8 * (Float(0.49).squareRoot() - 0.49), accuracy: 1e-5)
    }

    func testCompositingFollowsTheAlphaOfBothPictures() {
        let red = SIMD4<Float>(1, 0, 0, 1), half = SIMD4<Float>(0, 0, 1, 0.5)
        XCTAssertEqual(BlendShader.composite(.normal, backdrop: red, source: half), SIMD4<Float>(0.5, 0, 0.5, 1))
        XCTAssertEqual(BlendShader.composite(.multiply, backdrop: red, source: half), SIMD4<Float>(0.5, 0, 0, 1),
                       "multiplying red by blue is black, half covered")
        let clear = SIMD4<Float>(0, 0, 0, 0)
        XCTAssertEqual(BlendShader.composite(.multiply, backdrop: clear, source: half), half, "no backdrop: the source as it is")
        XCTAssertEqual(BlendShader.composite(.screen, backdrop: red, source: clear), red, "no source: the backdrop")
        XCTAssertEqual(BlendShader.composite(.screen, backdrop: clear, source: clear), clear)
    }

    func testPicturesBlendPixelByPixelAndSizesMustMatch() throws {
        let a: [UInt8] = [200, 100, 50, 255, 0, 0, 0, 0], b: [UInt8] = [128, 64, 250, 255, 10, 20, 30, 255]
        let out = try XCTUnwrap(BlendShader.blend(b, over: a, width: 2, height: 1, mode: .multiply))
        XCTAssertEqual(Array(out[0..<4]), [100, 25, 49, 255], "128/255 of 200, 64/255 of 100, 250/255 of 50")
        XCTAssertEqual(Array(out[4..<8]), [10, 20, 30, 255], "over nothing the source stays")
        XCTAssertNil(BlendShader.blend(b, over: a, width: 1, height: 1, mode: .multiply))
        XCTAssertNil(BlendShader.blend([], over: [], width: 0, height: 0, mode: .screen))
    }

    // The GPU body takes the mode as an index; it must be the case order of NativeBlendMode.
    func testModeNumbersMatchTheSharedHeader() {
        XCTAssertEqual(Int(BLEND_COUNT.rawValue), NativeBlendMode.allCases.count)
        XCTAssertEqual(Int(BLEND_normal.rawValue), NativeBlendMode.normal.index)
        XCTAssertEqual(Int(BLEND_multiply.rawValue), NativeBlendMode.multiply.index)
        XCTAssertEqual(Int(BLEND_screen.rawValue), NativeBlendMode.screen.index)
        XCTAssertEqual(Int(BLEND_overlay.rawValue), NativeBlendMode.overlay.index)
        XCTAssertEqual(Int(BLEND_add.rawValue), NativeBlendMode.add.index)
        XCTAssertEqual(Int(BLEND_softLight.rawValue), NativeBlendMode.softLight.index)
        XCTAssertEqual(Int(BLEND_darken.rawValue), NativeBlendMode.darken.index)
        XCTAssertEqual(Int(BLEND_lighten.rawValue), NativeBlendMode.lighten.index)
    }
}
