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

/// `sequence.captions` in the document (issue #81): round trip, older documents, and the validator's refusals.
final class NativeCaptionTrackTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withCaptions(_ json: String) -> NativeJSONValue {
        var d = validNativeDocument(); d["sequence"]?["captions"] = J(json); return d
    }
    func withCues(_ cues: String) -> NativeJSONValue { withCaptions(#"{"id":"captions:main","cues":["# + cues + "]}") }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func assertRejects(_ cues: String, _ path: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(withCues(cues), file: file, line: line)
        XCTAssertEqual(found.map(\.code), [.invalidCaption], "\(found)", file: file, line: line)
        XCTAssertEqual(found.first?.path, path, file: file, line: line)
        XCTAssertTrue(found.first?.message.contains(text) ?? false, "\(found)", file: file, line: line)
    }

    // Acceptance 1: `project.json` stores a caption track as a list of cues (id, start, end, text) and round-trips it.
    func testProjectJSONStoresTheCaptionTrackAndRoundTripsIt() throws {
        let cues = #"{"id":"cue-1","startMs":0,"endMs":1500,"text":"Hello"},{"id":"cue-2","startMs":1500,"endMs":4000,"text":"two\nlines"}"#
        let doc = try parse(withCues(cues))
        XCTAssertEqual(doc.sequence.captions, NativeCaptionTrack(id: "captions:main", cues: [
            NativeCaptionCue(id: "cue-1", startMs: 0, endMs: 1500, text: "Hello"),
            NativeCaptionCue(id: "cue-2", startMs: 1500, endMs: 4000, text: "two\nlines"),
        ]))
        let text = try serialize(withCues(cues))
        XCTAssertTrue(text.contains(#""captions": {"#), text)
        XCTAssertEqual(try parse(J(text)), doc, "save then open gives the same document")
        XCTAssertEqual(try serialize(J(text)), text, "a second save writes the same bytes")
    }

    // Acceptance 1 and migration: a document written before captions opens unchanged and saves without the key.
    func testADocumentWithoutCaptionsOpensAndSavesUnchanged() throws {
        let doc = try parse(validNativeDocument())
        XCTAssertNil(doc.sequence.captions)
        let text = try serialize(validNativeDocument())
        XCTAssertFalse(text.contains("captions"), text)
        XCTAssertEqual(try serialize(J(text)), text)
        XCTAssertEqual(doc.schemaVersion, NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION, "adding captions did not bump the schema")
    }

    // Acceptance 2: an older document stays valid; an empty track is valid too.
    func testAnOlderDocumentAndAnEmptyTrackAreValid() {
        XCTAssertEqual(validateNativeProjectDocument(validNativeDocument(), engine: engine), [])
        XCTAssertEqual(validateNativeProjectDocument(withCues(""), engine: engine), [])
    }

    // Acceptance 2: overlapping cues are refused with a typed error.
    func testRefusesOverlappingCues() {
        assertRejects(#"{"id":"a","startMs":0,"endMs":2000,"text":"A"},{"id":"b","startMs":1999,"endMs":3000,"text":"B"}"#,
                "sequence.captions.cues[1]", "overlaps the previous cue")
        XCTAssertEqual(validateNativeProjectDocument(
            withCues(#"{"id":"a","startMs":0,"endMs":2000,"text":"A"},{"id":"b","startMs":2000,"endMs":3000,"text":"B"}"#), engine: engine), [],
            "a cue may start the millisecond the previous one ends")
    }

    // Acceptance 2: a negative (or zero) duration is refused.
    func testRefusesANegativeDuration() {
        assertRejects(#"{"id":"a","startMs":3000,"endMs":1000,"text":"A"}"#, "sequence.captions.cues[0]", "must end after it starts")
        assertRejects(#"{"id":"a","startMs":3000,"endMs":3000,"text":"A"}"#, "sequence.captions.cues[0]", "must end after it starts")
    }

    // Acceptance 2: cues out of start order are refused.
    func testRefusesCuesOutOfOrder() {
        assertRejects(#"{"id":"a","startMs":5000,"endMs":6000,"text":"A"},{"id":"b","startMs":1000,"endMs":2000,"text":"B"}"#,
                "sequence.captions.cues[1]", "must be in start order")
    }

    // Acceptance 2: invalid UTF-8 (read as U+FFFD by the document reader, and a lone surrogate escape) is refused.
    func testRefusesInvalidUTF8Text() throws {
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000,"text":"caf�"}"#, "sequence.captions.cues[0].text", "invalid UTF-8")
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000,"text":"\ud800"}"#, "sequence.captions.cues[0].text", "invalid UTF-8")
        var bytes = Array(#"{"schemaVersion":1}"#.utf8)
        bytes.insert(0xE9, at: 2)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).unicodeScalars.contains("\u{FFFD}"),
                      "the document reader turns an invalid byte into U+FFFD, which the validator refuses")
    }

    func testRefusesMalformedTracksAndCues() {
        XCTAssertEqual(issues(withCaptions(#"[]"#)).map(\.message), ["Caption track must be an object"])
        XCTAssertEqual(issues(withCaptions(#"{"id":"c"}"#)).map(\.path), ["sequence.captions.cues"])
        XCTAssertEqual(issues(withCaptions(#"{"id":"","cues":[]}"#)).map(\.path), ["sequence.captions.id"])
        assertRejects(#"7"#, "sequence.captions.cues[0]", "must be an object")
        assertRejects(#"{"id":"a","startMs":-1,"endMs":1000,"text":"A"}"#, "sequence.captions.cues[0].startMs", "whole number of milliseconds")
        assertRejects(#"{"id":"a","startMs":0.5,"endMs":1000,"text":"A"}"#, "sequence.captions.cues[0].startMs", "whole number")
        assertRejects(#"{"id":"a","startMs":0,"endMs":3600000000,"text":"A"}"#, "sequence.captions.cues[0].endMs", "3599999999")
        assertRejects(#"{"id":"a","startMs":0,"endMs":"1000","text":"A"}"#, "sequence.captions.cues[0].endMs", "whole number")
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000}"#, "sequence.captions.cues[0].text", "must be a string")
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000,"text":""}"#, "sequence.captions.cues[0].text", "must not be empty")
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000,"text":"one\n\ntwo"}"#, "sequence.captions.cues[0].text", "blank line")
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000,"text":"a --> b"}"#, "sequence.captions.cues[0].text", "-->")
        assertRejects(#"{"id":"a","startMs":0,"endMs":1000,"text":"a\rb"}"#, "sequence.captions.cues[0].text", "control characters")
        let duplicate = issues(withCues(#"{"id":"a","startMs":0,"endMs":1000,"text":"A"},{"id":"a","startMs":1000,"endMs":2000,"text":"B"}"#))
        XCTAssertEqual(duplicate, [NativeProjectDocumentValidationIssue(code: .duplicateId, path: "sequence.captions.cues[1].id",
                                                                        message: "Duplicate stable ID a")], "the shared duplicate-id code")
    }

    func testTheProblemFunctionsAgreeWithTheValidator() {
        XCTAssertNil(nativeCaptionTextProblem("<i>tab\there</i>\nsecond line"))
        XCTAssertNotNil(nativeCaptionLineProblem("  \t "))
        XCTAssertNil(nativeCaptionTimingProblem(NativeCaptionCue(id: "a", startMs: 0, endMs: 1, text: "x"), after: nil))
        XCTAssertEqual(NATIVE_CAPTION_MAX_MILLISECONDS, 3_599_999_999)
    }
}
