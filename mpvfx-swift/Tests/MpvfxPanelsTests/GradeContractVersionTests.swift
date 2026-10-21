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
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The grade contract version the inspector writes (issue #172): new grades are contract 3, a stored grade keeps the
/// contract it was graded under, so editing one control of an old project's grade does not change its Warmth.
final class GradeContractVersionTests: XCTestCase {
    func testANewGradeIsWrittenAsContract3() {
        XCTAssertEqual(ColorGrading.contractVersion, 3)
        XCTAssertEqual(ColorGrading().json["version"], .number(3))
    }

    func testAStoredGradeKeepsItsContract() {
        XCTAssertEqual(ColorGrading(json: ["adjust": .object(["temperature": .number(0.5)])]).version, 2, "no version is contract 2")
        XCTAssertEqual(ColorGrading(json: ["version": .number(2)]).version, 2)
        XCTAssertEqual(ColorGrading(json: ["version": .number(3)]).version, 3)
        XCTAssertEqual(ColorGrading(json: ["version": .string("abc")]).version, 2)
        var old = ColorGrading(json: ["adjust": .object(["temperature": .number(0.5)])])
        old.adjust["saturation"] = 0.2
        XCTAssertEqual(old.json["version"], .number(2), "an edit keeps contract 2")
    }

    func testEditingAnOldGradeInTheInspectorKeepsContract2() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", ColorGrading(json: ["adjust": .object(["temperature": .number(0.5)])])))
        var g = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        g.adjust["contrast"] = 0.1
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        let stored = try XCTUnwrap(editor.clip("clip:a")?.clip.effects.first { $0.effectId == ColorGrading.effectId }?.parameters)
        XCTAssertEqual(stored["version"], .number(2))
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:b", ColorGrading().applying(try XCTUnwrap(ColorGrading.preset("warm-daylight")))))
        XCTAssertEqual(editor.colorGrading(clipId: "clip:b")?.version, 3, "a grade started in the inspector is contract 3")
    }
}
