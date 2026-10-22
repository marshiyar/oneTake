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
import Foundation
import XCTest
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

final class TimelineReplaceMediaTests: XCTestCase {
    func make(_ edit: (inout NativeProjectClip) -> Void = { _ in }) throws -> TimelineEditor {
        let engine = try? KeyframeRuntime()
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(TimelineChunk6Tests.json), engine: engine)
        edit(&doc.sequence.tracks[0].clips[0])
        return try TimelineEditor(json: serializeNativeProjectDocument(doc, engine: engine), engine: engine)
    }

    func asset(_ frames: Double = 600, kind: NativeProjectAssetKind = .video) -> NativeProjectAsset {
        var a = NativeProjectAsset(id: "replacement", kind: kind, name: "New take", source: "new.mov", durationFrames: frames)
        if kind != .audio { a.naturalSize = NativeMediaNaturalSize(width: 1080, height: 1920) }
        return a
    }

    /// A1: compare the complete serialized clip, including the existing grade and rotation keyframes.
    func testReplacementPreservesEveryAuthoredFieldAndUndoesInOneStep() throws {
        let e = try make { $0.sourceInFrame = 12; $0.staticParameters = ["transform.scaleX": .number(1.5), "layout.width": .number(320)] }
        let before = e.document
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var expected = try XCTUnwrap(e.clip("clip:a")?.clip)
        expected.assetId = "replacement"
        XCTAssertTrue(e.replaceMedia(clipId: "clip:a", asset: asset()))
        XCTAssertEqual(try encoder.encode(e.clip("clip:a")?.clip), try encoder.encode(Optional(expected)))
        XCTAssertEqual(e.clip("clip:a")?.clip, expected)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Replace media")
        let saved = try serializeNativeProjectDocument(e.document, engine: e.engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(saved), engine: e.engine), e.document)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.clip("clip:a")?.clip, expected)
    }

    /// A2: source in-point and 2x speed require 400 frames, despite a timeline length of only 180.
    func testTooShortReplacementReportsMissingFramesWithoutImportOrHistory() throws {
        let e = try make { $0.sourceInFrame = 40; $0.playbackRate = .init(numerator: 2, denominator: 1) }
        let before = e.document
        XCTAssertFalse(e.replaceMedia(clipId: "clip:a", asset: asset(399)))
        XCTAssertEqual(e.lastFailure?.message, "Replacement media is too short: missing 1 source frames")
        XCTAssertEqual(e.document, before); XCTAssertFalse(e.canUndo)
        XCTAssertTrue(e.replaceMedia(clipId: "clip:a", asset: asset(400)))
    }

    func testFractionalInPointAndRampUseTheSourceSpan() throws {
        let e = try make {
            $0.sourceInFrame = 10; $0.sourceInFraction = .init(numerator: 1, denominator: 2)
            $0.speedRamp = NativeSpeedRamp(points: [.init(t: 0, speed: 2)])
        }
        XCTAssertFalse(e.replaceMedia(clipId: "clip:a", asset: asset(370)))
        XCTAssertEqual(e.lastFailure?.message, "Replacement media is too short: missing 1 source frames")
        XCTAssertTrue(e.replaceMedia(clipId: "clip:a", asset: asset(371)))
    }

    func testHoldNeedsOnlyItsHeldSourceFrameAndAnImageHasNoSourceLimit() throws {
        let e = try make { $0.holdSourceFrame = NativeClipHold(frame: 50) }
        XCTAssertFalse(e.replaceMedia(clipId: "clip:a", asset: asset(50)))
        XCTAssertTrue(e.replaceMedia(clipId: "clip:a", asset: asset(51)))
        let still = try make()
        XCTAssertTrue(still.replaceMedia(clipId: "clip:a", asset: asset(1, kind: .image)))
    }

    func testLockedTrackAndIncompatibleMediaRefuseWithoutChangingTheDocument() throws {
        let e = try make()
        XCTAssertFalse(e.replaceMedia(clipId: "clip:a", asset: asset(kind: .audio)))
        XCTAssertFalse(e.canUndo)
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        let before = e.document, count = e.undoStack.count
        XCTAssertFalse(e.replaceMedia(clipId: "clip:a", asset: asset()))
        XCTAssertEqual(e.lastFailure?.message, "Track is locked")
        XCTAssertEqual(e.document, before); XCTAssertEqual(e.undoStack.count, count)
    }

    func testUntouchedSizeFollowsTheNewSource() throws {
        let e = try make()
        let before = e.defaultLayout(clipId: "clip:a")
        XCTAssertTrue(e.replaceMedia(clipId: "clip:a", asset: asset()))
        XCTAssertNotEqual(e.defaultLayout(clipId: "clip:a"), before)
        XCTAssertEqual(e.clip("clip:a")?.clip.staticParameters, nil)
    }
}
