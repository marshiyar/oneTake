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
// Narration from text in the document (#349): the `narration` record on an audio clip, its validator, the unread
// record from a later version, and the insert / re-speak plans.
import XCTest
@testable import MpvfxShared

/// 30 fps; one audio track with a narration clip (frames 0–60) and a music clip after it (frames 120–180).
func narrationDocument(narration: String = #"{"v":1,"text":"Hello there","voiceId":"voice.a","voiceName":"Voice A"}"#) -> NativeJSONValue {
    J("""
    {"schemaVersion":1,"mediaEngine":"native","id":"project:n","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#000000"},
     "assets":[{"id":"asset:say","kind":"audio","name":"Narration.wav","source":"Narration/Narration.wav","durationFrames":60},
               {"id":"asset:music","kind":"audio","name":"Music.wav","source":"Music.wav","durationFrames":600}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:audio-1","kind":"audio","clips":[
       {"id":"clip:say","assetId":"asset:say","startFrame":0,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[],
        "staticParameters":{"audio.volume":0.5},"audioFxChain":"[{\\"type\\":\\"eq\\"}]","audioAutomation":"{\\"lanes\\":[]}",
        "fadeInFrames":10,"fadeOutFrames":10,"narration":\(narration)},
       {"id":"clip:music","assetId":"asset:music","startFrame":120,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
    """)
}

