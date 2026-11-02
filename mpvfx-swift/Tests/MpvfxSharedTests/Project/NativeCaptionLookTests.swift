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

/// The caption look (`sequence.captions.look`) and a cue's own position: round trip, byte identity, one test per validator
/// rule, and a look from a newer version kept verbatim.
final class NativeCaptionLookTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withCaptions(_ json: String) -> NativeJSONValue {
        var d = validNativeDocument(); d["sequence"]?["captions"] = J(json); return d
    }
    func withLook(_ look: String) -> NativeJSONValue {
        withCaptions("{\"id\":\"captions:main\",\"cues\":[],\"look\":" + look + "}")
    }
    func withCues(_ cues: String) -> NativeJSONValue { withCaptions(#"{"id":"captions:main","cues":["# + cues + "]}") }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    /// The document is refused with exactly one issue, `invalid-caption`, at `path`, whose message contains `text`.
    func assertRejects(_ d: NativeJSONValue, _ path: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(d, file: file, line: line)
        XCTAssertEqual(found.map(\.code), [.invalidCaption], "\(found)", file: file, line: line)
        XCTAssertEqual(found.first?.path, path, "\(found)", file: file, line: line)
        XCTAssertTrue(found.first?.message.contains(text) ?? false, "\(found)", file: file, line: line)
    }
    func assertLookRejects(_ look: String, _ path: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        assertRejects(withLook(look), path, text, file: file, line: line)
    }

    // Acceptance 1: a full look parses to typed values, round-trips, and a second save writes the same bytes.
    func testAFullLookParsesToTypedValuesAndRoundTripsByteIdentical() throws {
        let look = ##"{"v":1,"fontFamily":"Inter","size":0.07,"weight":600,"color":"#FFFFFF","outlines":[{"width":4,"color":"#000000"}],"shadow":{"x":2,"y":3,"blur":4,"color":"#00000080"},"plate":{"color":"#00000099","padding":0.5},"position":{"place":"top"},"safeArea":0.06,"maxWidth":0.7}"##
        let doc = try parse(withLook(look))
        let typed = try XCTUnwrap(doc.sequence.captions?.look)
        XCTAssertEqual(typed, NativeCaptionLook(
            fontFamily: "Inter", size: 0.07, weight: 600, color: "#FFFFFF",
            outlines: [NativeTextLook.Outline(width: 4, color: "#000000")],
            shadow: NativeTextLook.Shadow(x: 2, y: 3, blur: 4, color: "#00000080"),
            plate: NativeCaptionLook.Plate(color: "#00000099", padding: 0.5),
            position: NativeCaptionPosition.top, safeArea: 0.06, maxWidth: 0.7))
        XCTAssertTrue(typed.isSupported)
        let text = try serialize(withLook(look))
        XCTAssertEqual(try parse(J(text)), doc, "save then open gives the same document")
        XCTAssertEqual(try serialize(J(text)), text, "a second save writes the same bytes")
    }

    // Acceptance 1: a track without a look and a cue without a position save without those keys.
    func testATrackWithoutALookAndACueWithoutAPositionSaveWithoutTheKeys() throws {
        let cues = #"{"id":"cue-1","startMs":0,"endMs":1500,"text":"Hello"}"#
        let doc = try parse(withCues(cues))
        XCTAssertNil(doc.sequence.captions?.look)
        XCTAssertNil(doc.sequence.captions?.cues[0].position)
        let text = try serialize(withCues(cues))
        XCTAssertFalse(text.contains("look"), text)
        let json = J(text)
        XCTAssertNil(json["sequence"]?["captions"]?["look"])
        XCTAssertNil(json["sequence"]?["captions"]?["cues"]?[0]?["position"])
        let plain = try serialize(validNativeDocument())
        XCTAssertFalse(plain.contains("look"), plain)
    }

    // Acceptance 1: a cue with a custom position round-trips, and its x and y are kept.
    func testACueWithACustomPositionRoundTripsAndKeepsXAndY() throws {
        let cues = #"{"id":"cue-1","startMs":0,"endMs":1500,"text":"Hello","position":{"place":"custom","x":0.5,"y":0.2}}"#
        let doc = try parse(withCues(cues))
        XCTAssertEqual(doc.sequence.captions?.cues[0].position, NativeCaptionPosition.custom(x: 0.5, y: 0.2))
        XCTAssertEqual(doc.sequence.captions?.cues[0].position?.x, 0.5)
        XCTAssertEqual(doc.sequence.captions?.cues[0].position?.y, 0.2)
        let text = try serialize(withCues(cues))
        XCTAssertEqual(try parse(J(text)), doc, "save then open gives the same document")
        XCTAssertEqual(try serialize(J(text)), text, "a second save writes the same bytes")
        XCTAssertEqual(J(text)["sequence"]?["captions"]?["cues"]?[0]?["position"], J(#"{"place":"custom","x":0.5,"y":0.2}"#))
    }

    // Acceptance 1: the track look's custom position keeps x and y through a save.
    func testALookWithACustomPositionKeepsXAndY() throws {
        let look = #"{"v":1,"position":{"place":"custom","x":0.25,"y":0.8}}"#
        let doc = try parse(withLook(look))
        XCTAssertEqual(doc.sequence.captions?.look?.position, NativeCaptionPosition.custom(x: 0.25, y: 0.8))
        let text = try serialize(withLook(look))
        XCTAssertEqual(try parse(J(text)), doc, "save then open gives the same document")
        XCTAssertEqual(try serialize(J(text)), text, "a second save writes the same bytes")
        XCTAssertEqual(J(text)["sequence"]?["captions"]?["look"]?["position"], J(#"{"place":"custom","x":0.25,"y":0.8}"#))
    }

    // Acceptance 1 (validator): one test per rule.
    func testALookThatIsNotAnObjectIsRefused() {
        assertLookRejects("[]", "sequence.captions.look", "Caption look must be an object")
    }

    func testTheLookVersionMustBeANumber() {
        assertLookRejects(#"{"v":"1"}"#, "sequence.captions.look.v", "Caption look v must be a number")
    }

    func testTheSizeMustBeWithinItsRange() {
        assertLookRejects(#"{"v":1,"size":0}"#, "sequence.captions.look.size", "Caption size must be a number from 0.01 to 0.25")
        assertLookRejects(#"{"v":1,"size":0.3}"#, "sequence.captions.look.size", "Caption size must be a number from 0.01 to 0.25")
    }

    func testTheWeightMustBeAWholeNumberInItsRange() {
        assertLookRejects(#"{"v":1,"weight":450.5}"#, "sequence.captions.look.weight", "Caption weight must be a whole number from 1.0 to 1000.0")
        assertLookRejects(#"{"v":1,"weight":0}"#, "sequence.captions.look.weight", "Caption weight must be a whole number from 1.0 to 1000.0")
    }

    func testTheColorMustBeAHexColor() {
        assertLookRejects(##"{"v":1,"color":"red"}"##, "sequence.captions.look.color", "Caption colors must be #RGB, #RRGGBB or #RRGGBBAA")
    }

    func testTheSafeAreaMustBeWithinItsRange() {
        assertLookRejects(#"{"v":1,"safeArea":0.5}"#, "sequence.captions.look.safeArea", "Caption safe area must be a number from 0.0 to 0.4")
    }

    func testTheMaxWidthMustBeWithinItsRange() {
        assertLookRejects(#"{"v":1,"maxWidth":0.1}"#, "sequence.captions.look.maxWidth", "Caption maximum width must be a number from 0.2 to 1.0")
    }

    func testTheFontFamilyMustNotBeEmpty() {
        assertLookRejects(#"{"v":1,"fontFamily":""}"#, "sequence.captions.look.fontFamily", "Caption font family must be a non-empty string")
    }

    func testALookHasAtMostTwoOutlines() {
        assertLookRejects(##"{"v":1,"outlines":[{"width":1,"color":"#000000"},{"width":1,"color":"#000000"},{"width":1,"color":"#000000"}]}"##,
                          "sequence.captions.look.outlines", "A caption look has at most 2 outlines")
    }

    func testAnOutlineWidthMustBeWithinItsRange() {
        assertLookRejects(##"{"v":1,"outlines":[{"width":-1,"color":"#000000"}]}"##,
                          "sequence.captions.look.outlines[0].width", "Outline width must be a number from 0.0 to 100.0")
    }

    func testTheShadowBlurMustBeWithinItsRange() {
        assertLookRejects(##"{"v":1,"shadow":{"blur":300,"color":"#000000"}}"##,
                          "sequence.captions.look.shadow.blur", "Shadow blur must be a number from 0.0 to 200.0")
    }

    func testTheShadowMustBeAnObject() {
        assertLookRejects(#"{"v":1,"shadow":5}"#, "sequence.captions.look.shadow", "Shadow must be an object")
    }

    func testThePlateMustBeAnObject() {
        assertLookRejects(#"{"v":1,"plate":"black"}"#, "sequence.captions.look.plate", "Plate must be an object")
    }

    func testThePlateColorMustBeAHexColor() {
        assertLookRejects(##"{"v":1,"plate":{"color":"red"}}"##, "sequence.captions.look.plate.color", "Caption colors must be #RGB, #RRGGBB or #RRGGBBAA")
    }

    func testThePlatePaddingMustBeWithinItsRange() {
        assertLookRejects(##"{"v":1,"plate":{"color":"#00000099","padding":3}}"##,
                          "sequence.captions.look.plate.padding", "Plate padding must be a number from 0.0 to 2.0")
    }

    func testThePositionPlaceMustBeKnown() {
        assertLookRejects(#"{"v":1,"position":{"place":"middle"}}"#, "sequence.captions.look.position.place",
                          "Caption position place must be one of bottom, top, custom")
    }

    func testACustomPositionNeedsAYAsWell() {
        assertLookRejects(#"{"v":1,"position":{"place":"custom","x":0.5}}"#, "sequence.captions.look.position.y",
                          "A custom caption position needs y as a number from 0 to 1")
    }

    func testABottomPositionRefusesAnX() {
        assertLookRejects(#"{"v":1,"position":{"place":"bottom","x":0.5}}"#, "sequence.captions.look.position.x",
                          "Only a custom caption position has x")
    }

    func testACueCustomPositionXMustBeWithinZeroToOne() {
        assertRejects(withCues(#"{"id":"a","startMs":0,"endMs":1000,"text":"A","position":{"place":"custom","x":1.5,"y":0.2}}"#),
                      "sequence.captions.cues[0].position.x", "A custom caption position needs x as a number from 0 to 1")
    }

    // Acceptance 1: a look whose `v` this editor does not know is kept byte for byte, not validated, and not supported.
    func testALookFromAnUnknownVersionIsKeptVerbatimAndNotValidated() throws {
        let look = ##"{"anything":true,"v":2}"##
        XCTAssertEqual(validateNativeProjectDocument(withLook(look), engine: engine), [])
        XCTAssertEqual(validateNativeProjectDocument(withLook(##"{"fontFamily":"","size":0,"v":2}"##), engine: engine), [],
                       "a look from a newer version is not validated further")
        let doc = try parse(withLook(look))
        let kept = try XCTUnwrap(doc.sequence.captions?.look)
        XCTAssertFalse(kept.isSupported)
        XCTAssertEqual(try NativeJSONValue.from(kept), J(look))
        let text = try serialize(withLook(look))
        // Keys are sorted on save, and the look sits at depth 3 (sequence, captions, look), so its members are indented 8 spaces.
        let block = "\"look\": {\n        \"anything\": true,\n        \"v\": 2\n      }"
        XCTAssertTrue(text.contains(block), text)
        XCTAssertEqual(try serialize(J(text)), text, "a second save writes the same bytes")
        XCTAssertEqual(try parse(J(text)), doc)
        let reopened = try parse(J(text))
        let reopenedLook = try XCTUnwrap(reopened.sequence.captions?.look)
        XCTAssertFalse(reopenedLook.isSupported)
    }
}
