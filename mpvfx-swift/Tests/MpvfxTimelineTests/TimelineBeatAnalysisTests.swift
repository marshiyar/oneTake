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
import OneTakeKeyframes
import XCTest

@testable import MpvfxShared
@testable import MpvfxTimeline

/// Find beats (#290): analysed marks replace only analysed marks, and the search runs off the main thread, can be
/// cancelled, and changes the document only when it finishes.
internal final class TimelineBeatAnalysisTests: XCTestCase {
    private static let json: String = """
        {"schemaVersion":1,"mediaEngine":"native","id":"found","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"music","kind":"audio","name":"music","source":"music.wav","durationFrames":900},
                   {"id":"silent","kind":"audio","name":"silent","durationFrames":900}],
         "sequence":{"id":"seq","name":"Main","tracks":[{"id":"a1","kind":"audio","clips":[
           {"id":"a","assetId":"music","startFrame":0,"durationFrames":300,"sourceInFrame":60,"effects":[],"parameterTracks":[]},
           {"id":"nofile","assetId":"silent","startFrame":300,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """

    private func make() throws -> TimelineEditor { try TimelineEditor(json: Self.json, engine: KeyframeRuntime()) }
    private func beats(_ e: TimelineEditor) -> NativeClipBeats? { e.clip("a")?.clip.beats }
    private typealias Marks = [(seconds: Double, strength: Double)]
    private let sixMarks: Marks = [(2.0, 0.9), (2.5, 0.4), (3.0, 1.0), (3.5, 0.2), (4.0, 0.8), (4.5, 0.6)]

