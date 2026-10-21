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

/// `clip.holdSourceFrame` in the document: absent stays absent byte for byte, `"v": 1` round trips, another version
/// is kept unchanged and not drawn, and every bad value is a typed issue.
final class NativeClipHoldTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withHold(_ hold: String, _ extra: [String: NativeJSONValue] = [:]) -> NativeJSONValue {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["holdSourceFrame"] = J(hold)
        for (k, v) in extra { d["sequence"]?["tracks"]?[0]?["clips"]?[0]?[k] = v }
        return d
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func rejects(_ d: NativeJSONValue, _ code: NativeProjectDocumentValidationCode, _ path: String,
                 file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(d, file: file, line: line)
        XCTAssertTrue(found.contains { $0.code == code && $0.path.hasSuffix(path) }, "\(found)", file: file, line: line)
    }

    func testADocumentWithoutHoldsOpensAndSavesByteIdentical() throws {
        let saved = try serialize(validNativeDocument())
        XCTAssertFalse(saved.contains("holdSourceFrame"))
        XCTAssertEqual(try serialize(J(saved)), saved, "open and save again: the same bytes")
        XCTAssertEqual(try parse(J(saved)).schemaVersion, 1)
    }

    func testAVersionOneHoldRoundTrips() throws {
        let saved = try serialize(withHold(#"{"v":1,"frame":120}"#))
        XCTAssertEqual(J(saved)["sequence"]?["tracks"]?[0]?["clips"]?[0]?["holdSourceFrame"], J(#"{"frame":120,"v":1}"#), saved)
        let clip = try parse(J(saved)).sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.holdSourceFrame, NativeClipHold(frame: 120))
        XCTAssertEqual(clip.holdSourceFrame?.sourceFrame, 120)
        XCTAssertEqual(try serialize(J(saved)), saved)
    }

    func testAHoldFromANewerVersionIsKeptUnchangedNotDrawnAndNoticed() throws {
        let hold = #"{"v":2,"frame":{"from":3,"to":9},"motion":"blur"}"#
        let doc = try parse(withHold(hold))
        let clip = doc.sequence.tracks[0].clips[0]
        XCTAssertEqual(try NativeJSONValue.from(clip.holdSourceFrame), J(hold), "every key kept as written")
        XCTAssertNil(clip.holdSourceFrame?.sourceFrame)
        XCTAssertTrue(doc.isUndrawnClip(clip))
        XCTAssertEqual(doc.undrawnContentNotices,
                       ["1 held frame from a newer version of the editor is kept in the project but not drawn in preview or export."])
        XCTAssertTrue(try serialize(J(try serialize(withHold(hold)))).contains("\"motion\": \"blur\""))
    }

    func testHostileHoldsAreTypedIssues() {
        rejects(withHold(#""120""#), .invalidClip, "holdSourceFrame")
        rejects(withHold(#"{}"#), .invalidClip, "holdSourceFrame.v")
        rejects(withHold(#"{"v":0,"frame":1}"#), .invalidClip, "holdSourceFrame.v")
        rejects(withHold(#"{"v":1.5,"frame":1}"#), .invalidClip, "holdSourceFrame.v")
        rejects(withHold(#"{"v":"1","frame":1}"#), .invalidClip, "holdSourceFrame.v")
        rejects(withHold(#"{"v":1}"#), .invalidClip, "holdSourceFrame.frame")
        rejects(withHold(#"{"v":1,"frame":-1}"#), .invalidClip, "holdSourceFrame.frame")
        rejects(withHold(#"{"v":1,"frame":2.5}"#), .invalidClip, "holdSourceFrame.frame")
        rejects(withHold(#"{"v":1,"frame":"3"}"#), .invalidClip, "holdSourceFrame.frame")
        rejects(withHold(#"{"v":1,"frame":1e300}"#), .invalidClip, "holdSourceFrame.frame")
        rejects(withHold(#"{"v":1,"frame":300}"#), .sourceOutOfBounds, "holdSourceFrame.frame")
        rejects(withHold(#"{"v":1,"frame":3}"#, ["playbackRate": J(#"{"numerator":2,"denominator":1}"#)]), .invalidPlaybackRate, "playbackRate")
        var image = withHold(#"{"v":1,"frame":3}"#)
        image["assets"]?[0]?["kind"] = .string("image")
        rejects(image, .invalidClip, "holdSourceFrame")
    }

    func testAHeldClipLongerThanItsSourceIsValid() throws {
        // A hold reads one frame, so 900 frames of frame 299 fit a 300-frame source.
        let doc = try parse(withHold(#"{"v":1,"frame":299}"#, ["durationFrames": .number(900)]))
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].durationFrames, 900)
    }
}
