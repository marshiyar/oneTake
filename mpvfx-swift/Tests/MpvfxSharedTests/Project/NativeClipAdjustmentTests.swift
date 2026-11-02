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

/// `clip.adjustment` in the document (#326, A1): absent stays absent byte for byte, `true` round trips, and every bad
/// value is a typed issue.
final class NativeClipAdjustmentTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }

    /// The valid document plus an element asset and a clip of it on a second track.
    func withAdjustment(_ value: NativeJSONValue?, extra: [String: NativeJSONValue] = [:], assetKind: String = "element") -> NativeJSONValue {
        var d = validNativeDocument()
        d["assets"] = J(#"[{"id":"asset:camera-a","kind":"video","name":"camera-a.mov","durationFrames":300},{"id":"asset:adj","kind":"\#(assetKind)","name":"Adjustment","durationFrames":300}]"#)
        var clip = J(#"{"id":"clip:adj","assetId":"asset:adj","startFrame":0,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]}"#)
        if let value { clip["adjustment"] = value }
        for (k, v) in extra { clip[k] = v }
        let first = d["sequence"]?["tracks"]?[0] ?? .null
        d["sequence"]?["tracks"] = .array([first, J(#"{"id":"track:adj","kind":"video","clips":[]}"#)])
        d["sequence"]?["tracks"]?[1]?["clips"] = .array([clip])
        return d
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func rejects(_ d: NativeJSONValue, _ path: String = "adjustment", file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(d, file: file, line: line)
        XCTAssertTrue(found.contains { $0.code == .invalidClip && $0.path.hasSuffix(path) }, "\(found)", file: file, line: line)
    }

    func testA1ADocumentWithoutAdjustmentsOpensAndSavesByteIdentical() throws {
        let saved = try serialize(validNativeDocument())
        XCTAssertFalse(saved.contains("adjustment"))
        XCTAssertEqual(try serialize(J(saved)), saved)
        let plain = try serialize(withAdjustment(nil))
        XCTAssertFalse(plain.contains("adjustment\":"), "an ordinary element clip omits the field")
        XCTAssertEqual(try serialize(J(plain)), plain)
        XCTAssertEqual(try parse(J(plain)).schemaVersion, 1)
    }

    func testA1AnAdjustmentRoundTrips() throws {
        let saved = try serialize(withAdjustment(.bool(true)))
        XCTAssertEqual(J(saved)["sequence"]?["tracks"]?[1]?["clips"]?[0]?["adjustment"], .bool(true), saved)
        let clip = try parse(J(saved)).sequence.tracks[1].clips[0]
        XCTAssertTrue(clip.isAdjustment)
        XCTAssertEqual(try serialize(J(saved)), saved)
    }

    func testA1BadAdjustmentsAreTypedIssues() {
        rejects(withAdjustment(.string("yes")))
        rejects(withAdjustment(.number(1)))
        rejects(withAdjustment(.bool(true), assetKind: "image"))
        rejects(withAdjustment(.bool(true), extra: ["text": J(#"{"v":1,"content":"x"}"#)]))
        rejects(withAdjustment(.bool(true), extra: ["shape": J(#"{"v":1,"kind":"rect"}"#)]))
        rejects(withAdjustment(.bool(true), extra: ["generator": J(##"{"v":1,"kind":"color","color":"#fff"}"##)]))
    }
}
