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
@testable import MpvfxTimeline

/// The caption list's edits (NativeCaptionListPlan.swift) and their editor commands. The demo project runs at 30 fps, so
/// one frame is Int((1000 / 30).rounded()) = 33 ms for a nudge, and the minimum cue is 34 ms (1000 / 30 rounded up).
final class CaptionListEditTests: XCTestCase {
    static let threeCues = [
        NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
        NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3000, text: "two"),
        NativeCaptionCue(id: "cue:3", startMs: 5000, endMs: 6000, text: "three"),
    ]

    /// "hello brave world" from 1000 to 3000 ms: the split example. Caret 5 is after "hello", caret 11 after "brave".
    static let helloCue = NativeCaptionCue(id: "cue:1", startMs: 1000, endMs: 3000, text: "hello brave world")

    /// The same cue with word times: hello 1000-1400, brave 1500-1900, world 2100-2900.
    static let timedHello = NativeCaptionCue(id: "cue:1", startMs: 1000, endMs: 3000, text: "hello brave world", words: [
        NativeCaptionWord(text: "hello", start: 1000, end: 1400),
        NativeCaptionWord(text: "brave", start: 1500, end: 1900),
        NativeCaptionWord(text: "world", start: 2100, end: 2900),
    ])

    /// The demo project with a caption track of `cues`, validated like any loaded project.
    func captioned(_ cues: [NativeCaptionCue]) throws -> NativeProjectDocument {
        var d = try TimelineEditor(json: TimelineEditor.demoJSON).document
        d.sequence.captions = NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues)
        return try parseNativeProjectDocument(d)
    }

    /// A caption track of `cues` for the pure planners.
    func captionTrack(_ cues: [NativeCaptionCue]) -> NativeCaptionTrack {
        NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues)
    }

    /// Every cue passes the storage rules: text, timing in start order with no overlap, and word times.
    func assertStorable(_ track: NativeCaptionTrack, file: StaticString = #filePath, line: UInt = #line) {
        var previous: NativeCaptionCue?
        for cue in track.cues {
            XCTAssertNil(nativeCaptionTextProblem(cue.text), "text of \(cue.id)", file: file, line: line)
            XCTAssertNil(nativeCaptionTimingProblem(cue, after: previous), "timing of \(cue.id)", file: file, line: line)
            XCTAssertNil(nativeCaptionWordsProblem(cue), "words of \(cue.id)", file: file, line: line)
            previous = cue
        }
    }

    // MARK: Nudge

    func testNudgeEndEdgeOneFrameMovesTheEndByThirtyThreeMs() throws {
        // cue:2 is 2000-3000; one frame is 33 ms, so the end moves to 3033. The next cue starts at 5000, so nothing clamps.
        let out = try planCaptionNudge(captionTrack(Self.threeCues), cueId: "cue:2", edge: .end, byFrames: 1, frameRate: 30)
        XCTAssertEqual(out.cues[1], NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3033, text: "two"))
        XCTAssertEqual(out.cues[0], Self.threeCues[0])
        XCTAssertEqual(out.cues[2], Self.threeCues[2])
    }

    func testNudgeStartEdgeOneFrameBackMovesTheStartThirtyThreeMsEarlier() throws {
        // cue:2 starts at 2000; 2000 - 33 = 1967, and the cue before ends at 1000, so nothing clamps.
        let out = try planCaptionNudge(captionTrack(Self.threeCues), cueId: "cue:2", edge: .start, byFrames: -1, frameRate: 30)
        XCTAssertEqual(out.cues[1], NativeCaptionCue(id: "cue:2", startMs: 1967, endMs: 3000, text: "two"))
    }

    func testNudgeIntoATouchingNeighbourChangesNothing() throws {
        // cue:a ends exactly where cue:b starts (1000), so neither edge can move into the other.
        let touching = captionTrack([
            NativeCaptionCue(id: "cue:a", startMs: 0, endMs: 1000, text: "a"),
            NativeCaptionCue(id: "cue:b", startMs: 1000, endMs: 2000, text: "b"),
        ])
        // b's start -1 frame would be 1000 - 33 = 967; it clamps to a's end, 1000.
        let startOut = try planCaptionNudge(touching, cueId: "cue:b", edge: .start, byFrames: -1, frameRate: 30)
        XCTAssertEqual(startOut, touching)
        // a's end +1 frame would be 1000 + 33 = 1033; it clamps to b's start, 1000.
        let endOut = try planCaptionNudge(touching, cueId: "cue:a", edge: .end, byFrames: 1, frameRate: 30)
        XCTAssertEqual(endOut, touching)
    }

    func testNudgeClampsToTheOneFrameMinimumInBothDirections() throws {
        // cue:2 is 2000-2040, which is 40 ms; the minimum is 34 ms.
        let short = captionTrack([
            NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
            NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 2040, text: "two"),
        ])
        // End -1 frame would be 2040 - 33 = 2007; the minimum keeps it at 2000 + 34 = 2034.
        let shorter = try planCaptionNudge(short, cueId: "cue:2", edge: .end, byFrames: -1, frameRate: 30)
        XCTAssertEqual(shorter.cues[1].endMs, 2034)
        // Start +1 frame would be 2000 + 33 = 2033; the minimum keeps it at 2040 - 34 = 2006.
        let pulled = try planCaptionNudge(short, cueId: "cue:2", edge: .start, byFrames: 1, frameRate: 30)
        XCTAssertEqual(pulled.cues[1].startMs, 2006)
        XCTAssertEqual(pulled.cues[1].endMs, 2040)
        assertStorable(shorter)
        assertStorable(pulled)

        // A cue already at one frame (2000-2034): a further end -1 frame moves nothing.
        let atMinimum = captionTrack([
            NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 2034, text: "two"),
        ])
        let unchanged = try planCaptionNudge(atMinimum, cueId: "cue:2", edge: .end, byFrames: -1, frameRate: 30)
        XCTAssertEqual(unchanged, atMinimum)
    }

    func testNudgeOfAnUnknownCueThrows() {
        XCTAssertThrowsError(try planCaptionNudge(captionTrack(Self.threeCues), cueId: "cue:9", edge: .end, byFrames: 1, frameRate: 30)) {
            XCTAssertEqual($0 as? NativeCaptionEditError, .unknownCue("cue:9"))
        }
    }

    // MARK: Split

    func testSplitMakesTwoContiguousCuesAndTrimsTheSpaceAtTheCut() throws {
        // Caret 5 is the space after "hello" and caret 6 is just after that space; either way the cut trims to "hello".
        for caret in [5, 6] {
            let r = try planCaptionSplit(captionTrack([Self.helloCue]), cueId: "cue:1", atMs: 2000, caret: caret, frameRate: 30)
            XCTAssertEqual(r.newCueId, "cue:split-1")
            XCTAssertEqual(r.track.cues, [
                NativeCaptionCue(id: "cue:1", startMs: 1000, endMs: 2000, text: "hello"),
                NativeCaptionCue(id: "cue:split-1", startMs: 2000, endMs: 3000, text: "brave world"),
            ])
            XCTAssertEqual(r.track.cues[0].endMs, r.track.cues[1].startMs, "the halves are contiguous")
            assertStorable(r.track)
        }
    }

    func testSplitWithAnEmptySideThrowsNothingToSplit() {
        // Caret 0 leaves the first half empty; caret 17 (the end of "hello brave world") leaves the second half empty.
        let t = captionTrack([Self.helloCue])
        for caret in [0, 17] {
            XCTAssertThrowsError(try planCaptionSplit(t, cueId: "cue:1", atMs: 2000, caret: caret, frameRate: 30)) {
                XCTAssertEqual($0 as? NativeCaptionEditError, .nothingToSplit)
            }
        }
    }

    func testSplitWithAHalfUnderOneFrameThrowsNoRoom() {
        // The cue is 1000-3000 and the minimum is 34 ms. 1033 is 33 ms after the start, and 2967 is 33 ms before the end.
        let t = captionTrack([Self.helloCue])
        for atMs in [1033, 2967] {
            XCTAssertThrowsError(try planCaptionSplit(t, cueId: "cue:1", atMs: atMs, caret: 5, frameRate: 30)) {
                XCTAssertEqual($0 as? NativeCaptionEditError, .noRoom)
            }
        }
        // 34 ms on each side is exactly one frame, which is enough.
        XCTAssertNoThrow(try planCaptionSplit(t, cueId: "cue:1", atMs: 1034, caret: 5, frameRate: 30))
        XCTAssertNoThrow(try planCaptionSplit(t, cueId: "cue:1", atMs: 2966, caret: 5, frameRate: 30))
    }

    func testSplitSecondHalfTakesThePositionOverride() throws {
        var cue = Self.helloCue
        cue.position = NativeCaptionPosition.custom(x: 0.25, y: 0.75)
        let r = try planCaptionSplit(captionTrack([cue]), cueId: "cue:1", atMs: 2000, caret: 5, frameRate: 30)
        XCTAssertEqual(r.track.cues[1].position, NativeCaptionPosition.custom(x: 0.25, y: 0.75))
        XCTAssertEqual(r.track.cues[0].position, NativeCaptionPosition.custom(x: 0.25, y: 0.75), "the first half keeps it too")
    }

    func testSplitKeepsWordTimesOnlyWhenEachHalfStillSpellsItsWords() throws {
        // Caret 11 is the space before "world": "hello brave" keeps hello and brave, and "world" keeps its own time.
        let kept = try planCaptionSplit(captionTrack([Self.timedHello]), cueId: "cue:1", atMs: 2000, caret: 11, frameRate: 30)
        XCTAssertEqual(kept.track.cues[0].words, [
            NativeCaptionWord(text: "hello", start: 1000, end: 1400),
            NativeCaptionWord(text: "brave", start: 1500, end: 1900),
        ])
        XCTAssertEqual(kept.track.cues[1].words, [NativeCaptionWord(text: "world", start: 2100, end: 2900)])
        assertStorable(kept.track)

        // Caret 5 cuts after "hello": the first half's words would spell "hello brave", and the second's "world" would
        // spell "brave world", so both halves lose their word times.
        let dropped = try planCaptionSplit(captionTrack([Self.timedHello]), cueId: "cue:1", atMs: 2000, caret: 5, frameRate: 30)
        XCTAssertNil(dropped.track.cues[0].words)
        XCTAssertNil(dropped.track.cues[1].words)
        assertStorable(dropped.track)
    }

    func testSplitNewIdSkipsIdsAlreadyInUse() throws {
        let t = captionTrack([
            NativeCaptionCue(id: "cue:a", startMs: 0, endMs: 1000, text: "hello brave"),
            NativeCaptionCue(id: "cue:split-1", startMs: 1000, endMs: 1500, text: "x"),
        ])
        let r = try planCaptionSplit(t, cueId: "cue:a", atMs: 500, caret: 5, frameRate: 30)
        XCTAssertEqual(r.newCueId, "cue:split-2")
        XCTAssertEqual(r.track.cues.map { $0.id }, ["cue:a", "cue:split-2", "cue:split-1"])
        assertStorable(r.track)
    }

    // MARK: Join

    func testJoinMergesTwoCuesAndAbsorbsTheGap() throws {
        // cue:a 1000-2000 "one" and cue:b 2500-3000 "two": the 500 ms gap is absorbed into the joined cue.
        let t = captionTrack([
            NativeCaptionCue(id: "cue:a", startMs: 1000, endMs: 2000, text: "one"),
            NativeCaptionCue(id: "cue:b", startMs: 2500, endMs: 3000, text: "two"),
        ])
        let out = try planCaptionJoin(t, cueId: "cue:a")
        XCTAssertEqual(out.cues, [NativeCaptionCue(id: "cue:a", startMs: 1000, endMs: 3000, text: "one two")])
        assertStorable(out)
    }

    func testJoinOfTheLastCueThrowsNoNextCue() {
        let t = captionTrack([
            NativeCaptionCue(id: "cue:a", startMs: 1000, endMs: 2000, text: "one"),
            NativeCaptionCue(id: "cue:b", startMs: 2500, endMs: 3000, text: "two"),
        ])
        XCTAssertThrowsError(try planCaptionJoin(t, cueId: "cue:b")) {
            XCTAssertEqual($0 as? NativeCaptionEditError, .noNextCue)
        }
    }

    func testJoinKeepsWordTimesOnlyWhenBothCuesHaveThem() throws {
        let both = captionTrack([
            NativeCaptionCue(id: "cue:a", startMs: 1000, endMs: 2000, text: "one",
                             words: [NativeCaptionWord(text: "one", start: 1000, end: 1900)]),
            NativeCaptionCue(id: "cue:b", startMs: 2500, endMs: 3000, text: "two",
                             words: [NativeCaptionWord(text: "two", start: 2500, end: 2900)]),
        ])
        let joined = try planCaptionJoin(both, cueId: "cue:a")
        XCTAssertEqual(joined.cues[0].words, [
            NativeCaptionWord(text: "one", start: 1000, end: 1900),
            NativeCaptionWord(text: "two", start: 2500, end: 2900),
        ])
        assertStorable(joined)

        // Only the first cue has word times: the joined cue has none.
        let one = captionTrack([
            NativeCaptionCue(id: "cue:a", startMs: 1000, endMs: 2000, text: "one",
                             words: [NativeCaptionWord(text: "one", start: 1000, end: 1900)]),
            NativeCaptionCue(id: "cue:b", startMs: 2500, endMs: 3000, text: "two"),
        ])
        XCTAssertNil(try planCaptionJoin(one, cueId: "cue:a").cues[0].words)
    }

    func testSplitThenJoinReturnsTheOriginalCue() throws {
        // A plain cue: split at the caret, then join, gives back the same cue (no gap, same text, span and id).
        let original = captionTrack([Self.helloCue])
        let split = try planCaptionSplit(original, cueId: "cue:1", atMs: 2000, caret: 5, frameRate: 30)
        XCTAssertEqual(try planCaptionJoin(split.track, cueId: "cue:1"), original)

        // A timed cue split where both halves keep their words joins back to the same word times too.
        let timed = captionTrack([Self.timedHello])
        let timedSplit = try planCaptionSplit(timed, cueId: "cue:1", atMs: 2000, caret: 11, frameRate: 30)
        XCTAssertEqual(try planCaptionJoin(timedSplit.track, cueId: "cue:1"), timed)
    }

    // MARK: Find and replace

    func testFindCountsMatchesCaseSensitiveAndInsensitive() {
        let t = captionTrack([
            NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "Hello hello HELLO"),
            NativeCaptionCue(id: "cue:2", startMs: 1000, endMs: 2000, text: "bye"),
        ])
        let sensitive = findCaptionMatches(t, find: "hello", caseSensitive: true)
        XCTAssertEqual(sensitive.map { $0.cueId }, ["cue:1"])
        XCTAssertEqual(sensitive.map { $0.count }, [1], "only the lowercase \"hello\" matches")
        let loose = findCaptionMatches(t, find: "hello", caseSensitive: false)
        XCTAssertEqual(loose.map { $0.count }, [3])
    }

    func testOverlappingMatchesCountOnce() {
        // "aaa" holds one "aa" that does not overlap the next: the search resumes after the first match.
        let t = captionTrack([NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "aaa")])
        XCTAssertEqual(findCaptionMatches(t, find: "aa", caseSensitive: true).map { $0.count }, [1])
    }

    func testEmptyFindMatchesNothingAndChangesNothing() {
        let t = captionTrack(Self.threeCues)
        XCTAssertTrue(findCaptionMatches(t, find: "", caseSensitive: true).isEmpty)
        let r = planCaptionReplaceAll(t, find: "", replace: "x", caseSensitive: true)
        XCTAssertEqual(r.track, t)
        XCTAssertEqual(r.cuesChanged, 0)
        XCTAssertEqual(r.replacements, 0)
        XCTAssertEqual(r.skipped, [])
    }

    func testReplaceAllCountsCuesAndReplacements() {
        let t = captionTrack([
            NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one one"),
            NativeCaptionCue(id: "cue:2", startMs: 1000, endMs: 2000, text: "two one"),
            NativeCaptionCue(id: "cue:3", startMs: 2000, endMs: 3000, text: "two"),
        ])
        let r = planCaptionReplaceAll(t, find: "one", replace: "1", caseSensitive: true)
        // cue:1 has two matches and cue:2 one: two cues changed, three replacements. cue:3 has none.
        XCTAssertEqual(r.cuesChanged, 2)
        XCTAssertEqual(r.replacements, 3)
        XCTAssertEqual(r.skipped, [])
        XCTAssertEqual(r.track.cues.map { $0.text }, ["1 1", "two 1", "two"])
        assertStorable(r.track)
    }

    func testReplacingToEmptyOrToAnArrowSkipsTheCueAndNamesIt() {
        let t = captionTrack([
            NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
            NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3000, text: "two"),
        ])
        // "one" to "" would leave an empty cue: skipped, not counted, and the track is unchanged.
        let empty = planCaptionReplaceAll(t, find: "one", replace: "", caseSensitive: true)
        XCTAssertEqual(empty.track, t)
        XCTAssertEqual(empty.skipped, ["cue:1"])
        XCTAssertEqual(empty.cuesChanged, 0)
        XCTAssertEqual(empty.replacements, 0)

        // "two" to "a --> b" would write an SRT timing line into the text: skipped the same way.
        let arrow = planCaptionReplaceAll(t, find: "two", replace: "a --> b", caseSensitive: true)
        XCTAssertEqual(arrow.track, t)
        XCTAssertEqual(arrow.skipped, ["cue:2"])
        XCTAssertEqual(arrow.cuesChanged, 0)
    }

    func testReplaceAllDropsWordTimesWhenTheTextChanges() {
        let t = captionTrack([
            NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one",
                             words: [NativeCaptionWord(text: "one", start: 0, end: 900)]),
        ])
        let r = planCaptionReplaceAll(t, find: "one", replace: "uno", caseSensitive: true)
        XCTAssertEqual(r.track.cues, [NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "uno")])
        XCTAssertEqual(r.cuesChanged, 1)
        XCTAssertEqual(r.replacements, 1)
    }

    // MARK: Reading rate

    func testReadingRateDoesNotCountLineBreaks() {
        // 17 characters, a line break, then 17 more: 34 characters in 2000 ms is 17 characters per second.
        let text = String(repeating: "a", count: 17) + "\n" + String(repeating: "b", count: 17)
        let cue = NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 2000, text: text)
        XCTAssertEqual(nativeCaptionReadingRate(cue), 17)
    }

    func testExceedsReadingRateIsStrictlyAboveTheLimit() {
        // 17 characters in 1000 ms is 17.0 per second: not above a limit of 17.
        let at17 = NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: String(repeating: "a", count: 17))
        XCTAssertFalse(nativeCaptionExceedsReadingRate(at17, limit: 17))
        // 18 characters in 1000 ms is 18 per second: above 17.
        let at18 = NativeCaptionCue(id: "cue:2", startMs: 0, endMs: 1000, text: String(repeating: "a", count: 18))
        XCTAssertTrue(nativeCaptionExceedsReadingRate(at18, limit: 17))
    }

    func testZeroLengthCueHasAnInfiniteReadingRate() {
        let cue = NativeCaptionCue(id: "cue:1", startMs: 1000, endMs: 1000, text: "a")
        XCTAssertEqual(nativeCaptionReadingRate(cue), .infinity)
        XCTAssertTrue(nativeCaptionExceedsReadingRate(cue, limit: 40))
    }

    // MARK: Editor commands

    func testEditorNudgeIsOneUndoStepAndUndoRestoresTheDocument() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertTrue(e.nudgeCaptionCue("cue:2", edge: .end, byFrames: 1))
        XCTAssertEqual(e.captionCues[1].endMs, 3033)
        XCTAssertEqual(e.undoLabel, "Nudge caption")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)
    }

    func testEditorNudgeThatChangesNothingOrNamesNoCueRecordsNothing() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertFalse(e.nudgeCaptionCue("cue:9", edge: .end, byFrames: 1), "unknown cue")
        // cue:1 starts at 0, so moving its start earlier clamps to 0 and changes nothing.
        XCTAssertFalse(e.nudgeCaptionCue("cue:1", edge: .start, byFrames: -1), "clamped to no change")
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.document, before)
    }

    func testEditorSplitIsOneUndoStepAndReturnsTheNewCueId() throws {
        let e = TimelineEditor(document: try captioned([Self.helloCue]))
        let before = e.document
        XCTAssertEqual(e.splitCaptionCue("cue:1", atMs: 2000, caret: 5), "cue:split-1")
        XCTAssertEqual(e.captionCues.map { $0.text }, ["hello", "brave world"])
        XCTAssertEqual(e.undoLabel, "Split caption")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)
    }

    func testEditorSplitWithTextCommitsTheRetypeAndTheSplitInOneUndoStep() throws {
        let e = TimelineEditor(document: try captioned([Self.helloCue]))
        let before = e.document
        // The text being edited is "hi brave world"; the caret after "hi" (offset 2) is the cut.
        XCTAssertEqual(e.splitCaptionCue("cue:1", atMs: 2000, caret: 2, text: "hi brave world"), "cue:split-1")
        XCTAssertEqual(e.captionCues.map { $0.text }, ["hi", "brave world"])
        XCTAssertEqual(e.undoLabel, "Split caption")
        XCTAssertEqual(e.undoStack.count, 1, "the retype and the split are one step")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.captionCues.map { $0.text }, ["hello brave world"])
    }

    func testEditorJoinIsOneUndoStepAndUndoRestoresTheDocument() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertTrue(e.joinCaptionCue("cue:1"))
        XCTAssertEqual(e.captionCues, [
            NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 3000, text: "one two"),
            Self.threeCues[2],
        ])
        XCTAssertEqual(e.undoLabel, "Join captions")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)

        // The last cue has nothing after it to join with: nothing changes and nothing is recorded.
        XCTAssertFalse(e.joinCaptionCue("cue:3"))
        XCTAssertEqual(e.undoStack.count, 0)
    }

    func testEditorReplaceAllIsOneUndoStepAndReturnsTheCounts() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        let result = try XCTUnwrap(e.replaceAllCaptions(find: "e", with: "E", caseSensitive: true))
        XCTAssertEqual(result.cuesChanged, 2, "\"one\" and \"three\"")
        XCTAssertEqual(result.replacements, 3, "one e in \"one\", two in \"three\"")
        XCTAssertEqual(e.captionCues.map { $0.text }, ["onE", "two", "thrEE"])
        XCTAssertEqual(e.undoLabel, "Replace in captions")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
        XCTAssertFalse(e.canUndo)
    }

    func testEditorReplaceAllWithNoMatchRecordsNothing() throws {
        let e = TimelineEditor(document: try captioned(Self.threeCues))
        let before = e.document
        XCTAssertNil(e.replaceAllCaptions(find: "zzz", with: "y", caseSensitive: false))
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.document, before)
        // "two" matches, but replacing it with empty text is refused, so no cue changes and nothing is recorded.
        XCTAssertNil(e.replaceAllCaptions(find: "two", with: "", caseSensitive: true))
        XCTAssertEqual(e.undoStack.count, 0)
        XCTAssertEqual(e.document, before)
    }
}
