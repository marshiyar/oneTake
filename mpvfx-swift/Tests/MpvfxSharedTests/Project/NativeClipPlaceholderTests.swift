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

/// `clip.placeholder` in the document: absent stays absent byte for byte, `"v": 1` round trips, another version is kept
/// unchanged and not drawn, and every bad value is a typed issue.
final class NativeClipPlaceholderTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withPlaceholder(_ placeholder: String) -> NativeJSONValue {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["placeholder"] = J(placeholder)
        return d
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func rejects(_ d: NativeJSONValue, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(d, file: file, line: line)
        XCTAssertTrue(found.contains { $0.code == .invalidClip && $0.path.hasSuffix(path) }, "\(found)", file: file, line: line)
    }

    func testADocumentWithoutPlaceholdersOpensAndSavesByteIdentical() throws {
        let saved = try serialize(validNativeDocument())
        XCTAssertFalse(saved.contains("placeholder"))
        XCTAssertEqual(try serialize(J(saved)), saved, "open and save again: the same bytes")
        XCTAssertEqual(try parse(J(saved)).schemaVersion, 1)
        XCTAssertEqual(try parse(J(saved)).unfilledPlaceholderNumbers, [])
    }

    func testAVersionOnePlaceholderRoundTrips() throws {
        let saved = try serialize(withPlaceholder(#"{"v":1,"index":2,"label":"Intro"}"#))
        XCTAssertEqual(J(saved)["sequence"]?["tracks"]?[0]?["clips"]?[0]?["placeholder"], J(#"{"index":2,"label":"Intro","v":1}"#), saved)
        let doc = try parse(J(saved))
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].placeholder, NativeClipPlaceholder(index: 2, label: "Intro"))
        XCTAssertEqual(doc.unfilledPlaceholderNumbers, [2])
        XCTAssertEqual(try serialize(J(saved)), saved)
    }

    func testAPlaceholderWithoutALabelOmitsIt() throws {
        let saved = try serialize(withPlaceholder(#"{"v":1,"index":1}"#))
        XCTAssertFalse(saved.contains("label"), saved)
    }

    func testAPlaceholderFromANewerVersionIsKeptUnchangedNotDrawnAndNoticed() throws {
        let placeholder = #"{"v":2,"slot":{"name":"intro"},"index":"first"}"#
        let doc = try parse(withPlaceholder(placeholder))
        let clip = doc.sequence.tracks[0].clips[0]
        XCTAssertEqual(try NativeJSONValue.from(clip.placeholder), J(placeholder), "every key kept as written")
        XCTAssertNil(clip.placeholder?.number)
        XCTAssertTrue(doc.isUndrawnClip(clip))
        XCTAssertEqual(doc.unfilledPlaceholderNumbers, [])
        XCTAssertEqual(doc.undrawnContentNotices,
                       ["1 placeholder from a newer version of the editor is kept in the project but not drawn in preview or export."])
        XCTAssertTrue(try serialize(J(try serialize(withPlaceholder(placeholder)))).contains("\"slot\""))
    }

    func testHostilePlaceholdersAreTypedIssues() {
        rejects(withPlaceholder(#""1""#), "placeholder")
        rejects(withPlaceholder(#"{}"#), "placeholder.v")
        rejects(withPlaceholder(#"{"v":0,"index":1}"#), "placeholder.v")
        rejects(withPlaceholder(#"{"v":1.5,"index":1}"#), "placeholder.v")
        rejects(withPlaceholder(#"{"v":"1","index":1}"#), "placeholder.v")
        rejects(withPlaceholder(#"{"v":1}"#), "placeholder.index")
        rejects(withPlaceholder(#"{"v":1,"index":0}"#), "placeholder.index")
        rejects(withPlaceholder(#"{"v":1,"index":-2}"#), "placeholder.index")
        rejects(withPlaceholder(#"{"v":1,"index":1.5}"#), "placeholder.index")
        rejects(withPlaceholder(#"{"v":1,"index":"1"}"#), "placeholder.index")
        rejects(withPlaceholder(#"{"v":1,"index":1e300}"#), "placeholder.index")
        rejects(withPlaceholder(#"{"v":1,"index":1,"label":""}"#), "placeholder.label")
        rejects(withPlaceholder(#"{"v":1,"index":1,"label":4}"#), "placeholder.label")
    }

    func testTwoClipsCannotShareAPlaceholderNumber() {
        let d = J("""
        {"schemaVersion":1,"mediaEngine":"native","id":"project:demo","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#101010"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":300}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video-1","kind":"video","clips":[
           {"id":"clip:1","assetId":"asset:a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[],"placeholder":{"v":1,"index":3}},
           {"id":"clip:2","assetId":"asset:a","startFrame":30,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[],"placeholder":{"v":1,"index":3}}]}]}}
        """)
        rejects(d, "clips[1].placeholder.index")
    }
}
