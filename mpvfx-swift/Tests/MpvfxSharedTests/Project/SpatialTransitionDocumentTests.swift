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

final class SpatialTransitionDocumentTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"Interview 1","source":"a.mov","durationFrames":300},
               {"id":"a2","kind":"video","name":"Interview 2","source":"b.mov","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}],
      "transitions":[{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30,"alignment":"centre"}]}]}}
    """#
    func document() throws -> NativeProjectDocument { try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json)) }

    func testSpatialOptionsAreValidatedAndRoundTripWithoutLosingUnknownFields() throws {
        for kind in [NativeCutTransitionKind.wipe, .push] {
            var doc = try document()
            var transition = doc.sequence.tracks[0].transitions![0]
            transition.kind = kind; transition.direction = .up; transition.softness = 0.35
            transition.object["futureOption"] = .string("preserved")
            doc.sequence.tracks[0].transitions = [transition]
            let saved = try serializeNativeProjectDocument(doc)
            let reopened = try parseNativeProjectDocument(try NativeJSONValue.parse(saved))
            XCTAssertEqual(reopened.sequence.tracks[0].transitions, [transition])
            let span = try XCTUnwrap(nativeCutTransitionSpans(reopened)["B"]?.incoming)
            XCTAssertEqual(span.direction, .up); XCTAssertEqual(span.softness, 0.35)
            XCTAssertEqual(span.incomingLead, 15); XCTAssertEqual(span.outgoingTail, 15)
        }
    }

    func testInvalidSpatialOptionsAreRefusedAtomically() throws {
        let doc = try document()
        for softness in [-0.1, 1.1, Double.infinity] {
            let result = try applyNativeCutTransitionCommand(doc, .setSoftness(id: "t1", softness: softness))
            XCTAssertFalse(result.ok); XCTAssertEqual(result.document, doc)
        }
        var raw = try NativeJSONValue.parse(Self.json)
        // A typed command cannot express an invalid direction; validate its persisted spelling separately.
        let bad = Self.json.replacingOccurrences(of: #""kind":"dissolve""#, with: #""kind":"wipe","direction":"diagonal""#)
        raw = try NativeJSONValue.parse(bad)
        XCTAssertThrowsError(try parseNativeProjectDocument(raw))
    }

    func testWipeAndPushRefuseInsufficientSourceHandles() throws {
        var doc = try document()
        doc.sequence.tracks[0].transitions = nil
        doc.sequence.tracks[0].clips[1].sourceInFrame = 0
        for kind in [NativeCutTransitionKind.wipe, .push] {
            let transition = NativeCutTransition(id: "spatial", cut: ("A", "B"), kind: kind, durationFrames: 30)
            let result = try applyNativeCutTransitionCommand(doc, .add(trackId: "v1", transition: transition))
            XCTAssertEqual(result.failure?.code, .insufficientHandles)
            XCTAssertEqual(result.document, doc)
        }
    }
}
