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
import MpvfxShared
import OneTakeKeyframes

/// Applying a transition from the Transitions browser (issues #459, #268): which cut "the selected cut" is, the length
/// a new transition gets and how the media shortens or refuses it, replacing the transition already on a cut, and that
/// every apply, however many cuts it covers, is one undo step.
final class TimelineTransitionApplyTests: XCTestCase {
    /// Three touching clips on one track, cuts at frames 60 and 120. Clip C has `cSourceIn` frames of media before its
    /// in point, which is all a dissolve into it can borrow.
    static func json(cSourceIn: Int = 30) -> String {
        #"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a1","kind":"video","name":"One","source":"a.mov","durationFrames":300},
                   {"id":"a2","kind":"video","name":"Two","source":"b.mov","durationFrames":300},
                   {"id":"a3","kind":"video","name":"Three","source":"c.mov","durationFrames":300}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"C","assetId":"a3","startFrame":120,"durationFrames":60,"sourceInFrame":\#(cSourceIn),"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#
    }

    func editor(cSourceIn: Int = 30) throws -> TimelineEditor { try TimelineEditor(json: Self.json(cSourceIn: cSourceIn), engine: try KeyframeRuntime()) }
    func transitions(_ e: TimelineEditor) -> [NativeCutTransition] { e.document.sequence.tracks[0].cutTransitions }
    func cut(_ e: TimelineEditor, _ from: String) throws -> TimelineCut { try XCTUnwrap(e.allCuts.first { $0.fromClipId == from }) }

    func testCutsAreTheTouchingPairsOfATrack() throws {
        let e = try editor()
        XCTAssertEqual(e.allCuts, [TimelineCut(trackId: "v1", fromClipId: "A", toClipId: "B", frame: 60),
                                   TimelineCut(trackId: "v1", fromClipId: "B", toClipId: "C", frame: 120)])
    }

    func testTheSelectedCutIsTheOneBetweenSelectedClipsElseAfterTheFirstElseBefore() throws {
        let e = try editor()
        XCTAssertEqual(e.cuts(forSelection: []), [], "nothing selected, no cut")
        XCTAssertEqual(e.cuts(forSelection: ["B"]).map(\.toClipId), ["C"], "the cut after the selected clip")
        XCTAssertEqual(e.cuts(forSelection: ["C"]).map(\.fromClipId), ["B"], "the last clip has none after it: the cut before")
        XCTAssertEqual(e.cuts(forSelection: ["A", "B"]).map(\.fromClipId), ["A"], "two touching clips: the cut between them")
        XCTAssertEqual(e.cuts(forSelection: ["A", "B", "C"]).map(\.fromClipId), ["A", "B"], "every cut between selected clips")
    }

    func testANewTransitionGetsTheDefaultLengthAndIsOneUndoStep() throws {
        let e = try editor()
        let outcome = e.applyTransition(.dissolve, to: try cut(e, "A"))
        XCTAssertEqual(outcome, .applied(lengthFrames: 15, shortenedFrom: nil))
        let t = try XCTUnwrap(transitions(e).first)
        XCTAssertEqual(t.kind, .dissolve)
        XCTAssertEqual(t.fromClipId, "A")
        XCTAssertEqual(t.toClipId, "B")
        XCTAssertEqual(t.durationFrames, 15)
        XCTAssertEqual(e.undoStack.count, 1, "one undo step")
        XCTAssertEqual(e.undoLabel, "Add transition")
        XCTAssertTrue(e.undo())
        XCTAssertTrue(transitions(e).isEmpty, "undo removes it")
        XCTAssertTrue(e.redo())
        XCTAssertEqual(transitions(e).count, 1, "redo brings it back")
    }

    func testChoosingAnotherKindForACutReplacesItsTransitionInOneStepKeepingTheLength() throws {
        let e = try editor()
        let ab = try cut(e, "A")
        XCTAssertTrue(e.applyTransition(.dissolve, to: ab, lengthFrames: 20).first?.applied == true)
        XCTAssertTrue(e.applyTransition(.push, direction: .right, to: ab).first?.applied == true)
        let all = transitions(e)
        XCTAssertEqual(all.count, 1, "one transition per cut")
        XCTAssertEqual(all[0].kind, .push)
        XCTAssertEqual(all[0].direction, .right)
        XCTAssertEqual(all[0].durationFrames, 20, "the cut keeps the length it had")
        XCTAssertEqual(e.undoStack.count, 2, "one step per apply")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(transitions(e).first?.kind, .dissolve, "undo returns to the dissolve")
        XCTAssertEqual(transitions(e).first?.durationFrames, 20)
    }

