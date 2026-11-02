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

/// `clip.beats.analysis` (#290): marks found by analysis are kept apart from hand-placed ones, optional, omitted when
/// absent (a document without them saves byte for byte as before), and every bad value is a typed issue.
final class NativeClipBeatAnalysisTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }

    func document(beats: String?) -> NativeJSONValue {
        let beatsJSON = beats.map { #","beats":\#($0)"# } ?? ""
        return J("""
        {"schemaVersion":1,"mediaEngine":"native","id":"project:beats","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"asset:music","kind":"audio","name":"music.wav","source":"music.wav","durationFrames":300}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:a1","kind":"audio","clips":[
           {"id":"clip:music","assetId":"asset:music","startFrame":0,"durationFrames":120,"sourceInFrame":0,"effects":[],"parameterTracks":[]\(beatsJSON)}]}]}}
        """)
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func rejects(_ beats: String, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(document(beats: beats), file: file, line: line)
        XCTAssertTrue(found.contains { $0.code == .invalidClip && $0.path.hasSuffix(path) || $0.code == .sourceOutOfBounds && $0.path.hasSuffix(path) },
                      "\(found)", file: file, line: line)
    }
    private static let analysed = #"{"v":1,"frames":[5],"analysis":{"frames":[15,30,45],"strengths":[0.9,0.5,0.7],"sensitivity":0.5,"every":1}}"#

    func testAHandPlacedMarksDocumentSavesWithoutAnalysisByteForByte() throws {
        let saved = try serialize(document(beats: #"{"v":1,"frames":[10,20]}"#))
        XCTAssertFalse(saved.contains("analysis"))
        XCTAssertEqual(try serialize(J(saved)), saved)
        XCTAssertNil(try parse(J(saved)).sequence.tracks[0].clips[0].beats?.analysis)
    }

    func testAnalysedMarksRoundTripAndStayApartFromHandMarks() throws {
        let saved = try serialize(document(beats: Self.analysed))
        XCTAssertEqual(try serialize(J(saved)), saved, "open and save again: the same bytes")
        let beats = try XCTUnwrap(try parse(J(saved)).sequence.tracks[0].clips[0].beats)
        XCTAssertEqual(beats.frames, [5])
        XCTAssertEqual(beats.analysis, NativeBeatAnalysis(frames: [15, 30, 45], strengths: [0.9, 0.5, 0.7], sensitivity: 0.5, every: 1))
        XCTAssertEqual(beats.allFrames, [5, 15, 30, 45])
    }

    func testStrengthsAreOptional() throws {
        let saved = try serialize(document(beats: #"{"v":1,"frames":[],"analysis":{"frames":[15,30],"sensitivity":0.25,"every":2}}"#))
        XCTAssertFalse(saved.contains("strengths"), "left out when none were recorded")
        XCTAssertEqual(try parse(J(saved)).sequence.tracks[0].clips[0].beats?.analysis?.every, 2)
    }

    func testVisibleBeatFramesIncludeAnalysedMarks() throws {
        let clip = try parse(document(beats: Self.analysed)).sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.visibleBeatFrames.map(\.source), [5, 15, 30, 45])
        XCTAssertEqual(clip.visibleBeatFrames.map(\.timeline), [5, 15, 30, 45])
    }

    func testAnUnknownBeatVersionKeepsTheAnalysisKeyUnread() throws {
        let beats = #"{"v":2,"marks":[1],"analysis":{"anything":true}}"#
        let clip = try parse(document(beats: beats)).sequence.tracks[0].clips[0]
        XCTAssertNil(clip.beats?.analysis)
        XCTAssertEqual(clip.visibleBeatFrames.count, 0)
        XCTAssertTrue(try serialize(document(beats: beats)).contains("\"anything\""))
    }

    func testBadAnalysisValuesAreTypedIssues() {
        rejects(#"{"v":1,"frames":[],"analysis":"yes"}"#, "analysis")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[30,15],"sensitivity":0.5,"every":1}}"#, "analysis.frames[1]")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[15.5],"sensitivity":0.5,"every":1}}"#, "analysis.frames[0]")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[300],"sensitivity":0.5,"every":1}}"#, "analysis.frames[0]")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[15],"strengths":[0.5,0.6],"sensitivity":0.5,"every":1}}"#, "analysis.strengths")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[15],"strengths":[1.5],"sensitivity":0.5,"every":1}}"#, "analysis.strengths[0]")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[15],"sensitivity":2,"every":1}}"#, "analysis.sensitivity")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[15],"sensitivity":0.5,"every":3}}"#, "analysis.every")
        rejects(#"{"v":1,"frames":[],"analysis":{"frames":[15],"sensitivity":0.5}}"#, "analysis.every")
    }
}
