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
import Foundation
@testable import MpvfxShared

/// The caption lane's pure edits (move, trim, retext, add): exact times, the clamps, and the rules the document
/// validator applies to every result.
final class CaptionEditPlanTests: XCTestCase {
    // MARK: Helpers

    /// A track with the usual id and the cues given, already in start order.
    func makeTrack(_ cues: NativeCaptionCue...) -> NativeCaptionTrack {
        NativeCaptionTrack(id: "captions:main", cues: cues)
    }

    func makeCue(_ id: String, _ start: Int, _ end: Int, _ text: String, words: [NativeCaptionWord]? = nil) -> NativeCaptionCue {
        NativeCaptionCue(id: id, startMs: start, endMs: end, text: text, words: words)
    }

    func makeWord(_ text: String, _ start: Int, _ end: Int) -> NativeCaptionWord {
        NativeCaptionWord(text: text, start: start, end: end)
    }

    /// The edit throws exactly `expected`.
    func assertEditFails(_ expected: NativeCaptionEditError, file: StaticString = #filePath, line: UInt = #line,
                         _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? NativeCaptionEditError, expected, file: file, line: line)
        }
    }

    /// Every cue passes the timing rule against the cue before it, its text passes, and its word times pass. The document
    /// validator, which `parseNativeProjectDocument` runs on `sequence.captions`, reports no issue for the track.
    func assertValidTrack(_ track: NativeCaptionTrack, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var previous: NativeCaptionCue?
        for cue in track.cues {
            XCTAssertNil(nativeCaptionTimingProblem(cue, after: previous), "\(label): \(cue.id) timing", file: file, line: line)
            XCTAssertNil(nativeCaptionTextProblem(cue.text), "\(label): \(cue.id) text", file: file, line: line)
            XCTAssertNil(nativeCaptionWordsProblem(cue), "\(label): \(cue.id) words", file: file, line: line)
            previous = cue
        }
        var issues: [NativeProjectDocumentValidationIssue] = []
        validateNativeCaptionTrack(try validatorJSON(track), "sequence.captions", &issues)
        XCTAssertTrue(issues.isEmpty, "\(label): \(issues)", file: file, line: line)
    }

    /// The track as the document reader sees it: encoded to JSON, then read back as a JSON value.
    func validatorJSON(_ track: NativeCaptionTrack) throws -> NativeJSONValue {
        try JSONDecoder().decode(NativeJSONValue.self, from: JSONEncoder().encode(track))
    }

    // MARK: Move

    func testMoveClampsToThePreviousCueEndAndTheNextCueStart() throws {
        // a 0-1000, b 2000-3000 (1000 ms long), c 5000-6000
        let t = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 2000, 3000, "b"), makeCue("c", 5000, 6000, "c"))

        // Free space: b lands where asked, length kept.
        let free = try planCaptionMove(t, cueId: "b", toStartMs: 1500)
        XCTAssertEqual(free.cues[1], makeCue("b", 1500, 2500, "b"))

        // Before a ends: stops at a's end, 1000.
        let early = try planCaptionMove(t, cueId: "b", toStartMs: 500)
        XCTAssertEqual(early.cues[1], makeCue("b", 1000, 2000, "b"))

        // Past c: b may end no later than c starts (5000), so its start stops at 5000 - 1000 = 4000.
        let late = try planCaptionMove(t, cueId: "b", toStartMs: 9000)
        XCTAssertEqual(late.cues[1], makeCue("b", 4000, 5000, "b"))

        // The other cues and the track id are untouched.
        XCTAssertEqual(late.cues[0], t.cues[0])
        XCTAssertEqual(late.cues[2], t.cues[2])
        XCTAssertEqual(late.id, "captions:main")
    }

    func testMoveClampsAtZeroAndAtTheLastMillisecondAndKeepsTheLength() throws {
        let single = makeTrack(makeCue("a", 500, 1500, "a"))

        let zero = try planCaptionMove(single, cueId: "a", toStartMs: -300)
        XCTAssertEqual(zero.cues[0], makeCue("a", 0, 1000, "a"))

        // The last representable time is 999:59:59,999 = 3_599_999_999 ms, so the start stops 1000 ms before it.
        XCTAssertEqual(NATIVE_CAPTION_MAX_MILLISECONDS, 3_599_999_999)
        let end = try planCaptionMove(single, cueId: "a", toStartMs: 4_000_000_000)
        XCTAssertEqual(end.cues[0], makeCue("a", 3_599_998_999, 3_599_999_999, "a"))
    }

    func testMoveShiftsWordTimesWithTheCue() throws {
        // b 2000-3000 reads "hi there": hi 2100-2400, there 2400-2900
        let words = [makeWord("hi", 2100, 2400), makeWord("there", 2400, 2900)]
        let t = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 2000, 3000, "hi there", words: words), makeCue("c", 5000, 6000, "c"))

        // Moved by -500 ms (to 1500): every word moves by -500.
        let moved = try planCaptionMove(t, cueId: "b", toStartMs: 1500)
        XCTAssertEqual(moved.cues[1], makeCue("b", 1500, 2500, "hi there", words: [makeWord("hi", 1600, 1900), makeWord("there", 1900, 2400)]))

        // Clamped to 1000 (delta -1000): every word moves by -1000.
        let clamped = try planCaptionMove(t, cueId: "b", toStartMs: 500)
        XCTAssertEqual(clamped.cues[1], makeCue("b", 1000, 2000, "hi there", words: [makeWord("hi", 1100, 1400), makeWord("there", 1400, 1900)]))
    }

    func testMoveOfAnUnknownCueThrows() {
        let t = makeTrack(makeCue("a", 0, 1000, "a"))
        assertEditFails(.unknownCue("nope")) { _ = try planCaptionMove(t, cueId: "nope", toStartMs: 0) }
    }

    // MARK: Trim

    func testTrimStartClampsToThePreviousCueEndAndOneFrameBeforeTheEnd() throws {
        XCTAssertEqual(nativeCaptionMinimumDurationMs(frameRate: 25), 40)
        XCTAssertEqual(nativeCaptionMinimumDurationMs(frameRate: 30), 34)
        // a 0-1000, b 2000-3000, c 5000-6000
        let t = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 2000, 3000, "b"), makeCue("c", 5000, 6000, "c"))

        // Earlier than a ends: stops at 1000.
        let early = try planCaptionTrim(t, cueId: "b", edge: .start, toMs: 500, frameRate: 25)
        XCTAssertEqual(early.cues[1], makeCue("b", 1000, 3000, "b"))

        // Free: start moves to 2500.
        let free = try planCaptionTrim(t, cueId: "b", edge: .start, toMs: 2500, frameRate: 25)
        XCTAssertEqual(free.cues[1], makeCue("b", 2500, 3000, "b"))

        // Past b's end: stops one 40 ms frame before 3000, at 2960.
        let late = try planCaptionTrim(t, cueId: "b", edge: .start, toMs: 2990, frameRate: 25)
        XCTAssertEqual(late.cues[1], makeCue("b", 2960, 3000, "b"))

        // At 30 fps the minimum is 34 ms, so the same drag stops at 3000 - 34 = 2966.
        let thirty = try planCaptionTrim(t, cueId: "b", edge: .start, toMs: 2990, frameRate: 30)
        XCTAssertEqual(thirty.cues[1], makeCue("b", 2966, 3000, "b"))
    }

    func testTrimEndClampsToOneFrameAfterTheStartAndToTheNextCueStart() throws {
        let t = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 2000, 3000, "b"), makeCue("c", 5000, 6000, "c"))

        // Shorter than one frame: stops 40 ms after b starts, at 2040.
        let short = try planCaptionTrim(t, cueId: "b", edge: .end, toMs: 2010, frameRate: 25)
        XCTAssertEqual(short.cues[1], makeCue("b", 2000, 2040, "b"))

        // At 30 fps the same drag stops at 2000 + 34 = 2034.
        let short30 = try planCaptionTrim(t, cueId: "b", edge: .end, toMs: 2010, frameRate: 30)
        XCTAssertEqual(short30.cues[1], makeCue("b", 2000, 2034, "b"))

        // Free: end moves to 4000.
        let free = try planCaptionTrim(t, cueId: "b", edge: .end, toMs: 4000, frameRate: 25)
        XCTAssertEqual(free.cues[1], makeCue("b", 2000, 4000, "b"))

        // Past c: b may end no later than c starts, at 5000 (touching is allowed).
        let long = try planCaptionTrim(t, cueId: "b", edge: .end, toMs: 9000, frameRate: 25)
        XCTAssertEqual(long.cues[1], makeCue("b", 2000, 5000, "b"))

        // The last cue may run to the last representable millisecond, 3_599_999_999.
        let last = try planCaptionTrim(t, cueId: "c", edge: .end, toMs: NATIVE_CAPTION_MAX_MILLISECONDS + 1, frameRate: 25)
        XCTAssertEqual(last.cues[2], makeCue("c", 5000, 3_599_999_999, "c"))
    }

    func testTrimDropsWordTimesOnlyWhenTheTrimCutsAWord() throws {
        // b 2000-3000 reads "hi there": hi 2100-2400, there 2400-2900
        let words = [makeWord("hi", 2100, 2400), makeWord("there", 2400, 2900)]
        let t = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 2000, 3000, "hi there", words: words), makeCue("c", 5000, 6000, "c"))

        // End at 2950: "there" still ends inside the cue, so the word times stay.
        let longer = try planCaptionTrim(t, cueId: "b", edge: .end, toMs: 2950, frameRate: 25)
        XCTAssertEqual(longer.cues[1], makeCue("b", 2000, 2950, "hi there", words: words))

        // End at 2500: "there" (2400-2900) is cut, so the word times go and the text stays.
        let cut = try planCaptionTrim(t, cueId: "b", edge: .end, toMs: 2500, frameRate: 25)
        XCTAssertEqual(cut.cues[1], makeCue("b", 2000, 2500, "hi there"))

        // Start at 2050: "hi" (from 2100) is still inside, so the word times stay.
        let startKept = try planCaptionTrim(t, cueId: "b", edge: .start, toMs: 2050, frameRate: 25)
        XCTAssertEqual(startKept.cues[1], makeCue("b", 2050, 3000, "hi there", words: words))

        // Start at 2150: "hi" (from 2100) is cut, so the word times go.
        let startCut = try planCaptionTrim(t, cueId: "b", edge: .start, toMs: 2150, frameRate: 25)
        XCTAssertEqual(startCut.cues[1], makeCue("b", 2150, 3000, "hi there"))
    }

    func testTrimOfAnUnknownCueThrows() {
        let t = makeTrack(makeCue("a", 0, 1000, "a"))
        assertEditFails(.unknownCue("nope")) { _ = try planCaptionTrim(t, cueId: "nope", edge: .end, toMs: 500, frameRate: 25) }
    }

    // MARK: Retext

    func testRetextNormalisesLineEndingsToNewlines() throws {
        let t = makeTrack(makeCue("a", 0, 1000, "a"))
        let out = try planCaptionRetext(t, cueId: "a", text: "one\r\ntwo\rthree")
        XCTAssertEqual(out.cues[0], makeCue("a", 0, 1000, "one\ntwo\nthree"))
    }

    func testRetextKeepsWordTimesOnlyWhileTheyStillSpellTheText() throws {
        let words = [makeWord("hi", 2100, 2400), makeWord("there", 2400, 2900)]
        let t = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 2000, 3000, "hi there", words: words), makeCue("c", 5000, 6000, "c"))

        // Same words: the word times stay.
        let same = try planCaptionRetext(t, cueId: "b", text: "hi there")
        XCTAssertEqual(same.cues[1], makeCue("b", 2000, 3000, "hi there", words: words))

        // A different word: the word times go.
        let otherWord = try planCaptionRetext(t, cueId: "b", text: "hi you")
        XCTAssertEqual(otherWord.cues[1], makeCue("b", 2000, 3000, "hi you"))

        // Same words but a line break where the space was: the words no longer spell the text, so they go.
        let newLine = try planCaptionRetext(t, cueId: "b", text: "hi\r\nthere")
        XCTAssertEqual(newLine.cues[1], makeCue("b", 2000, 3000, "hi\nthere"))
    }

    func testRetextRefusesEmptyBlankLineAndArrowText() {
        let t = makeTrack(makeCue("a", 0, 1000, "a"))
        assertEditFails(.invalidText("Caption text must not be empty")) { _ = try planCaptionRetext(t, cueId: "a", text: "") }
        assertEditFails(.invalidText("Caption text must not hold a blank line")) { _ = try planCaptionRetext(t, cueId: "a", text: "a\n\nb") }
        assertEditFails(.invalidText("Caption text must not hold \"-->\" (it marks an SRT timing line)")) {
            _ = try planCaptionRetext(t, cueId: "a", text: "x --> y")
        }
    }

    func testRetextOfAnUnknownCueThrows() {
        let t = makeTrack(makeCue("a", 0, 1000, "a"))
        assertEditFails(.unknownCue("nope")) { _ = try planCaptionRetext(t, cueId: "nope", text: "fine") }
    }

    // MARK: Add

    func testAddOnANilTrackCreatesTheTrackWithATwoSecondCue() throws {
        let created = try planCaptionAdd(nil, atMs: 1000, frameRate: 25)
        XCTAssertEqual(created.track.id, NATIVE_CAPTION_TRACK_DEFAULT_ID)
        XCTAssertEqual(created.track.id, "captions:main")
        XCTAssertEqual(created.cueId, "cue:manual-1")
        // Nothing after it, so it runs its full 2000 ms: 1000 to 3000.
        XCTAssertEqual(created.track.cues, [makeCue("cue:manual-1", 1000, 3000, "Caption")])

        // An empty track keeps its own id.
        let empty = try planCaptionAdd(NativeCaptionTrack(id: "custom", cues: []), atMs: 0, frameRate: 25)
        XCTAssertEqual(empty.track.id, "custom")
        XCTAssertEqual(empty.track.cues, [makeCue("cue:manual-1", 0, 2000, "Caption")])
    }

    func testAddStopsAtTheNextCueWhenTheGapIsShorterThanTwoSeconds() throws {
        // a 0-500, b 2500-4000: a cue at 1000 can run to 2500 only (1500 ms), not 3000.
        let t = makeTrack(makeCue("a", 0, 500, "a"), makeCue("b", 2500, 4000, "b"))
        let out = try planCaptionAdd(t, atMs: 1000, frameRate: 25)
        XCTAssertEqual(out.cueId, "cue:manual-1")
        XCTAssertEqual(out.track.cues, [
            makeCue("a", 0, 500, "a"),
            makeCue("cue:manual-1", 1000, 2500, "Caption"),
            makeCue("b", 2500, 4000, "b"),
        ])
    }

    func testAddRefusesAStartInsideACueAndAGapUnderOneFrame() throws {
        let t = makeTrack(makeCue("a", 0, 1000, "a"))
        // Inside a: its first and its last millisecond.
        assertEditFails(.noRoom) { _ = try planCaptionAdd(t, atMs: 0, frameRate: 25) }
        assertEditFails(.noRoom) { _ = try planCaptionAdd(t, atMs: 999, frameRate: 25) }
        // Negative start.
        assertEditFails(.noRoom) { _ = try planCaptionAdd(nil, atMs: -1, frameRate: 25) }

        // A 39 ms gap at 25 fps (minimum 40): no room.
        let tight = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 1039, 2000, "b"))
        assertEditFails(.noRoom) { _ = try planCaptionAdd(tight, atMs: 1000, frameRate: 25) }

        // A 33 ms gap at 30 fps (minimum 34): no room.
        let tight30 = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 1033, 2000, "b"))
        assertEditFails(.noRoom) { _ = try planCaptionAdd(tight30, atMs: 1000, frameRate: 30) }

        // A gap of exactly one frame (40 ms at 25 fps) holds a cue.
        let exact = makeTrack(makeCue("a", 0, 1000, "a"), makeCue("b", 1040, 2000, "b"))
        let out = try planCaptionAdd(exact, atMs: 1000, frameRate: 25)
        XCTAssertEqual(out.track.cues[1], makeCue("cue:manual-1", 1000, 1040, "Caption"))
    }

    func testAddSkipsIdsAlreadyUsedInTheTrack() throws {
        let t = makeTrack(makeCue("cue:manual-1", 0, 500, "X"), makeCue("cue:manual-2", 5000, 6000, "Y"))
        let out = try planCaptionAdd(t, atMs: 1000, frameRate: 25)
        XCTAssertEqual(out.cueId, "cue:manual-3")
        XCTAssertEqual(out.track.cues.map(\.id), ["cue:manual-1", "cue:manual-3", "cue:manual-2"])
        XCTAssertEqual(out.track.cues[1], makeCue("cue:manual-3", 1000, 3000, "Caption"))
    }

    func testAddInsertsInStartOrder() throws {
        let t = makeTrack(makeCue("a", 0, 500, "a"), makeCue("c", 5000, 6000, "c"))

        // Between a and c.
        let middle = try planCaptionAdd(t, atMs: 1000, frameRate: 25)
        XCTAssertEqual(middle.track.cues.map(\.id), ["a", "cue:manual-1", "c"])

        // After c: appended, and with no cue after it, a full 2000 ms.
        let last = try planCaptionAdd(middle.track, atMs: 6000, frameRate: 25)
        XCTAssertEqual(last.cueId, "cue:manual-2")
        XCTAssertEqual(last.track.cues.map(\.id), ["a", "cue:manual-1", "c", "cue:manual-2"])
        XCTAssertEqual(last.track.cues[3], makeCue("cue:manual-2", 6000, 8000, "Caption"))
    }

    // MARK: Validation

    func testEveryEditResultPassesTheCaptionValidator() throws {
        // a 0-1000 "one", b 2000-3000 "hi there" (hi 2100-2400, there 2400-2900), c 5000-6000 "three"
        let words = [makeWord("hi", 2100, 2400), makeWord("there", 2400, 2900)]
        let start = makeTrack(makeCue("a", 0, 1000, "one"), makeCue("b", 2000, 3000, "hi there", words: words), makeCue("c", 5000, 6000, "three"))
        try assertValidTrack(start, "start")

        let moved = try planCaptionMove(start, cueId: "b", toStartMs: 1500)
        let trimmedEnd = try planCaptionTrim(moved, cueId: "b", edge: .end, toMs: 2450, frameRate: 25)
        let trimmedStart = try planCaptionTrim(trimmedEnd, cueId: "c", edge: .start, toMs: 2000, frameRate: 25)
        let retexted = try planCaptionRetext(trimmedStart, cueId: "a", text: "one\r\ntwo")
        let added = try planCaptionAdd(retexted, atMs: 6000, frameRate: 25).track

        let steps: [(String, NativeCaptionTrack)] = [
            ("move", moved), ("trim end", trimmedEnd), ("trim start", trimmedStart), ("retext", retexted), ("add", added),
        ]
        for (label, track) in steps {
            try assertValidTrack(track, label)
        }

        XCTAssertEqual(added.cues, [
            makeCue("a", 0, 1000, "one\ntwo"),
            makeCue("b", 1500, 2450, "hi there", words: [makeWord("hi", 1600, 1900), makeWord("there", 1900, 2400)]),
            makeCue("c", 2450, 6000, "three"),
            makeCue("cue:manual-1", 6000, 8000, "Caption"),
        ])
    }

    func testTheValidatorHelperRejectsAnOverlap() throws {
        // A control: the same checks must fail on a track that overlaps, or they prove nothing.
        let overlapping = makeTrack(makeCue("a", 0, 2000, "A"), makeCue("b", 1999, 3000, "B"))
        var issues: [NativeProjectDocumentValidationIssue] = []
        validateNativeCaptionTrack(try validatorJSON(overlapping), "sequence.captions", &issues)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertNotNil(nativeCaptionTimingProblem(overlapping.cues[1], after: overlapping.cues[0]))
    }

    func testTrimNeverOverlapsANeighbourWhenTheCueIsShorterThanAFrame() throws {
        // 10 ms cue touching the next cue: a 30 fps frame (34 ms) does not fit, so the end stays at the next cue's start.
        let track = makeTrack(makeCue("a", 1000, 1010, "a"), makeCue("b", 1010, 2000, "b"))
        let out = try planCaptionTrim(track, cueId: "a", edge: .end, toMs: 1500, frameRate: 30)
        XCTAssertEqual(out.cues[0].endMs, 1010)
        XCTAssertNil(nativeCaptionTimingProblem(out.cues[1], after: out.cues[0]))
        let start = try planCaptionTrim(track, cueId: "a", edge: .start, toMs: 1005, frameRate: 30)
        XCTAssertEqual(start.cues[0].startMs, 1000)
    }
}
