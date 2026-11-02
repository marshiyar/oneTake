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
@testable import MpvfxTimeline
@testable import MpvfxShared
import OneTakeKeyframes

/// Speed ramp edits on the timeline editor (issue #271): each edit is one undo step that restores the ramp exactly,
/// a locked track is refused, the ramp key toggles, and a length-changing edit ripples the next clip in one step.
final class TimelineSpeedRampEditTests: XCTestCase {
    /// Two touching clips (A 0..60, B 60..120) on one track with plenty of media, plus a locked track with one clip.
    static func json(locked: Bool = false) -> String {
        #"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a1","kind":"video","name":"One","source":"a.mov","durationFrames":600},
                   {"id":"a2","kind":"video","name":"Two","source":"b.mov","durationFrames":600}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","locked":\#(locked),"lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#
    }

    func editor(locked: Bool = false) throws -> TimelineEditor { try TimelineEditor(json: Self.json(locked: locked), engine: try KeyframeRuntime()) }
    func clip(_ e: TimelineEditor, _ id: String) throws -> NativeProjectClip { try XCTUnwrap(e.clip(id)?.clip) }

    func testApplyingAShapeIsOneUndoStepAndUndoRestoresTheRamp() throws {
        let e = try editor()
        let before = try clip(e, "A")
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle)))
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Set speed shape")
        XCTAssertNotNil(e.speedRamp(of: "A"))
        XCTAssertTrue(e.undo())
        let after = try clip(e, "A")
        XCTAssertEqual(after.speedRamp, before.speedRamp)
        XCTAssertEqual(after.durationFrames, before.durationFrames)
        XCTAssertNil(e.speedRamp(of: "A"))
    }

    func testUndoRestoresAnExistingRampExactly() throws {
        let e = try editor()
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowEnd)))
        let ramped = try XCTUnwrap(e.speedRamp(of: "A"))
        let steps = e.undoStack.count
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.speedUp)))
        XCTAssertNotEqual(e.speedRamp(of: "A"), ramped)
        XCTAssertEqual(e.undoStack.count, steps + 1, "one undo step")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.speedRamp(of: "A"), ramped, "undo restores the earlier ramp exactly")
    }

    func testALockedTrackIsRefusedAndNothingChanges() throws {
        let e = try editor(locked: true)
        let before = e.document
        XCTAssertFalse(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle)))
        XCTAssertEqual(e.lastFailure?.message, "Track is locked")
        XCTAssertFalse(e.toggleSpeedRamp(clipId: "A"))
        XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testToggleAddsThenClears() throws {
        let e = try editor()
        XCTAssertFalse(e.isRamped("A"))
        XCTAssertTrue(e.toggleSpeedRamp(clipId: "A"))
        XCTAssertTrue(e.isRamped("A"))
        XCTAssertEqual(e.undoLabel, "Set speed shape")
        XCTAssertTrue(e.toggleSpeedRamp(clipId: "A"))
        XCTAssertFalse(e.isRamped("A"))
        XCTAssertNil(e.speedRamp(of: "A"))
        XCTAssertEqual(e.undoLabel, "Remove speed ramp")
    }

    func testKeepLengthFalseChangesTheClipAndRipplesTheNextClipInOneStep() throws {
        let e = try editor()
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle), keepLength: false))
        let a = try clip(e, "A"), b = try clip(e, "B")
        XCTAssertNotEqual(a.durationFrames, 60, "the clip is resized to the ramp")
        XCTAssertEqual(b.startFrame, a.startFrame + a.durationFrames, "the next clip ripples")
        XCTAssertEqual(e.undoStack.count, 1, "one undo step")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(try clip(e, "A").durationFrames, 60)
        XCTAssertEqual(try clip(e, "B").startFrame, 60)
    }

    func testKeepLengthTrueLeavesTheLengthAndTheNextClip() throws {
        let e = try editor()
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle), keepLength: true))
        XCTAssertEqual(try clip(e, "A").durationFrames, 60)
        XCTAssertEqual(try clip(e, "B").startFrame, 60)
    }

    func testRampedAndRampLookups() throws {
        let e = try editor()
        XCTAssertFalse(e.isRamped("A"))
        XCTAssertNil(e.speedRamp(of: "A"))
        XCTAssertNil(e.speedRamp(of: "missing"))
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.speedUp)))
        XCTAssertTrue(e.isRamped("A"))
        XCTAssertFalse(e.isRamped("B"))
        XCTAssertEqual(e.speedRamp(of: "A")?.points.last?.t, 60)
    }
}
