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
@testable import MpvfxPlayer
import MpvfxColor
import MpvfxShared
import OneTakeKeyframes

/// Issue #179 A3 / A4: the preview composition grades a clip with keyframed grade values at each frame's values,
/// and a clip with no grade track keeps the one grade built per document.
final class PreviewGradeAnimationTests: XCTestCase {
    /// One 30-frame video clip graded with exposure +0.6; `tracks` are its parameter tracks.
    func composition(tracks: String = "[]") throws -> PreviewComposition {
        let engine = try KeyframeRuntime()
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"m.mov","source":"m.mov","durationFrames":30}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"video","clips":[
          {"id":"clip:a","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,
           "effects":[{"id":"g","effectId":"color-grading","enabled":true,"parameters":{"adjust":{"exposure":0.6}}}],
           "parameterTracks":\#(tracks)}]}]}}
        """#), engine: engine)
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/project"), engine: engine, fileExists: { _ in true })
    }

    static let exposureRamp = #"[{"schemaVersion":1,"id":"k","parameterId":"grade.adjust.exposure","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"k0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"k1","frame":20,"value":1,"outgoing":{"type":"linear"}}]}]"#

    func testAClipWithoutGradeTracksKeepsTheGradeBuiltOncePerDocument() throws {
        let comp = try composition()
        let e = try XCTUnwrap(comp.entries.first)
        XCTAssertNil(e.gradeAnimation)
        let early = try XCTUnwrap(comp.layers(at: 0.1).first?.grade), late = try XCTUnwrap(comp.layers(at: 0.9).first?.grade)
        XCTAssertTrue(early === e.grade && late === e.grade, "the same renderer object at every frame, as before")
    }

    func testAKeyedExposureIsGradedAtEachFramesValue() throws {
        let comp = try composition(tracks: Self.exposureRamp)
        XCTAssertEqual(comp.entries.first?.gradeAnimation?.parameterIds, ["grade.adjust.exposure"])
        XCTAssertNil(comp.layers(at: 0).first?.grade, "exposure 0 at the first frame: no active grade there")
        let mid = try XCTUnwrap(comp.layers(at: 10.0 / 30).first?.grade?.params.adjust("exposure"))
        XCTAssertEqual(mid, 0.5, accuracy: 1e-6, "linear halfway")
        XCTAssertEqual(try XCTUnwrap(comp.layers(at: 25.0 / 30).first?.grade?.params.adjust("exposure")), 1, accuracy: 1e-9, "held after the last key")
        let again = comp.layers(at: 10.0 / 30).first?.grade
        XCTAssertTrue(again === comp.layers(at: 10.0 / 30).first?.grade, "the same frame reuses its renderer")
    }
}
