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

/// Speed ramps in the document: round trip, byte identity, one test per validator rule, and what trim and split do to
/// a ramped clip. Uses `clip:audio` (120 frames of a 900-frame asset) of the clip-command fixture.
final class NativeSpeedRampDocumentTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    let audio = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:a1", clipId: "clip:audio")
    let bezier = NativeInterpolation.cubicBezier(.init(x1: 0.42, y1: 0, x2: 0.58, y2: 1))

    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeProjectDocument) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withRamp(_ ramp: NativeSpeedRamp?) throws -> NativeProjectDocument {
        var d = try parse(J(clipCommandsFixtureJSON))
        mutateClip(&d, "clip:audio") { $0.speedRamp = ramp }
        return try parse(try NativeJSONValue.from(d))
    }
    func rawRamp(_ ramp: String) -> NativeJSONValue {
        var d = J(clipCommandsFixtureJSON)
        d["sequence"]?["tracks"]?[2]?["clips"]?[0]?["speedRamp"] = J(ramp)
        return d
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func assertRefused(_ ramp: String, path: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(rawRamp(ramp), file: file, line: line)
        XCTAssertTrue(found.contains { $0.code == .invalidSpeedRamp && $0.path.hasSuffix(path) }, "\(path): \(found)", file: file, line: line)
    }

    func testRampSavesAndReopensUnchanged() throws {
        let doc = try withRamp(NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 60, speed: 0.5, ease: bezier)]))
        let text = try serialize(doc)
        XCTAssertTrue(text.contains("\"speedRamp\""), text)
        let reopened = try parse(J(text))
        XCTAssertEqual(reopened, doc)
        XCTAssertEqual(try serialize(reopened), text)
    }

    func testDocumentWithoutRampOpensAndSavesByteIdentical() throws {
        let saved = try serializeNativeProjectDocument(J(clipCommandsFixtureJSON), engine: engine)
        XCTAssertFalse(saved.contains("speedRamp"))
        XCTAssertEqual(Array(try serialize(try parse(J(saved))).utf8), Array(saved.utf8))
    }

    func testValidatorRules() {
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[]}"#, path: "points")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":10,"speed":1},{"t":10,"speed":2}]}"#, path: "points[1].t")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":20,"speed":1},{"t":10,"speed":2}]}"#, path: "points[1].t")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":1},{"t":121,"speed":2}]}"#, path: "points[1].t")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":-1,"speed":1}]}"#, path: "points[0].t")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":0.05}]}"#, path: "points[0].speed")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":10.5}]}"#, path: "points[0].speed")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":1,"ease":{"type":"wobble"}}]}"#, path: "points[0].ease")
        let many = (0..<65).map { #"{"t":\#($0),"speed":1}"# }.joined(separator: ",")
        assertRefused(#"{"v":1,"kind":"speed-ramp","points":[\#(many)]}"#, path: "points")
        assertRefused(#"{"kind":"speed-ramp"}"#, path: "speedRamp")
    }

    func testUnknownVersionOrKindStaysUnchangedAndIsNotInterpreted() throws {
        for raw in [#"{"v":2,"kind":"speed-ramp","points":"future"}"#, #"{"v":1,"kind":"curve-ramp","anything":[1]}"#] {
            let doc = try parse(rawRamp(raw))
            let ramp = try XCTUnwrap(findClip(doc, "clip:audio")?.speedRamp)
            XCTAssertFalse(ramp.isSupported)
            XCTAssertEqual(doc.unsupportedSpeedRampCount, 1)
            XCTAssertNotNil(doc.undrawnElementLayersNotice)
            XCTAssertEqual(try parse(J(try serialize(doc))), doc)
        }
    }

    // MARK: trim and split

    func testTrimOutRefusesWhatTheRampedSourceCannotCover() throws {
        // 5x for the whole clip: 180 frames reads 900 source frames (the asset's end), 181 would read past it.
        let doc = try withRamp(NativeSpeedRamp(points: [.init(t: 0, speed: 5)]))
        let ok = try applyNativeProjectClipCommand(doc, .trimOut(address: audio, endFrameExclusive: 180), engine: engine)
        XCTAssertTrue(ok.ok, "\(String(describing: ok.failure))")
        let past = try applyNativeProjectClipCommand(doc, .trimOut(address: audio, endFrameExclusive: 181), engine: engine)
        XCTAssertEqual(past.failure?.code, .invalidTrim)
    }

    func testTrimOutKeepsTheSpeedCurveUpToTheCut() throws {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1, ease: bezier), .init(t: 100, speed: 3)])
        let r = try applyNativeProjectClipCommand(try withRamp(ramp), .trimOut(address: audio, endFrameExclusive: 50), engine: engine)
        let trimmed = try XCTUnwrap(findClip(r.document, "clip:audio")?.speedRamp)
        for f in stride(from: 0.0, through: 50, by: 2.5) {
            XCTAssertEqual(trimmed.sourcePosition(atClipFrame: f), ramp.sourcePosition(atClipFrame: f), accuracy: 1e-3, "frame \(f)")
        }
        XCTAssertEqual(trimmed.speed(atClipFrame: 50), ramp.speed(atClipFrame: 50), accuracy: 1e-6)
    }

    func testSlicedEaseKeepsTheCurveInEverySegmentKind() {
        for ease in [NativeInterpolation.linear, .hold, bezier] {
            let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 0.5), .init(t: 40, speed: 2, ease: ease), .init(t: 100, speed: 4, ease: ease),
                                                .init(t: 140, speed: 1)])
            for (from, until) in [(10.0, 70.0), (50.0, 120.0), (45.0, 90.0), (0, 20), (30, 140)] {
                let part = ramp.sliced(from: from, until: until)
                for f in stride(from: 0.0, through: until - from, by: 1.5) {
                    XCTAssertEqual(part.sourcePosition(atClipFrame: f),
                                   ramp.sourcePosition(atClipFrame: from + f) - ramp.sourcePosition(atClipFrame: from),
                                   accuracy: 1e-3, "\(ease) \(from)...\(until) at \(f)")
                }
            }
        }
    }

    func testSplitKeepsTheSourcePositionContinuousAndBothHalvesOnTheCurve() throws {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1, ease: bezier), .init(t: 100, speed: 3)])
        let r = try applyNativeProjectClipCommand(try withRamp(ramp), .split(address: audio, splitFrame: 50), engine: engine)
        XCTAssertTrue(r.ok, "\(String(describing: r.failure))")
        let tracks = r.document.sequence.tracks.flatMap(\.clips).filter { $0.assetId == "asset:audio" }
        let (left, right) = (tracks[0], tracks[1])
        let cut = ramp.sourcePosition(atClipFrame: 50)
        XCTAssertEqual(sourceFrameValue(.init(sourceInFrame: right.sourceInFrame, sourceInFraction: right.sourceInFraction)), cut, accuracy: 1e-6)
        for f in stride(from: 0.0, through: 50, by: 5) {
            XCTAssertEqual(left.speedRamp!.sourcePosition(atClipFrame: f), ramp.sourcePosition(atClipFrame: f), accuracy: 1e-3)
        }
        for f in stride(from: 0.0, through: 70, by: 5) {
            XCTAssertEqual(right.speedRamp!.sourcePosition(atClipFrame: f), ramp.sourcePosition(atClipFrame: 50 + f) - cut, accuracy: 1e-3)
        }
    }
}
