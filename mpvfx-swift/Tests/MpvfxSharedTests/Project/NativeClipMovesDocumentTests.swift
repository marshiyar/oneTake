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
// `clip.moves` in the document (issue #273 A1, A5): round trip, byte identity, one test per validator rule, moves
// from a newer version kept and noticed, and the split and trim rules.
import XCTest
@testable import MpvfxShared

final class NativeClipMovesDocumentTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withMoves(_ moves: String) -> NativeJSONValue {
        var d = validNativeDocument(); d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["moves"] = J(moves); return d
    }
    /// The one issue the moves raise: its code and path (the clip is clips[0] of track 0, 90 frames long).
    func rejects(_ moves: String, at path: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(withMoves(moves)); XCTFail("accepted \(moves)", file: file, line: line) }
        catch let e as NativeProjectDocumentValidationError {
            XCTAssertEqual(e.issues.map(\.code), [.invalidMove], e.message, file: file, line: line)
            XCTAssertEqual(e.issues.first?.path, "sequence.tracks[0].clips[0].moves\(path)", file: file, line: line)
            XCTAssertTrue(e.message.contains(text), e.message, file: file, line: line)
        } catch { XCTFail("\(error)", file: file, line: line) }
    }

    // MARK: A1 round trip and byte identity

    func testA1EveryFieldRoundTripsAndTheSerializedMovesAreTheInput() throws {
        let json = #"{"in":{"amount":50,"direction":"up","ease":{"controlPoints":{"x1":0.1,"x2":0.9,"y1":0,"y2":1},"type":"cubic-bezier"},"frames":15,"kind":"slide"},"#
            + #""loop":{"amount":4,"ease":{"type":"linear"},"kind":"pulse","periodFrames":20},"out":{"frames":10,"kind":"spin"},"v":1}"#
        let doc = try parse(J(try serialize(withMoves(json))))
        let moves = try XCTUnwrap(doc.sequence.tracks[0].clips[0].moves)
        XCTAssertEqual(moves.inMove, NativeEdgeMove(kind: .slide, frames: 15, direction: .up, amount: 50,
                                                    ease: .cubicBezier(CubicBezierControlPoints(x1: 0.1, y1: 0, x2: 0.9, y2: 1))))
        XCTAssertEqual(moves.outMove, NativeEdgeMove(kind: .spin, frames: 10))
        XCTAssertEqual(moves.loop, NativeLoopMove(kind: .pulse, periodFrames: 20, amount: 4, ease: .linear))
        XCTAssertEqual(try NativeJSONValue.from(moves), J(json))
        XCTAssertEqual(NativeClipMoves(in: moves.inMove, out: moves.outMove, loop: moves.loop), moves, "typed writes store the same object")
    }

    func testA1ADocumentWithoutMovesOpensAndSavesByteIdentical() throws {
        let first = try serialize(validNativeDocument())
        XCTAssertFalse(first.contains("\"moves\""))
        XCTAssertEqual(try serialize(J(first)), first)
        XCTAssertNil(try parse(J(first)).sequence.tracks[0].clips[0].moves)
        XCTAssertEqual(try parse(J(first)).sequence.tracks[0].clips[0].moves, nil)
        let withOne = try serialize(withMoves(#"{"v":1,"in":{"kind":"rise","frames":12}}"#))
        XCTAssertEqual(try serialize(J(withOne)), withOne, "a document with moves saves byte-identical too")
        XCTAssertTrue(withOne.contains("\"schemaVersion\": 1"))
    }

    func testA1MovesFromANewerVersionOrKindAreKeptUnchangedNotDrawnAndNoticedOnce() throws {
        var d = withMoves(#"{"v":2,"in":{"kind":"warp","frames":"soon"},"extra":[1,2]}"#)
        d["sequence"]?["tracks"]?[0]?["clips"]?.append(J(
            #"{"id":"clip:b","assetId":"asset:camera-a","startFrame":100,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[],"moves":{"v":1,"in":{"kind":"focus","frames":5,"blur":3},"loop":{"kind":"float","periodFrames":10}}}"#))
        let first = try serialize(d)
        XCTAssertEqual(try serialize(J(first)), first, "kept byte for byte")
        let doc = try parse(J(first))
        let newer = try XCTUnwrap(doc.sequence.tracks[0].clips[0].moves)
        XCTAssertFalse(newer.isReadable); XCTAssertNil(newer.inMove)
        let unknownKind = try XCTUnwrap(doc.sequence.tracks[0].clips[1].moves)
        XCTAssertFalse(unknownKind.isReadable); XCTAssertNil(unknownKind.inMove)
        XCTAssertEqual(unknownKind.loop, NativeLoopMove(kind: .float, periodFrames: 10), "the known Loop still plays")
        XCTAssertEqual(try nativeClipMoveOffsets(doc.sequence.tracks[0].clips[0], clipFrame: 0, canvas: doc.canvas, engine: engine), .identity)
        XCTAssertEqual(doc.unreadableMovesClipCount, 2)
        XCTAssertEqual(doc.unreadableMovesNotice,
                       "Moves on 2 clips are from a newer version of the editor: they are kept in the project but not drawn in preview or export.")
        XCTAssertNil(try parse(withMoves(#"{"v":1,"out":{"kind":"drop","frames":3}}"#)).unreadableMovesNotice)
    }

    // MARK: A1 one test per validator rule

    func testA1RuleMovesMustBeAnObject() { rejects("[]", at: "", "Moves must be an object") }
    func testA1RuleMovesNeedAPositiveIntegerVersion() {
        rejects(#"{"in":{"kind":"slide","frames":3}}"#, at: ".v", "version v")
        rejects(#"{"v":"1"}"#, at: ".v", "version v")
        rejects(#"{"v":1.5}"#, at: ".v", "version v")
        rejects(#"{"v":0}"#, at: ".v", "version v")
    }
    func testA1RuleAMoveMustBeAnObject() {
        rejects(#"{"v":1,"in":"slide"}"#, at: ".in", "A move must be an object")
        rejects(#"{"v":1,"loop":5}"#, at: ".loop", "A loop move must be an object")
    }
    func testA1RuleAMoveNeedsAKind() {
        rejects(#"{"v":1,"out":{"frames":3}}"#, at: ".out.kind", "A move needs a kind")
        rejects(#"{"v":1,"in":{"kind":7,"frames":3}}"#, at: ".in.kind", "A move needs a kind")
        rejects(#"{"v":1,"loop":{"kind":"","periodFrames":4}}"#, at: ".loop.kind", "A move needs a kind")
    }
    func testA1RuleMoveFramesArePositiveIntegers() {
        for bad in ["0", "-3", "2.5", "\"10\"", "null"] {
            rejects(#"{"v":1,"in":{"kind":"grow","frames":\#(bad)}}"#, at: ".in.frames", "positive integer")
        }
    }
    func testA1RuleSlideDirectionIsAnEdge() {
        rejects(#"{"v":1,"in":{"kind":"slide","frames":3,"direction":"north"}}"#, at: ".in.direction", "left, right, up or down")
    }
    func testA1RuleOnlySlideTakesADirection() {
        rejects(#"{"v":1,"out":{"kind":"rise","frames":3,"direction":"left"}}"#, at: ".out.direction", "Only a slide move")
    }
    func testA1RuleAmountsStayInTheirKindsRange() {
        let cases = [("slide", "0"), ("slide", "201"), ("rise", "101"), ("drop", "-1"), ("grow", "100.5"), ("shrink", "0"),
                     ("spin", "0"), ("spin", "3601"), ("slide", "\"50\"")]
        for (kind, amount) in cases {
            rejects(#"{"v":1,"in":{"kind":"\#(kind)","frames":3,"amount":\#(amount)}}"#, at: ".in.amount", "range of a \(kind) move")
        }
        for (kind, amount) in [("float", "0"), ("pulse", "101"), ("sway", "181"), ("drift", "-2")] {
            rejects(#"{"v":1,"loop":{"kind":"\#(kind)","periodFrames":4,"amount":\#(amount)}}"#, at: ".loop.amount", "range of a \(kind) move")
        }
        XCTAssertNoThrow(try parse(withMoves(#"{"v":1,"in":{"kind":"spin","frames":3,"amount":-720},"loop":{"kind":"sway","periodFrames":4,"amount":180}}"#)))
    }
    func testA1RuleEaseIsAKeyframeInterpolation() {
        rejects(#"{"v":1,"in":{"kind":"slide","frames":3,"ease":"ease-in"}}"#, at: ".in.ease", "Move ease must be")
        rejects(#"{"v":1,"in":{"kind":"slide","frames":3,"ease":{"type":"bounce"}}}"#, at: ".in.ease", "Move ease must be")
        rejects(#"{"v":1,"out":{"kind":"slide","frames":3,"ease":{"type":"cubic-bezier","controlPoints":{"x1":0,"y1":0,"x2":1}}}}"#,
                at: ".out.ease", "Move ease must be")
    }
    func testA1RuleEaseControlPointsAreFiniteWithXWithinTheUnit() {
        rejects(#"{"v":1,"in":{"kind":"slide","frames":3,"ease":{"type":"cubic-bezier","controlPoints":{"x1":1.2,"y1":0,"x2":0.5,"y2":1}}}}"#,
                at: ".in.ease.controlPoints", "x1 and x2 within")
        rejects(#"{"v":1,"loop":{"kind":"float","periodFrames":4,"ease":{"type":"cubic-bezier","controlPoints":{"x1":0.2,"y1":0,"x2":-0.1,"y2":1}}}}"#,
                at: ".loop.ease.controlPoints", "x1 and x2 within")
    }
    func testA1RuleLoopPeriodIsAnEvenNumberOfFramesAtLeastTwo() {
        for bad in ["0", "1", "7", "2.5", "\"4\""] {
            rejects(#"{"v":1,"loop":{"kind":"float","periodFrames":\#(bad)}}"#, at: ".loop.periodFrames", "even number of frames")
        }
    }
    func testA1RuleInAndOutTogetherFitTheClip() {
        rejects(#"{"v":1,"in":{"kind":"slide","frames":60},"out":{"kind":"slide","frames":31}}"#, at: "", "must not be longer than the clip")
        XCTAssertNoThrow(try parse(withMoves(#"{"v":1,"in":{"kind":"slide","frames":60},"out":{"kind":"slide","frames":30}}"#)))
    }

    // MARK: A5 split and trim

    /// The 90-frame clip with an In of 20, an Out of 30 and a Loop, as an editor would hold it.
    func movedDocument() throws -> NativeProjectDocument {
        try parse(withMoves(#"{"v":1,"in":{"kind":"slide","frames":20,"direction":"right"},"out":{"kind":"shrink","frames":30},"loop":{"kind":"sway","periodFrames":8}}"#))
    }
    var address: NativeProjectClipAddress { .init(sequenceId: "sequence:main", trackId: "track:video-1", clipId: "clip:camera-a-1") }

    func testA5SplitKeepsInOnTheLeftPartOutOnTheRightAndLoopOnBoth() throws {
        let d = try movedDocument()
        let r = try applyNativeProjectClipCommand(d, .split(address: address, splitFrame: 40), engine: engine)
        XCTAssertNil(r.failure)
        let (left, right) = (r.document.sequence.tracks[0].clips[0], r.document.sequence.tracks[0].clips[1])
        XCTAssertEqual(left.moves?.inMove, NativeEdgeMove(kind: .slide, frames: 20, direction: .right)); XCTAssertNil(left.moves?.outMove)
        XCTAssertEqual(right.moves?.outMove, NativeEdgeMove(kind: .shrink, frames: 30)); XCTAssertNil(right.moves?.inMove)
        XCTAssertEqual(left.moves?.loop, right.moves?.loop); XCTAssertNotNil(left.moves?.loop)
        let back = try XCTUnwrap(r.inverse)
        XCTAssertEqual(try applyNativeProjectClipCommand(r.document, back, engine: engine).document, d, "the inverse restores the moves")
    }

    func testA5SplitShorterThanAMoveFitsItAndAPartWithoutMovesOmitsThem() throws {
        let d = try parse(withMoves(#"{"v":1,"in":{"kind":"slide","frames":20}}"#))
        let r = try applyNativeProjectClipCommand(d, .split(address: address, splitFrame: 8), engine: engine)
        XCTAssertEqual(r.document.sequence.tracks[0].clips[0].moves?.inMove?.frames, 8, "the In shrinks to the 8-frame left part")
        XCTAssertNil(r.document.sequence.tracks[0].clips[1].moves, "the right part has no move left: the key is omitted")
        let saved = try serializeNativeProjectDocument(r.document, engine: engine)
        XCTAssertEqual(saved.components(separatedBy: "\"moves\"").count - 1, 1, "only the left part stores moves")
    }

    func testA5TrimKeepsMovesOnTheEdgesAndShrinksThemInProportionWhenTheyNoLongerFit() throws {
        let d = try movedDocument()
        let shorter = try applyNativeProjectClipCommand(d, .trimOut(address: address, endFrameExclusive: 60), engine: engine)
        XCTAssertNil(shorter.failure)
        XCTAssertEqual(shorter.document.sequence.tracks[0].clips[0].moves, d.sequence.tracks[0].clips[0].moves, "60 frames still fit 20 + 30")
        let tight = try applyNativeProjectClipCommand(d, .trimIn(address: address, startFrame: 65), engine: engine)
        XCTAssertNil(tight.failure)
        let m = try XCTUnwrap(tight.document.sequence.tracks[0].clips[0].moves)
        XCTAssertEqual(m.inMove?.frames, 10); XCTAssertEqual(m.outMove?.frames, 15, "25 frames: 20:30 becomes 10:15")
        XCTAssertNotNil(m.loop)
    }
}
