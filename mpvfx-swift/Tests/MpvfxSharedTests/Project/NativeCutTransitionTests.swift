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

/// Cut transitions in `project.json` (issue #265): round trip, the validator's typed issues, the handle refusal,
/// entries from a newer version, and the edit commands.
final class NativeCutTransitionTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    /// Two touching clips on one track at 30 fps: "Interview 1" [0, 60) from source 30 (210 frames after its out
    /// point), "Interview 2" [60, 120) from source `bIn` (that many frames before its in point).
    static func json(transitions: String? = nil, bIn: Int = 30, bStart: Int = 60) -> String {
        let list = transitions.map { #","transitions":[\#($0)]"# } ?? ""
        return #"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a1","kind":"video","name":"Interview 1","source":"a.mov","durationFrames":300},
                   {"id":"a2","kind":"video","name":"Interview 2","source":"b.mov","durationFrames":300}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"B","assetId":"a2","startFrame":\#(bStart),"durationFrames":60,"sourceInFrame":\#(bIn),"muted":false,"effects":[],"parameterTracks":[]}]\#(list)}]}}
        """#
    }
    static let dissolve = #"{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30,"alignment":"centre"}"#

    func parse(_ text: String) throws -> NativeProjectDocument { try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: engine) }
    func save(_ d: NativeProjectDocument) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func issues(_ text: String) throws -> [NativeProjectDocumentValidationIssue] {
        validateNativeProjectDocument(try NativeJSONValue.parse(text), engine: engine)
    }
    func entry(_ fields: String) -> String { #"{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30\#(fields)}"# }

    // MARK: A1

    func testA1ADissolveSavesReopensAndValidatesUnchanged() throws {
        let doc = try parse(Self.json(transitions: Self.dissolve))
        let saved = try save(doc)
        let reopened = try parse(saved)
        XCTAssertEqual(reopened, doc)
        XCTAssertEqual(try save(reopened), saved, "a second save writes the same bytes")
        XCTAssertEqual(reopened.sequence.tracks[0].cutTransitions.first?.kind, .dissolve)
        XCTAssertEqual(reopened.sequence.tracks[0].cutTransitions.first?.durationFrames, 30)
        XCTAssertEqual(validateNativeProjectDocument(try NativeJSONValue.parse(saved), engine: engine), [])
    }

    func testA1ADocumentWithoutTransitionsIsByteIdenticalAfterSave() throws {
        let saved = try save(try parse(Self.json()))
        XCTAssertFalse(saved.contains("transitions"), "no key is added")
        XCTAssertEqual(try save(try parse(saved)), saved)
        XCTAssertEqual(saved, try save(try parse(saved)), "save of a saved document changes no byte")
    }

    // MARK: A2

    func assertIssue(_ entries: String, _ code: NativeProjectDocumentValidationCode, _ text: String, bStart: Int = 60,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try issues(Self.json(transitions: entries, bStart: bStart))
        XCTAssertTrue(found.contains { $0.code == code && $0.message.contains(text) }, "\(found)", file: file, line: line)
        XCTAssertThrowsError(try parse(Self.json(transitions: entries, bStart: bStart)), file: file, line: line)
    }

    func testA2UnknownClipIds() throws {
        try assertIssue(#"{"v":1,"id":"t1","fromClipId":"A","toClipId":"Z","kind":"dissolve","durationFrames":30}"#,
                        .missingReference, "Clip Z is not on track")
    }

    func testA2ClipsWithAGapOfOneFrame() throws {
        try assertIssue(Self.dissolve, .transitionClipsNotAdjacent, "do not touch", bStart: 61)
    }

    func testA2TwoTransitionsOnOneCut() throws {
        let second = #"{"v":1,"id":"t2","fromClipId":"A","toClipId":"B","kind":"dip","durationFrames":10}"#
        try assertIssue("\(Self.dissolve),\(second)", .duplicateTransition, "already has a transition")
    }

    func testA2DurationNotAPositiveWholeNumberOrLongerThanAClip() throws {
        for bad in ["0", "-3", "2.5", "\"30\""] {
            try assertIssue(#"{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dip","durationFrames":\#(bad)}"#,
                            .invalidTransition, "positive whole number")
        }
        try assertIssue(#"{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dip","durationFrames":61}"#,
                        .invalidTransition, "longer than clip A")
    }

    func testA2NonFiniteNumbers() throws {
        var doc = try NativeJSONValue.parse(Self.json(transitions: Self.dissolve))
        doc["sequence"]?["tracks"]?[0]?["transitions"]?[0]?["durationFrames"] = .number(.infinity)
        XCTAssertTrue(validateNativeProjectDocument(doc, engine: engine).contains { $0.code == .invalidTransition && $0.message.contains("finite") })
        doc["sequence"]?["tracks"]?[0]?["transitions"]?[0]?["durationFrames"] = .number(.nan)
        XCTAssertTrue(validateNativeProjectDocument(doc, engine: engine).contains { $0.code == .invalidTransition })
    }

    func testA2BadColorAlignmentVersionAndShape() throws {
        try assertIssue(entry(#","kind":"dip","color":"black""#).replacingOccurrences(of: #""kind":"dissolve","#, with: ""),
                        .invalidTransition, "#RGB, #RRGGBB or #RRGGBBAA")
        try assertIssue(entry(#","alignment":"middle""#), .invalidTransition, "centre, endsAtCut or startsAtCut")
        try assertIssue(#"{"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30}"#, .invalidTransition, "version v")
        try assertIssue(#""dissolve""#, .invalidTransition, "must be an object")
        let notArray = Self.json().replacingOccurrences(of: #""parameterTracks":[]}]}"#, with: #""parameterTracks":[]}],"transitions":{}}"#)
        XCTAssertTrue(try issues(notArray).contains { $0.message == "Transitions must be an array" })
    }

    // MARK: A3

    func testA3ADissolveWithTooLittleHandleIsRefusedWithTheClipNameAndFrames() throws {
        let doc = try parse(Self.json(bIn: 6))
        let add = NativeCutTransition(id: "t1", cut: ("A", "B"), kind: .dissolve, durationFrames: 24)
        let r = try applyNativeCutTransitionCommand(doc, .add(trackId: "v1", transition: add), engine: engine)
        XCTAssertEqual(r.failure?.code, .insufficientHandles)
        XCTAssertEqual(r.failure?.message, #"Clip "Interview 2" has 6 frames of media before its in point; this dissolve needs 12"#)
        XCTAssertEqual(r.document, doc, "nothing in the document changes")
        var late = add; late.alignment = .startsAtCut
        let tail = try parse(Self.json(bIn: 6).replacingOccurrences(of: #""sourceInFrame":30"#, with: #""sourceInFrame":234"#))
        XCTAssertEqual(try applyNativeCutTransitionCommand(tail, .add(trackId: "v1", transition: late), engine: engine).failure?.message,
                       #"Clip "Interview 1" has 6 frames of media after its out point; this dissolve needs 24"#)
    }

    func testA3ADipNeedsNoHandles() throws {
        let doc = try parse(Self.json(bIn: 0).replacingOccurrences(of: #""sourceInFrame":30"#, with: #""sourceInFrame":240"#))
        let dip = NativeCutTransition(id: "t1", cut: ("A", "B"), kind: .dip, durationFrames: 30)
        XCTAssertTrue(try applyNativeCutTransitionCommand(doc, .add(trackId: "v1", transition: dip), engine: engine).ok)
        let r = try applyNativeCutTransitionCommand(try parse(Self.json(transitions: Self.dissolve, bIn: 6).replacingOccurrences(of: #""durationFrames":30,"alignment""#, with: #""durationFrames":12,"alignment""#)),
                                                    .setLength(id: "t1", durationFrames: 14), engine: engine)
        XCTAssertEqual(r.failure?.code, .insufficientHandles, "lengthening past the handle is refused too")
    }

    // MARK: A8

    func testA8AnUnknownKindIsKeptDrawnAsAHardCutAndNoticedOnce() throws {
        let future = #"{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"pageCurl","durationFrames":30,"curl":{"angle":45}}"#
        let newer = #"{"v":2,"id":"t2","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":"long"}"#
        let doc = try parse(Self.json(transitions: "\(future),\(newer)"))
        let saved = try save(doc)
        XCTAssertTrue(saved.contains(#""kind": "pageCurl""#) && saved.contains(#""angle": 45"#) && saved.contains(#""v": 2"#),
                      "both entries are saved unchanged")
        XCTAssertEqual(try save(try parse(saved)), saved)
        XCTAssertTrue(nativeCutTransitionSpans(doc).isEmpty, "nothing is drawn: the cut stays hard")
        XCTAssertEqual(doc.openNotices, ["2 transitions from a newer version of the editor are kept in the project and drawn as hard cuts."])
        XCTAssertEqual(try parse(Self.json(transitions: future)).openNotices,
                       ["1 transition from a newer version of the editor is kept in the project and drawn as a hard cut."])
        XCTAssertEqual(try parse(Self.json(transitions: Self.dissolve)).openNotices, [])
    }

    // MARK: Commands, timing

    func testEditCommandsAreEachOneRestorableStep() throws {
        let doc = try parse(Self.json(transitions: Self.dissolve))
        let steps: [NativeCutTransitionCommand] = [.setLength(id: "t1", durationFrames: 20), .setKind(id: "t1", kind: .dip),
                                                   .setAlignment(id: "t1", alignment: .endsAtCut), .setColor(id: "t1", color: "#ffffff"),
                                                   .remove(id: "t1")]
        for step in steps {
            guard case .success(let next, let inverse) = try applyNativeCutTransitionCommand(doc, step, engine: engine) else {
                return XCTFail("\(step) refused")
            }
            XCTAssertNotEqual(next, doc, "\(step)")
            XCTAssertEqual(try applyNativeProjectClipCommand(next, inverse, engine: engine).document, doc, "undo of \(step) restores it")
        }
        let removed = try applyNativeCutTransitionCommand(doc, .remove(id: "t1"), engine: engine).document
        XCTAssertNil(removed.sequence.tracks[0].transitions, "the last removal leaves the key absent")
        XCTAssertEqual(try applyNativeCutTransitionCommand(doc, .remove(id: "nope"), engine: engine).failure?.code, .missingTransition)
    }

    func testSpansFollowTheAlignmentAndMixLinearly() throws {
        let spans = nativeCutTransitionSpans(try parse(Self.json(transitions: Self.dissolve)))
        let s = try XCTUnwrap(spans["B"]?.incoming)
        XCTAssertEqual([s.startFrame, s.cutFrame, s.endFrame], [45, 60, 75])
        XCTAssertEqual(spans["A"]?.tail, 15); XCTAssertEqual(spans["B"]?.lead, 15)
        XCTAssertEqual(s.incomingMix(atFrame: 45).opacity, 0); XCTAssertEqual(s.incomingMix(atFrame: 60).opacity, 0.5)
        XCTAssertEqual(s.outgoingMix(atFrame: 60), .none, "the outgoing clip stays at full opacity")
        XCTAssertEqual(s.outgoingGain(atFrame: 60) * s.outgoingGain(atFrame: 60) + s.incomingGain(atFrame: 60) * s.incomingGain(atFrame: 60),
                       1, accuracy: 1e-12, "equal power")
        let odd = nativeCutTransitionRange(cut: 60, length: 7, alignment: .centre)
        XCTAssertEqual([odd.start, odd.end], [57, 64], "the extra frame of an odd length goes after the cut")
    }
}
