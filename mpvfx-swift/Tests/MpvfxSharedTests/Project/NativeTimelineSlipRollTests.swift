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
// Slip (issue #87) and roll (issue #88) document commands. Fixture: clipCommandsFixtureJSON, where clip:first plays
// source 12..<132 at [0, 120) and clip:second plays source 132..<252 at [120, 240), both from a 900-frame video.
// A roll that shrinks clip:first slices its rotation track, which needs the real engine: those cases run in
// MpvfxTimelineTests (TimelineSlipRollTests).
import XCTest
@testable import MpvfxShared

final class NativeTimelineSlipRollTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    let second = clipAddress("clip:second")

    func fixture() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(clipCommandsFixtureJSON), engine: engine)
    }
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectClipCommand) throws -> NativeProjectClipCommandResult {
        try applyNativeProjectClipCommand(d, c, engine: engine)
    }
    func clip(_ d: NativeProjectDocument, _ id: String) throws -> NativeProjectClip { try XCTUnwrap(findClip(d, id)) }
    func roll(_ delta: Double) -> NativeProjectClipCommand {
        .roll(.init(outgoing: firstClipAddress, incoming: second, deltaFrames: delta))
    }
    func assertRejected(_ r: NativeProjectClipCommandResult, _ original: NativeProjectDocument, _ code: NativeProjectClipFailureCode,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.ok, file: file, line: line)
        XCTAssertEqual(r.document, original, "a rejection returns the unchanged input", file: file, line: line)
        XCTAssertEqual(r.failure?.code, code, file: file, line: line)
    }
    /// Every result must pass the validator: serialize re-validates, parse validates again.
    func assertValid(_ d: NativeProjectDocument, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try serializeNativeProjectDocument(d, engine: engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: engine), d, file: file, line: line)
    }

    /// clip:second re-pointed at a still or text asset refuses to slip.
    func assertNoSlip(_ kind: NativeProjectAssetKind, file: StaticString = #filePath, line: UInt = #line) throws {
        var original = try fixture()
        original.assets.append(NativeProjectAsset(id: "asset:still", kind: kind, name: "still", source: nil, durationFrames: 900))
        mutateClip(&original, "clip:second") { $0.assetId = "asset:still" }
        original = try parseNativeProjectDocument(original, engine: engine)
        XCTAssertNil(nativeSlipRange(original, second), "\(kind)", file: file, line: line)
        assertRejected(try apply(original, .slip(address: second, deltaFrames: 1)), original, .invalidSlip, file: file, line: line)
    }
    func assertRefused(_ command: NativeProjectClipCommand, _ code: NativeProjectClipFailureCode,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try fixture()
        assertRejected(try apply(original, command), original, code, file: file, line: line)
    }

    // MARK: Slip (#87)

    func testSlipByTenFramesChangesOnlyTheSourceInPoint() throws {
        let original = try fixture()
        let r = try apply(original, .slip(address: firstClipAddress, deltaFrames: 10))
        XCTAssertTrue(r.ok, "\(String(describing: r.failure))")
        var slipped = try clip(r.document, "clip:first"), before = try clip(original, "clip:first")
        XCTAssertEqual(slipped.sourceInFrame, 22)
        XCTAssertEqual(slipped.startFrame, 0); XCTAssertEqual(slipped.durationFrames, 120)
        slipped.sourceInFrame = before.sourceInFrame
        XCTAssertEqual(slipped, before, "nothing but the in-point changes, keyframes included")
        before = try clip(original, "clip:second")
        XCTAssertEqual(try clip(r.document, "clip:second"), before, "the neighbour stays put")
        try assertValid(r.document)
        let undo = try apply(r.document, try XCTUnwrap(r.inverse))
        XCTAssertEqual(undo.document, original)
    }

    func testSlipMovesTheSourceByTheFramesTimesThePlaybackRate() throws {
        var original = try fixture()
        mutateClip(&original, "clip:second") { $0.playbackRate = .init(numerator: 2, denominator: 1) }
        original = try parseNativeProjectDocument(original, engine: engine)
        let r = try apply(original, .slip(address: second, deltaFrames: 10))
        XCTAssertEqual(try clip(r.document, "clip:second").sourceInFrame, 152, "10 timeline frames at 2x are 20 source frames")
        try assertValid(r.document)
    }

    func testSlipClampsAtTheStartAndEndOfTheSource() throws {
        let original = try fixture()
        XCTAssertEqual(nativeSlipRange(original, firstClipAddress), -12...768, "12 frames before the in-point, 900 - 132 after the out-point")
        assertRejected(try apply(original, .slip(address: firstClipAddress, deltaFrames: -13)), original, .invalidSlip)
        assertRejected(try apply(original, .slip(address: firstClipAddress, deltaFrames: 769)), original, .invalidSlip)
        XCTAssertEqual(try clip(try apply(original, .slip(address: firstClipAddress, deltaFrames: -12)).document, "clip:first").sourceInFrame, 0)
        let atEnd = try apply(original, .slip(address: firstClipAddress, deltaFrames: 768)).document
        XCTAssertEqual(try clip(atEnd, "clip:first").sourceInFrame, 780)
        try assertValid(atEnd)
    }

    func testSlipRangeIsExactForAFractionalInPointAndRate() throws {
        var original = try fixture()
        mutateClip(&original, "clip:second") {
            $0.sourceInFrame = 12; $0.sourceInFraction = .init(numerator: 1, denominator: 2); $0.playbackRate = .init(numerator: 3, denominator: 2)
        }
        original = try parseNativeProjectDocument(original, engine: engine)
        // In-point 12.5 at 1.5 source frames per timeline frame: 8 frames back reach 0.5, 9 would pass 0.
        XCTAssertEqual(nativeSlipRange(original, second)?.lowerBound, -8)
        let r = try apply(original, .slip(address: second, deltaFrames: -8))
        XCTAssertEqual(try clip(r.document, "clip:second").sourceInFrame, 0)
        XCTAssertEqual(try clip(r.document, "clip:second").sourceInFraction, .init(numerator: 1, denominator: 2))
        assertRejected(try apply(original, .slip(address: second, deltaFrames: -9)), original, .invalidSlip)
    }

    func testStillsAndTextRefuseTheSlip() throws {
        try assertNoSlip(.image)
        try assertNoSlip(.element)
    }

    func testSlipRejectsHostileDeltasAndAddresses() throws {
        let original = try fixture()
        try assertRefused(.slip(address: firstClipAddress, deltaFrames: 0.5), .invalidSlip)
        try assertRefused(.slip(address: firstClipAddress, deltaFrames: .nan), .invalidSlip)
        try assertRefused(.slip(address: firstClipAddress, deltaFrames: .infinity), .invalidSlip)
        try assertRefused(.slip(address: firstClipAddress, deltaFrames: -.infinity), .invalidSlip)
        try assertRefused(.slip(address: firstClipAddress, deltaFrames: 1e300), .invalidSlip)
        assertRejected(try apply(original, .slip(address: clipAddress("clip:missing"), deltaFrames: 1)), original, .missingClip)
        XCTAssertNil(nativeSlipRange(original, clipAddress("clip:missing")))
    }

    // MARK: Roll (#88)

    func testRollByTwelveLengthensTheOutgoingClipAndShortensTheIncomingOne() throws {
        let original = try fixture()
        let r = try apply(original, roll(12))
        XCTAssertTrue(r.ok, "\(String(describing: r.failure))")
        let a = try clip(r.document, "clip:first"), b = try clip(r.document, "clip:second")
        XCTAssertEqual(a.startFrame, 0); XCTAssertEqual(a.durationFrames, 132); XCTAssertEqual(a.sourceInFrame, 12)
        XCTAssertEqual(b.startFrame, 132); XCTAssertEqual(b.durationFrames, 108); XCTAssertEqual(b.sourceInFrame, 144)
        XCTAssertEqual(b.startFrame + b.durationFrames, 240, "the sequence keeps its length")
        XCTAssertEqual(try clip(r.document, "clip:audio"), try clip(original, "clip:audio"), "every other clip stays")
        XCTAssertEqual(r.document.sequence.durationFrames, original.sequence.durationFrames)
        try assertValid(r.document)
        XCTAssertEqual(try apply(r.document, try XCTUnwrap(r.inverse)).document, original)
    }

    func testRollClampsAtTheSourceMediaAndAtOneFrame() throws {
        let original = try fixture()
        XCTAssertEqual(nativeRollRange(original, outgoing: firstClipAddress, incoming: second), -119...119, "each clip keeps one frame")
        assertRejected(try apply(original, roll(120)), original, .invalidRoll)
        assertRejected(try apply(original, roll(-120)), original, .invalidRoll)
        var tight = original
        mutateClip(&tight, "clip:first") { $0.sourceInFrame = 770 }   // 10 source frames left after its out-point
        mutateClip(&tight, "clip:second") { $0.sourceInFrame = 5 }    // 5 source frames before its in-point
        tight = try parseNativeProjectDocument(tight, engine: engine)
        XCTAssertEqual(nativeRollRange(tight, outgoing: firstClipAddress, incoming: second), -5...10)
        assertRejected(try apply(tight, roll(11)), tight, .invalidRoll)
        assertRejected(try apply(tight, roll(-6)), tight, .invalidRoll)
        let r = try apply(tight, roll(10))
        XCTAssertEqual(try clip(r.document, "clip:first").durationFrames, 130)
        try assertValid(r.document)
    }

    func testRollNeedsTwoClipsThatTouchOnOneTrack() throws {
        var gapped = try fixture()
        mutateClip(&gapped, "clip:second") { $0.startFrame = 130 }
        gapped = try parseNativeProjectDocument(gapped, engine: engine)
        XCTAssertNil(nativeRollRange(gapped, outgoing: firstClipAddress, incoming: second), "a gap behind the edge is not a cut")
        assertRejected(try apply(gapped, roll(5)), gapped, .invalidRoll)
        let original = try fixture()
        let audio = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:a1", clipId: "clip:audio")
        XCTAssertNil(nativeRollRange(original, outgoing: audio, incoming: second), "clips on two tracks")
        XCTAssertNil(nativeRollRange(original, outgoing: second, incoming: firstClipAddress), "the order is outgoing, then incoming")
        XCTAssertNil(nativeRollRange(original, outgoing: firstClipAddress, incoming: firstClipAddress))
    }

    func testRollRejectsHostileDeltasAndAddresses() throws {
        let original = try fixture()
        try assertRefused(roll(0.5), .invalidRoll)
        try assertRefused(roll(.nan), .invalidRoll)
        try assertRefused(roll(.infinity), .invalidRoll)
        try assertRefused(roll(1e300), .invalidRoll)
        let missing = NativeProjectClipCommand.roll(.init(outgoing: firstClipAddress, incoming: clipAddress("clip:missing"), deltaFrames: 1))
        assertRejected(try apply(original, missing), original, .missingClip)
    }

    func testAStillRollsWithoutASourceLimit() throws {
        var original = try fixture()
        original.assets.append(NativeProjectAsset(id: "asset:still", kind: .image, name: "still", source: nil, durationFrames: 900))
        mutateClip(&original, "clip:second") { $0.assetId = "asset:still"; $0.sourceInFrame = 0 }
        original = try parseNativeProjectDocument(original, engine: engine)
        XCTAssertEqual(nativeRollRange(original, outgoing: firstClipAddress, incoming: second), -119...119)
    }
}
