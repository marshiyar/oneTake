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
        XCTAssertFalse(NativeGradeParameter.isGradeParameter("grade.curves.master"), "a curve is animated point by point, never as one value")
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

    // MARK: Curve points and secondaries (issue #228)

    func testCurvePointAndSecondaryIdsAreRecognisedWithTheirJSONPaths() {
        XCTAssertEqual(NativeGradeParameter.curveId("master", 2, "y"), "grade.curves.master.2.y")
        XCTAssertEqual(NativeGradeParameter.path("grade.curves.master.2.y"), ["curves", "master", "2", "1"])
        XCTAssertEqual(NativeGradeParameter.path("grade.curves.lumaVsSaturation.0.x"), ["curves", "lumaVsSaturation", "0", "0"])
        XCTAssertEqual(NativeGradeParameter.path("grade.hueCurves.hueVsLuma.15.x"), ["hueCurves", "hueVsLuma", "15", "0"])
        XCTAssertEqual(NativeGradeParameter.path("grade.secondaries.1.hueCenter"), ["secondaries", "1", "key", "hue", "center"])
        XCTAssertEqual(NativeGradeParameter.path("grade.secondaries.0.tint"), ["secondaries", "0", "correction", "tint"])
        for id in NativeGradeParameter.secondaryIds(3) { XCTAssertTrue(NativeGradeParameter.isGradeParameter(id), id) }
        XCTAssertEqual(NativeGradeParameter.secondaryIds(0).count, 14)
        XCTAssertEqual(NativeGradeParameter.secondaryKeyFields.count + NativeGradeParameter.secondaryCorrectionFields.count, 14)
        XCTAssertEqual(NativeGradeParameter.curveIds("red", count: 2), ["grade.curves.red.0.x", "grade.curves.red.0.y", "grade.curves.red.1.x", "grade.curves.red.1.y"])
        for bad in ["grade.curves.master.16.x", "grade.curves.master.-1.x", "grade.curves.master.01.x", "grade.curves.master.0.z",
                    "grade.curves.hueVsHue.0.x", "grade.hueCurves.master.0.x", "grade.curves.unknown.0.x", "grade.secondaries.4.tint",
                    "grade.secondaries.0.enabled", "grade.secondaries.0", "grade.curves.master.0.x.y"] {
            XCTAssertFalse(NativeGradeParameter.isGradeParameter(bad), bad)
            XCTAssertNil(NativeGradeParameter.path(bad), bad)
        }
        XCTAssertFalse(NativeGradeParameter.allIds.contains { $0.hasPrefix("grade.curves") || $0.hasPrefix("grade.secondaries") }, "the fixed list stays as it was")
    }

    func testAuthoredValueReadsCurvePointsAndSecondaryFields() throws {
        let c = try gradeClip(#"{"curves":{"master":[[0,0],[0.5,0.7],[1,1]]},"hueCurves":{"hueVsSat":[[10,0.2]]},"secondaries":[{"enabled":true,"key":{"hue":{"center":120,"range":30,"softness":20}},"correction":{"tint":0.4}}]}"#)
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.curves.master.1.y", in: c), 0.7)
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.curves.master.2.x", in: c), 1)
        XCTAssertNil(NativeGradeParameter.authoredValue("grade.curves.master.3.x", in: c), "no such point")
        XCTAssertNil(NativeGradeParameter.authoredValue("grade.curves.red.0.x", in: c), "no such curve")
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.secondaries.0.hueCenter", in: c), 120)
        XCTAssertEqual(NativeGradeParameter.authoredValue("grade.secondaries.0.tint", in: c), 0.4)
        XCTAssertNil(NativeGradeParameter.authoredValue("grade.secondaries.0.satMin", in: c), "absent: the default applies")
        XCTAssertNil(NativeGradeParameter.authoredValue("grade.secondaries.1.tint", in: c), "no second secondary")
    }

    /// Writing replaces the number of a point or setting that is there and creates nothing for one that is not.
    func testWritingChangesExistingPointsAndSecondariesOnly() throws {
        let c = try gradeClip(#"{"curves":{"master":[[0,0],[1,1]]},"secondaries":[{"enabled":true,"key":{"hue":{"center":120}},"correction":{"tint":0}}]}"#)
        let params = try XCTUnwrap(c.effects.first?.parameters)
        let out = NativeGradeParameter.writing([
            "grade.curves.master.1.y": 0.25, "grade.curves.master.5.y": 0.9, "grade.curves.red.0.x": 0.1,
            "grade.secondaries.0.hueCenter": 200, "grade.secondaries.0.satMin": 0.3, "grade.secondaries.1.tint": 1,
        ], into: params)
        XCTAssertEqual(jsJSONStringify(.object(out)),
                       #"{"curves":{"master":[[0,0],[1,0.25]]},"secondaries":[{"enabled":true,"key":{"hue":{"center":200},"saturation":{"min":0.3}},"correction":{"tint":0}}]}"#)
    }

    func testAnimatedIdsListFixedIdsThenPointsAndSecondariesInOrder() throws {
        var c = try gradeClip("{}")
        func track(_ id: String) -> NativeParameterTrack {
            NativeParameterTrack(id: "t-\(id)", parameterId: id, valueType: .number, frameRate: RationalFrameRate(numerator: 30, denominator: 1),
                                 keyframes: [NativeKeyframe(id: "k", frame: 0, value: .number(0), outgoing: .linear)], autoRotate: nil)
        }
        let ids = ["grade.secondaries.1.tint", "grade.curves.master.10.y", "grade.curves.master.2.x", "grade.adjust.exposure", "grade.intensity", "grade.curves.red.0.x"]
        c.parameterTracks = ids.map(track) + [track("transform.opacity"), track("grade.curves.master.99.x")]
        XCTAssertEqual(NativeGradeParameter.animatedIds(c),
                       ["grade.intensity", "grade.adjust.exposure", "grade.curves.master.2.x", "grade.curves.master.10.y", "grade.curves.red.0.x", "grade.secondaries.1.tint"])
        XCTAssertEqual(NativeGradeParameter.animatedCurveChannels(c), ["curves.master", "curves.red"])
        XCTAssertTrue(NativeGradeParameter.hasAnimatedSecondaries(c))
        c.parameterTracks = [track("grade.adjust.exposure")]
        XCTAssertTrue(NativeGradeParameter.animatedCurveChannels(c).isEmpty)
        XCTAssertFalse(NativeGradeParameter.hasAnimatedSecondaries(c))
    }
}
