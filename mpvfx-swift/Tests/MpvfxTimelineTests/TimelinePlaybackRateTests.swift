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
}