    // A4
    internal func testRerunningReplacesOnlyAnalysedMarksAndKeepsHandPlacedOnes() throws {
        let e = try make()
        XCTAssertTrue(e.addBeat(clipId: "a", at: 1))          // a hand mark at source frame 90
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertEqual(beats(e)?.frames, [90])
        XCTAssertEqual(beats(e)?.analysis?.frames, [60, 75, 90, 105, 120, 135])
        XCTAssertEqual(beats(e)?.analysis?.strengths, [0.9, 0.4, 1.0, 0.2, 0.8, 0.6])
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: [(5.0, 0.5), (6.0, 0.5)], sensitivity: 0.7, every: 2))
        XCTAssertEqual(beats(e)?.frames, [90], "the hand-placed mark stays")
        XCTAssertEqual(beats(e)?.analysis?.frames, [150, 180], "the earlier analysis is gone")
        XCTAssertEqual(beats(e)?.analysis?.sensitivity, 0.7); XCTAssertEqual(beats(e)?.analysis?.every, 2)
    }

    internal func testEachAnalysisIsOneUndoStepAndNoMarksClearsTheAnalysedOnes() throws {
        let e = try make()
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Find beats")
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: [], sensitivity: 0.5, every: 1))
        XCTAssertNil(beats(e), "no hand marks and no analysed marks: no beats object")
        XCTAssertEqual(e.undoStack.count, 2)
        XCTAssertTrue(e.undo()); XCTAssertEqual(beats(e)?.analysis?.frames.count, 6)
        XCTAssertTrue(e.undo()); XCTAssertNil(beats(e))
    }

    internal func testTheSameResultAgainAddsNoUndoStep() throws {
        let e = try make()
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertEqual(e.undoStack.count, 1)
    }

    internal func testMarksOnTheSameFrameKeepTheStrongerAndMarksPastTheMediaAreDropped() throws {
        let e = try make()
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: [(2.0, 0.3), (2.01, 0.9), (31.0, 1), (-1, 1), (.nan, 1)], sensitivity: 0.5, every: 1))
        XCTAssertEqual(beats(e)?.analysis?.frames, [60])
        XCTAssertEqual(beats(e)?.analysis?.strengths, [0.9])
    }

    internal func testBadSettingsAndUnavailableClipsAreRefused() throws {
        let e = try make()
        XCTAssertFalse(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 1.5, every: 1))
        XCTAssertFalse(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 3))
        XCTAssertFalse(e.replaceAnalysisBeats(clipId: "nope", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertTrue(e.setTrackLocked("a1", true))
        let steps = e.undoStack.count
        XCTAssertFalse(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertNil(e.beatAnalysisSource(clipId: "a"), "a locked track cannot be analysed")
        XCTAssertEqual(e.undoStack.count, steps)
    }

    internal func testAnalysedMarksSnapAreDrawnAndRoundTrip() throws {
        let e = try make()
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertEqual(e.tracks[0].clips[0].beatTimes, [0, 0.5, 1, 1.5, 2, 2.5], "source frame 60 is where the clip starts")
        let saved = try serializeNativeProjectDocument(e.document)
        let reopened = try TimelineEditor(json: saved)
        XCTAssertEqual(reopened.clip("a")?.clip.beats?.analysis, beats(e)?.analysis)
        XCTAssertEqual(saved, try serializeNativeProjectDocument(reopened.document))
    }

    internal func testAnAnalysedMarkCanBeDeletedOrMovedAndThenBelongsToTheHand() throws {
        let e = try make()
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: sixMarks, sensitivity: 0.5, every: 1))
        XCTAssertFalse(e.addBeat(clipId: "a", at: 1), "frame 90 already carries an analysed mark")
        XCTAssertTrue(e.editBeat(clipId: "a", sourceFrame: 75, to: nil))
        XCTAssertEqual(beats(e)?.analysis?.frames, [60, 90, 105, 120, 135])
        XCTAssertEqual(beats(e)?.analysis?.strengths, [0.9, 1.0, 0.2, 0.8, 0.6], "strengths follow their marks")
        XCTAssertTrue(e.editBeat(clipId: "a", sourceFrame: 105, to: 2.2))            // source frame 126
        XCTAssertEqual(beats(e)?.frames, [126])
        XCTAssertEqual(beats(e)?.analysis?.frames, [60, 90, 120, 135])
        XCTAssertTrue(e.replaceAnalysisBeats(clipId: "a", marks: [(4.0, 1)], sensitivity: 0.5, every: 1))
        XCTAssertEqual(beats(e)?.frames, [126], "the moved mark is the user's now")
    }

    // MARK: The search

    private func search(_ e: TimelineEditor, _ analysis: @escaping TimelineBeatSearch.Analysis) -> TimelineBeatSearch {
        TimelineBeatSearch(editor: e, analysis: analysis)
    }
    internal func testTheAnalysisRunsOffTheMainThreadAndTheResultIsStoredWhenItFinishes() throws {
        let e = try make()
        var ranOnMain: Bool?
        var seen: TimelineBeatAnalysisSource?
        let s = search(e) { source, options, _, progress in
            ranOnMain = Thread.isMainThread; seen = source
            XCTAssertEqual(options, TimelineBeatSearch.Options(sensitivity: 0.5, every: 1))
            progress(0.5)
            return [(2.0, 0.9), (3.0, 0.5)]
        }
        let done = expectation(description: "finished")
        var outcome: TimelineBeatSearch.Outcome?
        s.onFinish = { outcome = $0; done.fulfill() }
        XCTAssertTrue(s.start(clipId: "a"))
        XCTAssertTrue(s.isRunning)
        XCTAssertFalse(s.start(clipId: "a"), "one search at a time")
        wait(for: [done], timeout: 10)
        XCTAssertEqual(ranOnMain, false)
        XCTAssertEqual(seen?.assetSource, "music.wav")
        XCTAssertEqual(seen?.startSeconds ?? 0, 2, accuracy: 1e-9, "the clip starts at source frame 60")
        XCTAssertEqual(seen?.durationSeconds ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(outcome, .applied(marks: 2))
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(beats(e)?.analysis?.frames, [60, 90])
        XCTAssertEqual(e.undoStack.count, 1)
    }

    /// A3: the document does not change while the analysis runs, and a cancel stops it and drops its result.
    internal func testCancellingStopsTheSearchAndLeavesTheDocumentAlone() throws {
        let e = try make()
        let before = e.document
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        var sawCancel = false
        let s = search(e) { _, _, isCancelled, _ in
            started.signal()
            gate.wait()                                   // held open by the test
            sawCancel = isCancelled()
            return isCancelled() ? nil : [(2.0, 1)]
        }
        let done = expectation(description: "finished")
        var outcome: TimelineBeatSearch.Outcome?
        s.onFinish = { outcome = $0; done.fulfill() }
        XCTAssertTrue(s.start(clipId: "a"))
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(e.document, before, "nothing is written while the analysis runs")
        XCTAssertTrue(s.isRunning)
        s.cancel()
        gate.signal()
        wait(for: [done], timeout: 10)
        XCTAssertTrue(sawCancel)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.undoStack.isEmpty)
    }

    internal func testAResultForAClipTrimmedMeanwhileIsDropped() throws {
        let e = try make()
        let before = e.document
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let s = search(e) { _, _, _, _ in started.signal(); gate.wait(); return [(2.0, 1)] }
        let done = expectation(description: "finished")
        var outcome: TimelineBeatSearch.Outcome?
        s.onFinish = { outcome = $0; done.fulfill() }
        XCTAssertTrue(s.start(clipId: "a"))
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        let address = try XCTUnwrap(e.address(clipId: "a"))
        XCTAssertTrue(e.apply(.trimOut(address: address, endFrameExclusive: 200)))
        gate.signal()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .clipChanged)
        XCTAssertNil(beats(e))
        XCTAssertNotEqual(e.document, before)
    }

    internal func testASearchNeedsAnAudioClipWithAFileAndAValidSetting() throws {
        let e = try make()
        let s = search(e) { _, _, _, _ in [] }
        XCTAssertFalse(s.start(clipId: "nofile"), "its asset has no media file")
        XCTAssertFalse(s.start(clipId: "missing"))
        XCTAssertFalse(s.start(clipId: "a", options: .init(sensitivity: 2, every: 1)))
        XCTAssertFalse(s.start(clipId: "a", options: .init(sensitivity: 0.5, every: 3)))
        XCTAssertFalse(s.isRunning)
    }

    internal func testAnAnalysisErrorIsReportedAndChangesNothing() throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "the file could not be decoded" } }
        let e = try make()
        let s = search(e) { _, _, _, _ in throw Boom() }
        let done = expectation(description: "finished")
        var outcome: TimelineBeatSearch.Outcome?
        s.onFinish = { outcome = $0; done.fulfill() }
        XCTAssertTrue(s.start(clipId: "a"))
        wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .failed("the file could not be decoded"))
        XCTAssertNil(beats(e))
    }

    internal func testTheClipMenuOffersFindBeatsOnlyWhenTheHostHandlesIt() throws {
        let e = try make()
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 30), editor: e)
        c.viewport = CanvasSize(1_000, 300)
        func hasFindBeats() -> Bool {
            (c.view.clipMenu?.entries ?? []).contains { if case .item(let i) = $0 { return i.action == .findBeats }; return false }
        }
        c.openClipMenu("a", x: 10, y: 10)
        XCTAssertFalse(hasFindBeats())
        var requested: [String] = []
        c.onFindBeats = { requested.append($0) }
        c.openClipMenu("a", x: 10, y: 10)
        XCTAssertTrue(hasFindBeats())
        XCTAssertTrue(c.runClipMenu(.findBeats, clipId: "a"))
        XCTAssertEqual(requested, ["a"])
        c.openClipMenu("nofile", x: 10, y: 10)
        XCTAssertFalse(hasFindBeats(), "no media file to read")
    }
}