final class NativeClipNarrationTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("expected a validation error", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func withNarration(_ value: NativeJSONValue) -> NativeJSONValue {
        var d = narrationDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["narration"] = value
        return d
    }
    func respeakEdit(samples: Int, text: String = "Hello there, and welcome back") -> NativeNarrationEdit {
        NativeNarrationEdit(audio: NativeNarrationAudio(assetId: "asset:say-2", source: "Narration/Narration (2).wav", name: "Narration (2).wav",
                                                        samples48k: samples),
                            narration: NativeClipNarration(text: text, voiceId: "voice.a", voiceName: "Voice A"))
    }

    // MARK: A1 round trip, byte identity, validator

    func testA1NarrationRoundTripsAndADocumentWithoutItSavesByteIdentical() throws {
        let text = try serialize(narrationDocument())
        let doc = try parse(J(text))
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].narration?.narration,
                       NativeClipNarration(text: "Hello there", voiceId: "voice.a", voiceName: "Voice A"))
        XCTAssertEqual(try serialize(J(text)), text)
        XCTAssertTrue(text.contains(#""narration": {"#), text)
        // Absent stays absent: a document without narration serializes to the same bytes as before the field existed.
        let plain = try serialize(validNativeDocument())
        XCTAssertFalse(plain.contains("narration"))
        XCTAssertEqual(try serialize(J(plain)), plain)
        XCTAssertEqual(try parse(J(plain)).schemaVersion, 1)
    }

    func testA1RateAndPitchAreOmittedAtTheirDefaultsAndKeptOtherwise() throws {
        let plain = NativeClipNarration(text: "a", voiceId: "v", voiceName: "V", rate: 1, pitch: 0)
        XCTAssertNil(plain.rate); XCTAssertNil(plain.pitch)
        let json = try NativeJSONValue.from(plain)
        XCTAssertEqual(json.objectValue.map { Array($0.keys).sorted() }, ["text", "v", "voiceId", "voiceName"])
        XCTAssertEqual(json["v"], .number(1))
        let tuned = NativeClipNarration(text: "a", voiceId: "v", voiceName: "V", rate: 1.5, pitch: -3)
        let doc = try parse(withNarration(try NativeJSONValue.from(tuned)))
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].narration?.narration?.rate, 1.5)
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].narration?.narration?.pitch, -3)
    }

    func testA1ValidatorReportsEveryBadNarrationValueAsATypedIssue() {
        let long = String(repeating: "a", count: NativeNarrationScale.textLimit + 1)
        let cases: [(NativeJSONValue, String, String)] = [
            (.string("hello"), ".narration", "Narration must be an object"),
            (J(#"{"text":"a","voiceId":"v","voiceName":"V"}"#), ".narration.v", "Narration version must be a whole number of at least 1"),
            (J(#"{"v":1.5,"text":"a","voiceId":"v","voiceName":"V"}"#), ".narration.v", "Narration version must be a whole number of at least 1"),
            (J(#"{"v":1,"text":"   ","voiceId":"v","voiceName":"V"}"#), ".narration.text", "Narration text must not be empty"),
            (J(#"{"v":1,"text":"\#(long)","voiceId":"v","voiceName":"V"}"#), ".narration.text", "Narration text must be at most 20000 characters"),
            (J(#"{"v":1,"voiceId":"v","voiceName":"V"}"#), ".narration.text", "Narration text must be a string"),
            (J(#"{"v":1,"text":"a","voiceName":"V"}"#), ".narration.voiceId", "Narration voice ID must be a non-empty string"),
            (J(#"{"v":1,"text":"a","voiceId":"","voiceName":"V"}"#), ".narration.voiceId", "Narration voice ID must be a non-empty string"),
            (J(#"{"v":1,"text":"a","voiceId":"v"}"#), ".narration.voiceName", "Narration voice name must be a string"),
            (J(#"{"v":1,"text":"a","voiceId":"v","voiceName":"V","rate":3}"#), ".narration.rate", "Narration rate must be a finite number from 0.5 to 2"),
            (J(#"{"v":1,"text":"a","voiceId":"v","voiceName":"V","rate":"fast"}"#), ".narration.rate", "Narration rate must be a finite number from 0.5 to 2"),
            (J(#"{"v":1,"text":"a","voiceId":"v","voiceName":"V","pitch":-13}"#), ".narration.pitch", "Narration pitch must be a finite number from -12 to 12"),
        ]
        for (value, suffix, message) in cases {
            let found = issues(withNarration(value))
            XCTAssertEqual(found.map(\.code), [.invalidNarration], "\(value)")
            XCTAssertEqual(found.first?.path, "sequence.tracks[0].clips[0]\(suffix)", "\(value)")
            XCTAssertEqual(found.first?.message, message, "\(value)")
        }
        // Non-finite numbers cannot be written as JSON text but can reach the validator from an in-memory document.
        for key in ["rate", "pitch"] {
            for bad in [Double.nan, .infinity] {
                var value = J(#"{"v":1,"text":"a","voiceId":"v","voiceName":"V"}"#)
                value[key] = .number(bad)
                XCTAssertEqual(issues(withNarration(value)).map(\.path), ["sequence.tracks[0].clips[0].narration.\(key)"])
            }
        }
    }

    func testA1OnlyAnAudioClipCanCarryNarration() {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["narration"] = J(#"{"v":1,"text":"a","voiceId":"v","voiceName":"V"}"#)
        let found = issues(d)
        XCTAssertEqual(found.map(\.message), ["Only a clip of an audio asset can carry narration"])
        XCTAssertEqual(found.map(\.code), [.invalidNarration])
    }

    func testANarrationWithAnUnknownVersionIsKeptUnchangedAndNoticedOnce() throws {
        let future = #"{"v":2,"text":7,"voices":["x"],"prosody":{"emphasis":"strong"}}"#
        let text = try serialize(narrationDocument(narration: future))
        let doc = try parse(J(text))
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].narration, .unread(J(future)))
        XCTAssertNil(doc.sequence.tracks[0].clips[0].narration?.narration)
        XCTAssertEqual(try serialize(J(text)), text)
        XCTAssertEqual(doc.unreadNarrationCount, 1)
        XCTAssertEqual(doc.unreadNarrationNotice,
                       "1 narration clip from a newer version of the editor plays from its audio file; it cannot be spoken again here.")
        XCTAssertNil(try parse(narrationDocument()).unreadNarrationNotice)
        // Re-speak is off for it, with the reason.
        XCTAssertEqual(planNativeNarrationRespeak(doc, clipId: "clip:say", respeakEdit(samples: 96_000), engine: engine).error,
                       .unreadNarration(clipId: "clip:say"))
        XCTAssertEqual(NativeNarrationPlanFailure.unreadNarration(clipId: "clip:say").description,
                       "This narration comes from a newer version of the editor and cannot be spoken again here")
    }

    func testUnknownKeysOfAVersionOneRecordSurviveASave() throws {
        let text = try serialize(narrationDocument(narration: #"{"v":1,"text":"a","voiceId":"v","voiceName":"V","style":"calm"}"#))
        XCTAssertTrue(text.contains(#""style": "calm""#), text)
        var doc = try parse(J(text))
        doc.revision += 1
        XCTAssertTrue(try serializeNativeProjectDocument(doc, engine: engine).contains(#""style": "calm""#))
    }

    // MARK: A3 re-speak

    func testA3RespeakWithLongerTextKeepsStartVolumeFxAndAutomationAndChangesOnlyAssetAndDuration() throws {
        let doc = try parse(narrationDocument())
        let before = doc.sequence.tracks[0].clips[0]
        // 3 s at 48 kHz = 90 frames at 30 fps: past the old end (60), short of the music clip (120).
        let result = planNativeNarrationRespeak(doc, clipId: "clip:say", respeakEdit(samples: 144_000), engine: engine)
        let plan = try XCTUnwrap(result.value)
        XCTAssertEqual(plan.durationFrames, 90)
        let after = plan.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(after.assetId, "asset:say-2")
        XCTAssertEqual(after.durationFrames, 90)
        XCTAssertEqual(after.narration?.narration?.text, "Hello there, and welcome back")
        var expected = before
        expected.assetId = after.assetId; expected.durationFrames = after.durationFrames; expected.narration = after.narration
        XCTAssertEqual(after, expected, "only asset, duration and the record change")
        XCTAssertEqual(after.staticParameters?["audio.volume"], before.staticParameters?["audio.volume"])
        XCTAssertEqual(after.audioFxChain, before.audioFxChain); XCTAssertEqual(after.audioAutomation, before.audioAutomation)
        // The earlier WAV's asset stays in the document (the unused-media rules decide about it).
        XCTAssertEqual(plan.document.assets.map(\.id), ["asset:say", "asset:music", "asset:say-2"])
        XCTAssertEqual(plan.document.assets.last?.durationFrames, 90)
        XCTAssertEqual(plan.document.sequence.tracks[0].clips[1], doc.sequence.tracks[0].clips[1])
    }

    func testA3RespeakThatWouldOverlapTheNextClipIsRefusedWithItsName() throws {
        let doc = try parse(narrationDocument())
        // 5 s = 150 frames: runs into the music clip at 120.
        let failure = planNativeNarrationRespeak(doc, clipId: "clip:say", respeakEdit(samples: 240_000), engine: engine).error
        XCTAssertEqual(failure, .overlapsClip(clipId: "clip:music", name: "Music.wav"))
        XCTAssertEqual(failure?.description, "The narration would overlap \"Music.wav\" on its track")
        // Exactly up to the next clip fits (no ripple, no trim of the neighbour).
        XCTAssertEqual(planNativeNarrationRespeak(doc, clipId: "clip:say", respeakEdit(samples: 192_000), engine: engine).value?.durationFrames, 120)
    }

    func testRespeakShorterCutsTheFadesAsATrimDoesAndRefusesClipsThatAreNotNarration() throws {
        let doc = try parse(narrationDocument())
        let plan = try XCTUnwrap(planNativeNarrationRespeak(doc, clipId: "clip:say", respeakEdit(samples: 24_000), engine: engine).value)
        let clip = plan.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.durationFrames, 15)
        XCTAssertEqual(clip.fadeInFrames, 10); XCTAssertEqual(clip.fadeOutFrames, 5)
        XCTAssertEqual(planNativeNarrationRespeak(doc, clipId: "clip:music", respeakEdit(samples: 24_000), engine: engine).error,
                       .notNarration(clipId: "clip:music"))
        XCTAssertEqual(planNativeNarrationRespeak(doc, clipId: "clip:nope", respeakEdit(samples: 24_000), engine: engine).error,
                       .clipNotFound(clipId: "clip:nope"))
        XCTAssertEqual(planNativeNarrationRespeak(doc, clipId: "clip:say", respeakEdit(samples: 1_000), engine: engine).error,
                       .audioTooShort(samples48k: 1_000))
        var locked = doc; locked.sequence.tracks[0].locked = true
        XCTAssertEqual(planNativeNarrationRespeak(locked, clipId: "clip:say", respeakEdit(samples: 24_000), engine: engine).error,
                       .trackLocked(trackId: "track:audio-1"))
    }

    // MARK: Insert

    func testInsertPlacesAnAudioClipAtTheRequestedPlaceWithItsRecord() throws {
        let doc = try parse(narrationDocument())
        let edit = respeakEdit(samples: 48_000, text: "Chapter two")
        let plan = try XCTUnwrap(planNativeNarrationInsert(doc, edit, at: NativeNarrationPlacement(trackId: "track:audio-1", startFrame: 200,
                                                                                                  clipId: "clip:new"), engine: engine).value)
        let clip = try XCTUnwrap(plan.document.sequence.tracks[0].clips.first { $0.id == "clip:new" })
        XCTAssertEqual(clip.startFrame, 200); XCTAssertEqual(clip.durationFrames, 30); XCTAssertEqual(clip.assetId, "asset:say-2")
        XCTAssertEqual(clip.narration?.narration?.text, "Chapter two")
        XCTAssertEqual(plan.document.assets.last?.kind, .audio)
        XCTAssertEqual(plan.document.assets.last?.source, "Narration/Narration (2).wav")
        XCTAssertEqual(planNativeNarrationInsert(doc, edit, at: .init(trackId: "track:audio-1", startFrame: 100, clipId: "clip:new"),
                                                 engine: engine).error,
                       .overlapsClip(clipId: "clip:music", name: "Music.wav"))
        XCTAssertEqual(planNativeNarrationInsert(doc, edit, at: .init(trackId: "track:x", startFrame: 0, clipId: "clip:new"), engine: engine).error,
                       .trackNotFound(trackId: "track:x"))
        XCTAssertEqual(planNativeNarrationInsert(doc, edit, at: .init(trackId: "track:audio-1", startFrame: -1, clipId: "clip:new"),
                                                 engine: engine).error, .invalidStart(frame: -1))
        let video = try parse(validNativeDocument())
        XCTAssertEqual(planNativeNarrationInsert(video, edit, at: .init(trackId: "track:video-1", startFrame: 0, clipId: "clip:new"),
                                                 engine: engine).error, .trackNotAudio(trackId: "track:video-1"))
        // A clip id already in use is refused by the document validator, never written.
        if case .documentRejected? = planNativeNarrationInsert(doc, edit, at: .init(trackId: "track:audio-1", startFrame: 200, clipId: "clip:music"),
                                                               engine: engine).error {} else { XCTFail("duplicate clip id accepted") }
    }

    func testSampleToFrameConversionIsExactIntegerArithmetic() {
        // 30 000 frames at 30000/1001 fps are exactly 48 048 000 samples.
        XCTAssertEqual(nativeNarrationFrames(samples48k: 48_048_000, frameRate: .init(numerator: 30000, denominator: 1001)), 30_000)
        XCTAssertEqual(nativeNarrationFrames(samples48k: 48_047_999, frameRate: .init(numerator: 30000, denominator: 1001)), 29_999)
        XCTAssertEqual(nativeNarrationFrames(samples48k: 1_599, frameRate: .init(numerator: 30, denominator: 1)), 0)
        XCTAssertNil(nativeNarrationFrames(samples48k: 10, frameRate: .init(numerator: 29.97, denominator: 1)))
        XCTAssertNil(nativeNarrationFrames(samples48k: Int.max, frameRate: .init(numerator: 30, denominator: 1)))
    }
}
