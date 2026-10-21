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
import MpvfxShared

final class ColorKeyTests: XCTestCase {
    func testSyntheticFrameProducesDocumentedMatte() {
        var params = ColorGradeParams()
        params.colorKey = .init(similarity: 0.08, smoothness: 0.18)
        let renderer = ColorGradeRenderer(params: params)
        var pixels: [UInt8] = [0, 255, 0, 255, 128, 128, 128, 255, 64, 192, 64, 255]
        renderer.apply(&pixels, width: 3, height: 1, time: 0)
        XCTAssertEqual(pixels[3], 0)
        XCTAssertEqual(pixels[7], 255)

        func chroma(_ c: SIMD3<Double>) -> SIMD2<Double> {
            let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            return SIMD2((c.z - y) / 1.8556, (c.x - y) / 1.5748)
        }
        let edge = chroma(SIMD3(64.0 / 255, 192.0 / 255, 64.0 / 255))
        let key = chroma(SIMD3(0, 1, 0))
        let distance = ((edge.x - key.x) * (edge.x - key.x) + (edge.y - key.y) * (edge.y - key.y)).squareRoot()
        let t = min(1, max(0, (distance - 0.08) / 0.18))
        let expected = t * t * (3 - 2 * t)
        XCTAssertEqual(Double(pixels[11]) / 255, expected, accuracy: 0.02)
    }

    func testFullSpillRemovesGreenCastAndPreservesNeutral() {
        var params = ColorGradeParams()
        params.colorKey = .init(similarity: 0.02, smoothness: 0.5, spill: 1)
        let renderer = ColorGradeRenderer(params: params)
        var pixels: [UInt8] = [64, 192, 64, 255, 128, 128, 128, 255]
        renderer.apply(&pixels, width: 2, height: 1, time: 0)
        XCTAssertLessThanOrEqual(pixels[1], max(pixels[0], pixels[2]) + 2)
        XCTAssertEqual(Array(pixels[4..<7]), [128, 128, 128])
    }

    func testClipReadsOnlySupportedVersionAndKind() throws {
        func object(_ text: String) throws -> NativeJSONObject {
            let value = try JSONDecoder().decode(NativeJSONValue.self, from: Data(text.utf8))
            return try XCTUnwrap(value.objectValue)
        }
        var clip = NativeProjectClip.fresh(id: "c", assetId: "a", startFrame: 0, durationFrames: 1)
        clip.effects = [NativeClipEffect(id: "key", effectId: "color-key", enabled: true,
                                         parameters: try object("{\"v\":1,\"kind\":\"chroma\"}"))]
        XCTAssertNotNil(ColorGradeParams.clipGrade(clip)?.colorKey)
        clip.effects[0].parameters = try object("{\"v\":2,\"kind\":\"chroma\"}")
        XCTAssertNil(ColorGradeParams.clipGrade(clip))
        clip.effects[0].parameters = try object("{\"v\":1,\"kind\":\"future\"}")
        XCTAssertNil(ColorGradeParams.clipGrade(clip))
    }
}