    func testOnlyANonDefaultDirectionAndColourIsWritten() throws {
        let e = try editor()
        let ab = try cut(e, "A"), bc = try cut(e, "B")
        e.applyTransition(.wipe, direction: .left, to: ab)
        XCTAssertNil(transitions(e)[0].object["direction"], "the default direction is not written")
        e.applyTransition(.wipe, direction: .up, to: ab)
        XCTAssertEqual(transitions(e)[0].object["direction"]?.stringValue, "up")
        e.applyTransition(.dip, color: NativeCutTransition.defaultDipColor, to: bc)
        XCTAssertNil(transitions(e).first { $0.toClipId == "C" }?.object["color"], "the default colour is not written")
        e.applyTransition(.dip, color: NativeCutTransition.whiteDipColor, to: bc)
        XCTAssertEqual(transitions(e).first { $0.toClipId == "C" }?.color, NativeCutTransition.whiteDipColor)
    }

    func testAShortHandleShortensTheTransitionAndSaysSo() throws {
        let e = try editor(cSourceIn: 5)   // 5 frames before C's in point: a centred dissolve into it holds at most 11
        let outcome = e.applyTransition(.dissolve, to: try cut(e, "B"))
        XCTAssertEqual(outcome, .applied(lengthFrames: 11, shortenedFrom: 15))
        XCTAssertEqual(outcome.shortenedLength, 11)
        XCTAssertEqual(transitions(e).first?.durationFrames, 11)
        XCTAssertEqual(e.transitionFit(.dissolve, on: try cut(e, "B"))?.length, 11)
        XCTAssertEqual(e.transitionFit(.dip, on: try cut(e, "B"))?.length, 15, "a dip borrows no media")
    }

    func testNoHandleRefusesADissolveButNotADipAndChangesNothing() throws {
        let e = try editor(cSourceIn: 0)
        let bc = try cut(e, "B")
        guard case .refused(let why) = e.applyTransition(.dissolve, to: bc) else { return XCTFail("a dissolve with no media is refused") }
        XCTAssertTrue(why.contains("2 frames"), why)
        XCTAssertTrue(transitions(e).isEmpty)
        XCTAssertTrue(e.undoStack.isEmpty, "a refusal is not an undo step")
        XCTAssertEqual(e.lastFailure?.message, why)
        XCTAssertTrue(e.applyTransition(.dip, to: bc).applied, "a dip needs no handle")
    }

    func testSeveralCutsAreOneUndoStepAndARefusedOneDoesNotStopTheRest() throws {
        let e = try editor(cSourceIn: 0)
        let outcomes = e.applyTransition(.dissolve, to: e.allCuts)
        XCTAssertEqual(outcomes.map(\.applied), [true, false], "A-B fits, B-C has no media")
        XCTAssertEqual(transitions(e).count, 1)
        XCTAssertEqual(e.undoStack.count, 1)
        let both = try editor()
        XCTAssertEqual(both.applyTransition(.wipe, direction: .down, to: both.allCuts).map(\.applied), [true, true])
        XCTAssertEqual(both.undoStack.count, 1, "two cuts, one undo step")
        XCTAssertTrue(both.undo())
        XCTAssertTrue(transitions(both).isEmpty)
    }

    func testALockedTrackRefusesAndChangesNothing() throws {
        let e = try editor()
        var locked = e.document
        locked.sequence.tracks[0].locked = true
        e.loadDocument(locked)
        XCTAssertEqual(e.applyTransition(.dissolve, to: try cut(e, "A")), .refused("Track is locked"))
        XCTAssertTrue(transitions(e).isEmpty)
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    func testAStaleCutIsRefused() throws {
        let e = try editor()
        let ab = try cut(e, "A")
        XCTAssertTrue(e.apply(.move(address: .init(sequenceId: "s", trackId: "v1", clipId: "B"), destination: .init(trackId: "v1", startFrame: 200))))
        XCTAssertEqual(e.applyTransition(.dissolve, to: ab), .refused("The two clips no longer meet at a cut."))
    }

    func testTheCutNearAFrameIsFoundWithinTheToleranceOnItsTrack() throws {
        let e = try editor()
        XCTAssertEqual(e.cut(nearFrame: 64, toleranceFrames: 6, trackId: "v1")?.fromClipId, "A")
        XCTAssertEqual(e.cut(nearFrame: 118, toleranceFrames: 6, trackId: "v1")?.fromClipId, "B")
        XCTAssertNil(e.cut(nearFrame: 90, toleranceFrames: 6, trackId: "v1"), "mid clip: no cut")
        XCTAssertNil(e.cut(nearFrame: 60, toleranceFrames: 6, trackId: "other"), "another track")
    }
}
