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
// Narration from text on the timeline (#349 A2, A3): adding a narration clip and speaking it again are one undo step each.
import XCTest
@testable import MpvfxTimeline
import MpvfxShared

final class TimelineNarrationTests: XCTestCase {
    func edit(_ assetId: String, samples: Int, text: String) -> NativeNarrationEdit {
        NativeNarrationEdit(audio: NativeNarrationAudio(assetId: assetId, source: "Narration/\(assetId).wav", name: "\(assetId).wav", samples48k: samples),
                            narration: NativeClipNarration(text: text, voiceId: "stub.voice.a", voiceName: "Stub A"))
    }

    func testA2AddingNarrationIsOneUndoStepAndUndoRemovesTheClip() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let before = e.document
        // 2 s of audio at 48 kHz = 60 frames at 30 fps, after the music clip (0–330) on track a1.
        let plan = try XCTUnwrap(planNativeNarrationInsert(e.document, edit("asset:say", samples: 96_000, text: "Welcome"),
                                                           at: NativeNarrationPlacement(trackId: "track:a1", startFrame: 400, clipId: "clip:say"),
                                                           engine: e.engine).value)
        XCTAssertTrue(e.addNarration(plan))
        let clip = try XCTUnwrap(e.document.sequence.tracks.flatMap(\.clips).first { $0.id == "clip:say" })
        XCTAssertEqual(clip.startFrame, 400); XCTAssertEqual(clip.durationFrames, 60)
        XCTAssertEqual(clip.narration?.narration?.text, "Welcome")
        XCTAssertEqual(e.undoLabel, "Add narration")
        XCTAssertTrue(e.undo())
        XCTAssertFalse(e.canUndo, "one undo step")
        XCTAssertNil(e.document.sequence.tracks.flatMap(\.clips).first { $0.id == "clip:say" })
        XCTAssertEqual(e.document.assets, before.assets)
        XCTAssertTrue(e.redo())
        XCTAssertNotNil(e.document.sequence.tracks.flatMap(\.clips).first { $0.id == "clip:say" })
    }

    func testA3SpeakingAgainIsOneUndoStepThatBringsTheEarlierAudioBack() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let insert = try XCTUnwrap(planNativeNarrationInsert(e.document, edit("asset:say", samples: 96_000, text: "Welcome"),
                                                             at: .init(trackId: "track:a1", startFrame: 400, clipId: "clip:say"), engine: e.engine).value)
        XCTAssertTrue(e.addNarration(insert))
        let respeak = try XCTUnwrap(planNativeNarrationRespeak(e.document, clipId: "clip:say", edit("asset:say-2", samples: 144_000, text: "Welcome back"),
                                                               engine: e.engine).value)
        XCTAssertTrue(e.respeakNarration(respeak))
        XCTAssertEqual(e.undoLabel, "Speak narration again")
        let spoken = try XCTUnwrap(e.document.sequence.tracks.flatMap(\.clips).first { $0.id == "clip:say" })
        XCTAssertEqual(spoken.assetId, "asset:say-2"); XCTAssertEqual(spoken.durationFrames, 90)
        XCTAssertTrue(e.undo())
        let restored = try XCTUnwrap(e.document.sequence.tracks.flatMap(\.clips).first { $0.id == "clip:say" })
        XCTAssertEqual(restored.assetId, "asset:say"); XCTAssertEqual(restored.durationFrames, 60)
        XCTAssertEqual(restored.narration?.narration?.text, "Welcome")
    }
}
