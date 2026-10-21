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
import MpvfxCanvas
import MpvfxColor
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The inspector (`ColorGrading`, MpvfxPanels) shows the grade the renderer (`ColorGradeParams`, MpvfxColor) draws:
/// the same value for every primary control, wheel, finish detail and the amount, whatever the stored JSON holds.
final class GradeReadParityTests: XCTestCase {
    func object(_ text: String) throws -> NativeJSONObject {
        let value = try JSONDecoder().decode(NativeJSONValue.self, from: Data(text.utf8))
        guard case .object(let o) = value else { throw ParityError.notAnObject(text) }
        return o
    }
    enum ParityError: Error { case notAnObject(String) }

    /// Stored grades the inspector must read as the renderer does: presets with keys left out, out-of-range values,
    /// numbers written as strings or booleans, nulls, wrapped hues and a padded preset id.
    static let corpus: [String] = [
        #"{"preset":"warm-daylight"}"#,
        #"{"preset":"night-lift","adjust":{"exposure":0}}"#,
        #"{"preset":" vintage-wash ","adjust":{"shadows":null}}"#,
        #"{"preset":"creator-camcorder"}"#,
        #"{"preset":"home-movie-8mm","intensity":"0.5","details":{"grain":null}}"#,
        #"{"adjust":{"exposure":5,"contrast":-3,"saturation":"0.4","tint":true,"vibrance":"abc","whites":[1]}}"#,
        #"{"intensity":1.8,"details":{"vignette":-1,"vignetteRoundness":-4,"grainSize":"0.9"}}"#,
        #"{"intensity":null,"adjust":{"contrast":0.3}}"#,
        #"{"wheels":{"shadows":{"hue":-30,"amount":3,"level":-2},"midtones":{"hue":"725","amount":"0.5","level":true},"highlights":{"hue":[0]}}}"#,
        #"{"preset":"no-such-preset","adjust":{"exposure":0.2}}"#,
        #"{"preset":"vhs-playback"}"#,
        #"{"preset":"editorial-halftone","effects":{"halftone":null,"bloom":9,"bloomRadius":"0","asciiStyle":true,"blur":"0.3","pixelate":-1,"tapeNoise":[1]}}"#,
    ]

    func testInspectorReadsEveryStoredValueAsTheRendererDoes() throws {
        for text in Self.corpus {
            let json = try object(text)
            let shown = ColorGrading(json: json)
            let drawn = try XCTUnwrap(ColorGradeParams(json: json), text)
            for k in GradeValues.adjustKeys { XCTAssertEqual(shown.adjustValue(k), drawn.adjust(k), "\(text) adjust.\(k)") }
            for k in GradeValues.detailKeys { XCTAssertEqual(shown.detail(k), drawn.detail(k), "\(text) details.\(k)") }
            for k in GradeValues.wheelKeys {
                let s = shown.wheel(k), d = try XCTUnwrap(drawn.wheels[k])
                XCTAssertEqual([s.hue, s.amount, s.level], [d.hue, d.amount, d.level], "\(text) wheels.\(k)")
            }
            for k in GradeValues.effectKeys { XCTAssertEqual(shown.effect(k), drawn.effect(k), "\(text) effects.\(k)") }
            XCTAssertEqual(shown.intensity, drawn.intensity, "\(text) intensity")
        }
    }

    /// What the inspector saves reads back, in the renderer, as what the inspector showed.
    func testSavedGradeReloadsAsShown() throws {
        for text in Self.corpus {
            let shown = ColorGrading(json: try object(text))
            let reloaded = try XCTUnwrap(ColorGradeParams(json: shown.json), text)
            for k in GradeValues.adjustKeys { XCTAssertEqual(reloaded.adjust(k), shown.adjustValue(k), "\(text) adjust.\(k)") }
            for k in GradeValues.detailKeys { XCTAssertEqual(reloaded.detail(k), shown.detail(k), "\(text) details.\(k)") }
            for k in GradeValues.effectKeys { XCTAssertEqual(reloaded.effect(k), shown.effect(k), "\(text) effects.\(k)") }
            XCTAssertEqual(reloaded.intensity, shown.intensity, "\(text) intensity")
        }
    }

    /// The inspector's preset table (names for the grid) carries the renderer's values.
    func testInspectorPresetsAreTheRendererPresets() throws {
        XCTAssertEqual(ColorGrading.presets.map(\.id), ColorGradeParams.presets.map(\.id))
        for p in ColorGrading.presets {
            let r = try XCTUnwrap(ColorGradeParams.preset(named: p.id))
            XCTAssertEqual(p.intensity, r.intensity, p.id)
            for k in GradeValues.adjustKeys { XCTAssertEqual(p.adjust[k] ?? 0, r.adjust[k], "\(p.id) adjust.\(k)") }
            for k in GradeValues.detailKeys { XCTAssertEqual(p.details[k] ?? GradeValues.detailDefaults[k], r.details[k], "\(p.id) details.\(k)") }
            for (k, v) in p.effects { XCTAssertEqual(v, r.effects[k], "\(p.id) effects.\(k)") }
        }
    }

    /// Resetting a slider on a preset grade renders the control's default, not the preset's value the slider no
    /// longer shows.
    func testResetOnAPresetGradeRendersTheDefault() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let preset = try XCTUnwrap(ColorGrading.preset("night-lift"))
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", ColorGrading().applying(preset)))
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.openGroupId = "grade"
        p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 380, height: 4000))
        try XCTUnwrap(p.reset("grade:adj:exposure"))()
        try XCTUnwrap(p.reset("grade:det:vignette"))()
        let clip = try XCTUnwrap(editor.clip("clip:a")?.clip)
        let drawn = try XCTUnwrap(ColorGradeParams.clipGrade(clip))
        XCTAssertEqual(drawn.adjust("exposure"), 0, "exposure renders its default after a reset")
        XCTAssertEqual(drawn.detail("vignette"), 0, "vignette renders its default after a reset")
        XCTAssertEqual(drawn.adjust("shadows"), 0.2, "the other preset values stay")
        let shown = try XCTUnwrap(editor.colorGrading(clipId: "clip:a"))
        XCTAssertEqual(shown.adjustValue("exposure"), 0); XCTAssertEqual(shown.adjustValue("shadows"), 0.2)
    }
}
