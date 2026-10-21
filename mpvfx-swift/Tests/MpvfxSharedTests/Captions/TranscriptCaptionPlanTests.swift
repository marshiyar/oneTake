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

/// Recognised words become caption cues (issue #342): time mapping, grouping rules, word times, overlap choices.
final class TranscriptCaptionPlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func w(_ text: String, _ s: Int, _ e: Int) -> TranscriptWord { TranscriptWord(text: text, startMs: s, endMs: e) }

    /// 30 fps; the clip starts at sequence 5 s, shows media from 2 s for 10 s of timeline, at `rate`.
    func document(rate: Int = 1, captions: String? = nil) throws -> NativeProjectDocument {
        var d = validNativeDocument()
        d["frameRate"] = J(#"{"numerator":30,"denominator":1}"#)
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["startFrame"] = .number(150)
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["sourceInFrame"] = .number(60)
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["durationFrames"] = .number(300)
        d["assets"]?[0]?["durationFrames"] = .number(3000)
        if rate != 1 { d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["playbackRate"] = J(#"{"numerator":\#(rate),"denominator":1}"#) }
        if let captions { d["sequence"]?["captions"] = J(captions) }
        return try parseNativeProjectDocument(d, engine: engine)
    }
    let clipId = "clip:camera-a-1"
    func plan(_ words: [TranscriptWord], rate: Int = 1, captions: String? = nil,
              overlap: TranscriptCaptionOverlap = .replaceRange) throws -> TranscriptCaptionPlan {
        try planTranscriptCaptions(try document(rate: rate, captions: captions), clipId: clipId, words: words, overlap: overlap)
    }
    func cues(_ words: [TranscriptWord]) throws -> [NativeCaptionCue] { try plan(words).document.sequence.captions?.cues ?? [] }

    // A1: a 200 ms pause keeps one cue, a 900 ms pause splits.
    func testAPauseOfNineHundredMillisecondsSplitsAndTwoHundredDoesNot() throws {
        let c = try cues([w("one", 2000, 2300), w("two", 2500, 2800), w("three", 3700, 4000)])
        XCTAssertEqual(c.map(\.text), ["one two", "three"])
    }

    func testASentenceEndSplitsOnlyAfterThreeWords() throws {
        let long = try cues([w("a", 2000, 2100), w("b", 2150, 2250), w("end.", 2300, 2400), w("next", 2450, 2550)])
        XCTAssertEqual(long.map(\.text), ["a b end.", "next"])
        let short = try cues([w("Hi.", 2000, 2100), w("there", 2150, 2250)])
        XCTAssertEqual(short.map(\.text), ["Hi. there"])
    }

    func testACueNeverExceedsEightyFourCharacters() throws {
        let words = (0..<12).map { w(String(repeating: "x", count: 9), 2000 + $0 * 300, 2200 + $0 * 300) }
        let c = try cues(words)
        XCTAssertEqual(c.count, 2)
        XCTAssertTrue(c.allSatisfy { $0.text.count <= TranscriptCaptionRules.maxCharacters }, "\(c.map(\.text.count))")
        XCTAssertEqual(c[0].text.count, 9 * 8 + 7)
    }

    func testACueNeverRunsLongerThanSixSeconds() throws {
        let words = (0..<10).map { w("w\($0)", 2000 + $0 * 700, 2600 + $0 * 700) }
        let c = try cues(words)
        XCTAssertGreaterThan(c.count, 1)
        XCTAssertTrue(c.allSatisfy { $0.endMs - $0.startMs <= TranscriptCaptionRules.maxCueMs }, "\(c)")
    }

    func testACueLastsAtLeastSevenHundredMillisecondsButNotOverTheNextCue() throws {
        let alone = try cues([w("hi", 2000, 2100)])
        XCTAssertEqual(alone[0].endMs - alone[0].startMs, 700)
        let c = try cues([w("hi", 2000, 2100), w("later", 2900, 3000)])
        XCTAssertEqual(c[0].endMs, 5000 + 700, "extended into the gap (the next cue starts at 5900)")
        let tight = try cues([w("hi", 2000, 2050), w("x", 2660, 2800)])
        XCTAssertEqual(tight.count, 2)
        XCTAssertEqual(tight[0].endMs, tight[1].startMs, "stops where the next cue starts")
    }

    // A2: clip at sequence 5 s, media start 2 s, rate 2: media 4.0-4.5 s is sequence 6.0-6.25 s.
    func testTimesMapThroughTheClipStartTrimAndRate() throws {
        let c = try plan([w("word", 4000, 4500)], rate: 2).document.sequence.captions?.cues ?? []
        XCTAssertEqual(c[0].words, [NativeCaptionWord(text: "word", start: 6000, end: 6250)])
        XCTAssertEqual(c[0].startMs, 6000)
    }

    func testWordsOutsideTheTrimmedRangeAreDroppedAndCounted() throws {
        let result = try plan([w("before", 500, 900), w("in", 3000, 3400), w("after", 13000, 13500)])
        XCTAssertEqual(result.wordsDropped, 2)
        XCTAssertEqual(result.document.sequence.captions?.cues.map(\.text), ["in"])
    }

    // A6: cleaning is counted.
    func testTextTheValidatorRefusesIsCleanedAndCounted() throws {
        let result = try plan([w("a\nb", 2000, 2200), w("x-->y", 2300, 2400), w("\u{7}", 2500, 2600), w("ok", 2700, 2800)])
        XCTAssertEqual(result.wordsCleaned, 2)
        XCTAssertEqual(result.wordsDropped, 1, "a word with nothing left is dropped")
        XCTAssertEqual(result.document.sequence.captions?.cues.first?.text, "a b x->y ok")
        XCTAssertEqual(try parseNativeProjectDocument(NativeJSONValue.from(result.document), engine: engine), result.document)
    }

    // A3: property test over random transcripts.
    func testCueWordsLieInsideInOrderAndJoinToTheText() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            var t = 2000
            var words: [TranscriptWord] = []
            for n in 0..<Int.random(in: 1...80, using: &rng) {
                t += Int.random(in: 0...1200, using: &rng)
                let len = Int.random(in: 0...500, using: &rng)
                let tail = Bool.random(using: &rng) ? "." : ""
                words.append(w("w\(n)\(tail)", t, t + len)); t += len
                if t > 11_900 { break }
            }
            let doc = try plan(words).document
            let c = doc.sequence.captions?.cues ?? []
            for cue in c {
                XCTAssertNil(nativeCaptionWordsProblem(cue), "\(cue)")
                XCTAssertEqual(cue.words?.map(\.text).joined(separator: " "), cue.text)
            }
            XCTAssertEqual(try parseNativeProjectDocument(NativeJSONValue.from(doc), engine: engine), doc)
        }
    }

    // A4: replaceRange removes only cues inside the clip's range (5 s - 15 s); keepExisting refuses on overlap.
    func testReplaceRangeRemovesOnlyCuesInsideTheClip() throws {
        let existing = #"{"id":"captions:main","cues":[{"id":"a","startMs":0,"endMs":1000,"text":"before"},{"id":"b","startMs":6000,"endMs":7000,"text":"inside"},{"id":"c","startMs":20000,"endMs":21000,"text":"after"}]}"#
        let result = try plan([w("new", 8000, 8200)], captions: existing)
        XCTAssertEqual(result.cuesReplaced, 1)
        XCTAssertEqual(result.document.sequence.captions?.cues.map(\.text), ["before", "new", "after"])
    }

    func testKeepExistingRefusesAnOverlapAndChangesNothing() throws {
        let existing = #"{"id":"captions:main","cues":[{"id":"b","startMs":6000,"endMs":7000,"text":"inside"}]}"#
        let doc = try document(captions: existing)
        XCTAssertThrowsError(try planTranscriptCaptions(doc, clipId: clipId, words: [w("new", 3000, 4200)], overlap: .keepExisting)) {
            XCTAssertEqual($0 as? TranscriptCaptionPlanError, .overlapsExistingCue(id: "b", startMs: 6000))
        }
        let kept = try planTranscriptCaptions(doc, clipId: clipId, words: [w("new", 9000, 9200)], overlap: .keepExisting)
        XCTAssertEqual(kept.document.sequence.captions?.cues.map(\.text), ["inside", "new"])
    }

    // A5: the plan is a pure document-to-document step; the input is untouched, so undo restores it byte for byte.
    func testThePlanLeavesTheInputUntouchedSoOneUndoRestoresIt() throws {
        let doc = try document(captions: #"{"id":"captions:main","cues":[{"id":"b","startMs":0,"endMs":500,"text":"keep"}]}"#)
        let before = try serializeNativeProjectDocument(doc, engine: engine)
        let after = try planTranscriptCaptions(doc, clipId: clipId, words: [w("hi", 3000, 3200)], overlap: .replaceRange).document
        XCTAssertNotEqual(after, doc)
        XCTAssertEqual(try serializeNativeProjectDocument(doc, engine: engine), before)
    }

    func testTypedRefusals() throws {
        XCTAssertThrowsError(try planTranscriptCaptions(try document(), clipId: "nope", words: [], overlap: .replaceRange)) {
            XCTAssertEqual($0 as? TranscriptCaptionPlanError, .clipNotFound("nope"))
        }
        XCTAssertThrowsError(try plan([w("b", 3000, 3100), w("a", 2000, 2100)])) {
            XCTAssertEqual($0 as? TranscriptCaptionPlanError, .wordsOutOfOrder(1))
        }
        var doc = try document()
        doc.sequence.tracks[0].clips[0].speedRamp = NativeSpeedRamp(points: [.init(t: 0, speed: 1)])
        XCTAssertThrowsError(try planTranscriptCaptions(doc, clipId: clipId, words: [], overlap: .replaceRange)) {
            XCTAssertEqual($0 as? TranscriptCaptionPlanError, .clipHasSpeedRamp(clipId))
        }
    }

    func testAnOlderDocumentWithoutWordsSavesUnchangedAndWordsValidate() throws {
        let doc = try document(captions: #"{"id":"captions:main","cues":[{"id":"b","startMs":0,"endMs":500,"text":"keep"}]}"#)
        XCTAssertFalse(try serializeNativeProjectDocument(doc, engine: engine).contains("words"))
        var d = try NativeJSONValue.from(doc)
        d["sequence"]?["captions"]?["cues"]?[0]?["words"] = J(#"[{"text":"other","start":0,"end":100}]"#)
        XCTAssertThrowsError(try parseNativeProjectDocument(d, engine: engine))
    }
}
