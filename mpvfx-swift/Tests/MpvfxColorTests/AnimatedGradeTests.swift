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

/// Issue #179: a grade at one frame is the stored grade with that frame's animated values written in, normalized
/// like any grade; with no animated value it is the stored grade unchanged.
final class AnimatedGradeTests: XCTestCase {
    func clip(_ parameters: String?, enabled: Bool = true) throws -> NativeProjectClip {
        var c = NativeProjectClip.fresh(id: "clip:1", assetId: "a", startFrame: 0, durationFrames: 30)
        if let parameters {
            let o = try XCTUnwrap(try NativeJSONValue.parse(parameters).objectValue)
            c.effects = [NativeClipEffect(id: "g", effectId: ColorGradeParams.effectId, enabled: enabled, parameters: o)]
        }
        return c
    }

    func testTheGradeContractListsMatchTheAnimatableIds() {
        XCTAssertEqual(NativeGradeParameter.adjustKeys, ColorGradeParams.adjustKeys)
        XCTAssertEqual(NativeGradeParameter.wheelKeys, ColorGradeParams.wheelKeys)
        XCTAssertEqual(NativeGradeParameter.effectKeys, ColorGradeParams.activeEffectKeys)
        XCTAssertTrue(Set(NativeGradeParameter.detailKeys).isSubset(of: ColorGradeParams.detailKeys))
    }

    func testNoAnimatedValueIsTheStoredGrade() throws {
        let c = try clip(#"{"adjust":{"exposure":0.6},"wheels":{"shadows":{"hue":120,"amount":0.4}}}"#)
        XCTAssertEqual(ColorGradeParams.clipGrade(c, animated: [:]), ColorGradeParams.clipGrade(c))
    }

    func testAnimatedValuesReplaceTheStoredOnesAndAreClamped() throws {
        let c = try clip(#"{"adjust":{"exposure":0.6,"contrast":0.2},"intensity":0.8}"#)
        let g = try XCTUnwrap(ColorGradeParams.clipGrade(c, animated: ["grade.adjust.exposure": 1.25, "grade.intensity": 3,
                                                                       "grade.wheels.midtones.amount": 0.5, "grade.effects.bloom": 9]))
        XCTAssertEqual(g.adjust("exposure"), 1.25)
        XCTAssertEqual(g.adjust("contrast"), 0.2, "a value that does not animate keeps its stored value")
        XCTAssertEqual(g.intensity, 1, "clamped to the contract's 0…1")
        XCTAssertEqual(g.wheels["midtones"]?.amount, 0.5)
        XCTAssertEqual(g.effect("bloom"), 3, "bloom's contract limit is 0…3")
    }

    func testAClipWithKeysButNoGradeAnimatesFromTheDefaultsAndAnOffGradeStaysOff() throws {
        let none = try clip(nil)
        XCTAssertEqual(ColorGradeParams.clipGrade(none, animated: ["grade.adjust.exposure": 0.5])?.adjust("exposure"), 0.5)
        XCTAssertNil(ColorGradeParams.clipGrade(try clip(#"{"adjust":{"exposure":0.6}}"#, enabled: false), animated: ["grade.adjust.exposure": 0.5]))
    }
}
