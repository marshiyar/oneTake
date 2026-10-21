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
@testable import MpvfxShared

/// The animatable grade parameters (issue #179): their ids, their JSON paths, the authored value read from the
/// grade effect, and values written back into the grade's JSON.
final class NativeGradeParameterTests: XCTestCase {
    func gradeClip(_ parameters: String) throws -> NativeProjectClip {
        let o = try XCTUnwrap(try NativeJSONValue.parse(parameters).objectValue)
        var c = NativeProjectClip.fresh(id: "c", assetId: "a", startFrame: 0, durationFrames: 10)
        c.effects = [NativeClipEffect(id: "g", effectId: "color-grading", enabled: true, parameters: o)]
        return c
    }

    func testIdsCoverAmountPrimaryWheelsFinishAndEffectAmounts() {
        XCTAssertEqual(NativeGradeParameter.allIds.count, 1 + 10 + 9 + 2 + 18)
        XCTAssertEqual(Set(NativeGradeParameter.allIds).count, NativeGradeParameter.allIds.count, "no id twice")
        XCTAssertEqual(NativeGradeParameter.allIds.prefix(2), ["grade.intensity", "grade.adjust.exposure"])
        XCTAssertTrue(NativeGradeParameter.allIds.contains("grade.wheels.midtones.level"))
        XCTAssertTrue(NativeGradeParameter.allIds.contains("grade.details.grain"))
        XCTAssertTrue(NativeGradeParameter.allIds.contains("grade.effects.kuwahara"))
        XCTAssertFalse(NativeGradeParameter.isGradeParameter("grade.curves.master"), "curves stay static (A5)")
        XCTAssertNil(NativeGradeParameter.path("grade.adjust.unknown"))
        XCTAssertEqual(NativeGradeParameter.path("grade.wheels.shadows.hue"), ["wheels", "shadows", "hue"])
    }

    func testAuthoredValueReadsTheGradeJSON() throws {
        let c = try gradeClip(#"{"intensity":0.5,"adjust":{"exposure":0.25},"wheels":{"shadows":{"hue":200,"amount":0.3}}}"#)
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.intensity", in: c), 0.5)
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.adjust.exposure", in: c), 0.25)
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.wheels.shadows.hue", in: c), 200)
        XCTAssertNil(NativeGradeParameter.authoredValue("grade.adjust.contrast", in: c), "absent: the default applies")
        XCTAssertNil(NativeGradeParameter.authoredValue("grade.adjust.exposure", in: NativeProjectClip.fresh(id: "x", assetId: "a", startFrame: 0, durationFrames: 1)))
    }

    func testWritingCreatesPathsAndKeepsOtherKeys() throws {
        let c = try gradeClip(#"{"preset":"warm-daylight","adjust":{"contrast":0.1}}"#)
        let params = try XCTUnwrap(c.effects.first?.parameters)
        let out = NativeGradeParameter.writing(["grade.adjust.exposure": 1, "grade.wheels.highlights.level": -0.5, "not.grade": 3], into: params)
        XCTAssertEqual(jsJSONStringify(.object(out)),
                       #"{"preset":"warm-daylight","adjust":{"contrast":0.1,"exposure":1},"wheels":{"highlights":{"level":-0.5}}}"#)
    }
}
