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
    static func json(locked: Bool = false, rampA: String = "") -> String {
        #"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a1","kind":"video","name":"One","source":"a.mov","durationFrames":600},
                   {"id":"a2","kind":"video","name":"Two","source":"b.mov","durationFrames":600}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","locked":\#(locked),"lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,\#(rampA)"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#
    }

    func editor(locked: Bool = false, rampA: String = "") throws -> TimelineEditor {
        try TimelineEditor(json: Self.json(locked: locked, rampA: rampA), engine: try KeyframeRuntime())
    }
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
        // Slow end covers the same 60 source frames in exactly 105 timeline frames.
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowEnd), keepLength: false), "\(String(describing: e.lastFailure))")
        let a = try clip(e, "A"), b = try clip(e, "B")
        XCTAssertEqual(a.durationFrames, 105, "the clip is resized to the ramp")
        XCTAssertEqual(b.startFrame, a.startFrame + a.durationFrames, "the next clip ripples")
        XCTAssertEqual(e.undoStack.count, 1, "one undo step")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(try clip(e, "A").durationFrames, 60)
        XCTAssertEqual(try clip(e, "B").startFrame, 60)
    }

    func testKeepLengthFalseThatNeedsAFractionalFrameIsRefusedAndChangesNothing() throws {
        let e = try editor()
        let before = e.document
        // Slow middle would need 91.5 frames to keep the source span.
        XCTAssertFalse(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle), keepLength: false))
        XCTAssertEqual(e.lastFailure?.code, .nonIntegralSourceBoundary)
        XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.undoStack.isEmpty)
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
        XCTAssertEqual(e.speedRamp(of: "A")?.isSupported, true)
    }

    // MARK: Point edits

    func testAddMoveEaseRemovePointEachAreOneLabelledUndoStep() throws {
        let e = try editor()
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowDown)))   // (0,1) (60,0.25)
        let base = try XCTUnwrap(e.speedRamp(of: "A"))
        var steps = e.undoStack.count

        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .addPoint(t: 30, speed: 2)))
        XCTAssertEqual(e.undoLabel, "Add speed point"); steps += 1; XCTAssertEqual(e.undoStack.count, steps)
        XCTAssertEqual(e.speedRamp(of: "A")?.points.map(\.t), [0, 30, 60])

        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .movePoint(index: 1, t: 40, speed: 3)))
        XCTAssertEqual(e.undoLabel, "Move speed point"); steps += 1; XCTAssertEqual(e.undoStack.count, steps)
        XCTAssertEqual(e.speedRamp(of: "A")?.points[1].t, 40)
        XCTAssertEqual(e.speedRamp(of: "A")?.points[1].speed, 3)

        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setEase(index: 1, ease: .hold)))
        XCTAssertEqual(e.undoLabel, "Change speed ease"); steps += 1; XCTAssertEqual(e.undoStack.count, steps)
        XCTAssertEqual(e.speedRamp(of: "A")?.points[1].ease, .hold)

        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .removePoint(index: 1)))
        XCTAssertEqual(e.undoLabel, "Remove speed point"); steps += 1; XCTAssertEqual(e.undoStack.count, steps)
        XCTAssertEqual(e.speedRamp(of: "A"), base, "removing the added point restores the shape")

        for _ in 0..<4 { XCTAssertTrue(e.undo()) }
        XCTAssertEqual(e.speedRamp(of: "A"), base)
    }

    func testInvalidPointEditsAreRefusedWithoutChange() throws {
        let e = try editor()
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .setShape(.slowDown)))
        let before = e.document, steps = e.undoStack.count
        let bad: [NativeSpeedRampCommand] = [
            .addPoint(t: 60, speed: 1),            // duplicate t: would divide by zero in speed(atClipFrame:)
            .addPoint(t: 0, speed: 1),             // duplicate t at the start
            .addPoint(t: 61, speed: 1),            // beyond the clip
            .addPoint(t: -1, speed: 1),
            .addPoint(t: 20, speed: 0),            // speed below 0.1
            .addPoint(t: 20, speed: 11),           // speed above 10
            .addPoint(t: 20, speed: .nan),
            .movePoint(index: 1, t: 0, speed: 1),  // onto its neighbour
            .movePoint(index: 5, t: 10, speed: 1), // no such point
            .removePoint(index: 9),
            .setEase(index: 9, ease: .hold),
        ]
        for command in bad {
            XCTAssertFalse(e.applySpeedRamp(clipId: "A", command), "\(command)")
            XCTAssertNotNil(e.lastFailure, "\(command)")
            XCTAssertEqual(e.document, before, "\(command)")
            XCTAssertEqual(e.undoStack.count, steps, "\(command)")
        }
    }

    func testRemovingTheLastPointIsRefused() throws {
        let e = try editor()
        XCTAssertTrue(e.applySpeedRamp(clipId: "A", .addPoint(t: 10, speed: 2)))
        let before = e.document
        XCTAssertFalse(e.applySpeedRamp(clipId: "A", .removePoint(index: 0)))
        XCTAssertEqual(e.document, before)
    }

    // MARK: Unsupported ramps

    static let futureRamp = #""speedRamp":{"v":2,"kind":"speed-ramp","points":[{"t":0,"speed":1}],"extra":"keep"},"#

    func testAnUnsupportedRampIsNotRampedAndEveryEditIsRefusedVerbatim() throws {
        let e = try editor(rampA: Self.futureRamp)
        let original = try clip(e, "A").speedRamp
        XCTAssertNotNil(original)
        XCTAssertFalse(e.isRamped("A"))
        XCTAssertNil(e.speedRamp(of: "A"))
        let before = e.document
        XCTAssertFalse(e.applySpeedRamp(clipId: "A", .setShape(.slowMiddle)))
        XCTAssertFalse(e.applySpeedRamp(clipId: "A", .clear))
        XCTAssertFalse(e.toggleSpeedRamp(clipId: "A"))
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(try clip(e, "A").speedRamp, original, "the unknown ramp round-trips untouched")
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testAnUnsupportedRampOnAnotherClipDoesNotBlockEditingTheNeighbour() throws {
        let e = try editor(rampA: Self.futureRamp)
        XCTAssertTrue(e.applySpeedRamp(clipId: "B", .setShape(.slowMiddle)))
        XCTAssertTrue(e.isRamped("B"))
        XCTAssertFalse(e.isRamped("A"))
    }

    func testEditingAMissingClipIsRefused() throws {
        let e = try editor()
        XCTAssertFalse(e.applySpeedRamp(clipId: "nope", .setShape(.slowMiddle)))
        XCTAssertTrue(e.undoStack.isEmpty)
    }
}
