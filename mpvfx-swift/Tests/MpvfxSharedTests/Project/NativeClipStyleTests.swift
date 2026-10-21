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

/// `clip.style` (fill, stroke, shadows) in the document: JSON round trip, defaults and validation.
final class NativeClipStyleTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func roundTrip(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parse(J(try serializeNativeProjectDocument(d, engine: engine))) }
    func withStyle(_ style: String) -> NativeJSONValue {
        var d = validNativeDocument(); d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["style"] = J(style); return d
    }
    func rejects(_ style: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(withStyle(style)); XCTFail("accepted \(style)", file: file, line: line) }
        catch let e as NativeProjectDocumentValidationError { XCTAssertTrue(e.message.contains(text), e.message, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testRoundTripsEveryStyleField() throws {
        let json = ##"{"fill":"#102030","strokeWidth":4,"strokeStyle":"solid","strokeColor":"#ffffff2e","shadows":[{"x":0,"y":12,"blur":36,"spread":0,"color":"#00000047"},{"x":-3,"y":0,"blur":0,"spread":1,"color":"#3ce6ac57"}]}"##
        let doc = try roundTrip(withStyle(json))
        let style = doc.sequence.tracks[0].clips[0].style
        XCTAssertEqual(style, NativeClipStyle(fill: "#102030", strokeWidth: 4, strokeStyle: "solid", strokeColor: "#ffffff2e",
                                              shadows: [NativeClipShadow(y: 12, blur: 36, color: "#00000047"),
                                                        NativeClipShadow(x: -3, spread: 1, color: "#3ce6ac57")]))
        XCTAssertEqual(try NativeJSONValue.from(style), J(json), "the serialized style is the input")
        XCTAssertEqual(try roundTrip(J(try serializeNativeProjectDocument(doc, engine: engine))).sequence.tracks[0].clips[0].style, style)
    }

    func testAbsentStyleStaysAbsentAndPartialStylesKeepTheirFields() throws {
        XCTAssertNil(try roundTrip(validNativeDocument()).sequence.tracks[0].clips[0].style)
        XCTAssertFalse(try serializeNativeProjectDocument(validNativeDocument(), engine: engine).contains("\"style\""))
        let s = try roundTrip(withStyle(##"{"fill":"#abc"}"##)).sequence.tracks[0].clips[0].style
        XCTAssertEqual(s, NativeClipStyle(fill: "#abc"))
        XCTAssertEqual(s?.visibleStrokeWidth, 0); XCTAssertEqual(s?.resolvedStrokeColor, NativeClipStyle.defaultStrokeColor)
    }

    func testShadowPresetsMatchTheTSValues() {
        XCTAssertEqual(NativeClipShadowPreset.infer(nil), NativeClipShadowPreset.none)
        for p in NativeClipShadowPreset.allCases { XCTAssertEqual(NativeClipShadowPreset.infer(p.shadows), p) }
        XCTAssertNil(NativeClipShadowPreset.infer([NativeClipShadow(x: 1, color: "#000")]), "custom")
        XCTAssertEqual(NativeClipShadowPreset.soft.shadows, [NativeClipShadow(y: 12, blur: 36, color: "#00000047")])
    }

    func testRejectsMalformedStyles() {
        rejects(##""red""##, "Style must be an object")
        rejects(##"{"fill":"red"}"##, "Style colors must be")
        rejects(##"{"strokeColor":"#12345"}"##, "Style colors must be")
        rejects(##"{"strokeWidth":-1}"##, "non-negative")
        rejects(##"{"strokeStyle":"dashed"}"##, "Stroke style must be none or solid")
        rejects(##"{"shadows":{}}"##, "Shadows must be an array")
        rejects(##"{"shadows":[{"x":1}]}"##, "A shadow needs a color")
        rejects(##"{"shadows":[{"color":"#000","blur":-2}]}"##, "non-negative")
    }

    // Blend modes (`clip.style.blend`): saved, validated, absent by default.
    func testBlendRoundTripsAndAnAbsentBlendStaysAbsent() throws {
        for mode in NativeBlendMode.allCases where mode != .normal {
            let style = try roundTrip(withStyle(#"{"blend":"\#(mode.rawValue)"}"#)).sequence.tracks[0].clips[0].style
            XCTAssertEqual(style, NativeClipStyle(blend: mode.rawValue)); XCTAssertEqual(style?.blendMode, mode)
        }
        XCTAssertEqual(NativeClipStyle().blendMode, .normal)
        XCTAssertTrue(NativeClipStyle().isEmpty); XCTAssertFalse(NativeClipStyle(blend: "screen").isEmpty)
        XCTAssertEqual(NativeBlendMode.allCases.map(\.rawValue),
                       ["normal", "multiply", "screen", "overlay", "add", "soft-light", "darken", "lighten"])
    }

    func testRejectsAnUnknownBlend() {
        rejects(##"{"blend":"dissolve"}"##, "Blend must be one of")
        rejects(##"{"blend":3}"##, "Blend must be one of")
    }
}
