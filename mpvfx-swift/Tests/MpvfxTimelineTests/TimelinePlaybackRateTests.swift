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

final class TimelinePlaybackRateTests: XCTestCase {
    func testRateScalesTheClipAndIsOneUndoStep() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let before = try XCTUnwrap(editor.clip("clip:b")?.clip.durationFrames)
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:b", 2))
        XCTAssertEqual(editor.clip("clip:b")?.clip.durationFrames, (before / 2).rounded())
        XCTAssertEqual(editor.playbackRate(clipId: "clip:b"), 2, accuracy: 1e-9)
        XCTAssertFalse(editor.setPlaybackRate(clipId: "clip:b", 2), "same rate is no edit")
        XCTAssertEqual(editor.undoLabel, "Change speed")
        editor.undo()
        XCTAssertEqual(editor.clip("clip:b")?.clip.durationFrames, before)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:b"), 1)
        XCTAssertTrue(editor.setTrackLocked("track:v1", true))
        XCTAssertFalse(editor.setPlaybackRate(clipId: "clip:b", 0.5))
    }

    /// A speed-up shortens the clip; its fades (issue #85) are clamped so the document stays valid.
    func testSpeedUpClampsTheClipFades() throws {
        let engine = try? KeyframeRuntime()
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(TimelineEditor.demoJSON), engine: engine)
        let t = try XCTUnwrap(doc.sequence.tracks.firstIndex { $0.clips.contains { $0.id == "clip:b" } })
        let c = try XCTUnwrap(doc.sequence.tracks[t].clips.firstIndex { $0.id == "clip:b" })
        let duration = doc.sequence.tracks[t].clips[c].durationFrames
        doc.sequence.tracks[t].clips[c].fadeInFrames = (duration / 2).rounded(.down)
        doc.sequence.tracks[t].clips[c].fadeOutFrames = (duration / 2).rounded(.down)
        let editor = try TimelineEditor(json: try serializeNativeProjectDocument(doc, engine: engine), engine: engine)
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:b", 4))
        let sped = try XCTUnwrap(editor.clip("clip:b")?.clip)
        XCTAssertEqual(sped.fadeInFrames, min((duration / 2).rounded(.down), sped.durationFrames), "the fade-in keeps its length, cut to the clip")
        XCTAssertLessThanOrEqual((sped.fadeInFrames ?? 0) + (sped.fadeOutFrames ?? 0), sped.durationFrames)
    }
}
