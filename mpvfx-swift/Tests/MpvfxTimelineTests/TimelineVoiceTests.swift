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

final class TimelineVoiceTests: XCTestCase {
    func testA3ThreeTakesKeepAndMuteEarlierTakesAndUndoRestoresThem() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let before = e.document
        for n in 1...3 { XCTAssertTrue(e.addVoiceTake(source: "media/take\(n).wav", seconds: 1, at: 2)) }
        let track = try XCTUnwrap(e.document.sequence.tracks.first { $0.id.hasPrefix("track:voice:") })
        XCTAssertEqual(track.clips.count, 3)
        XCTAssertEqual(track.clips.filter(\.muted).count, 2)
        XCTAssertEqual(e.document.assets.filter { $0.name.hasPrefix("Voice-over ") }.count, 3)
        let json = try serializeNativeProjectDocument(e.document, engine: e.engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(json), engine: e.engine), e.document)
        XCTAssertEqual(e.undoLabel, "Record voice")
        XCTAssertTrue(e.undo())
        let restored = try XCTUnwrap(e.document.sequence.tracks.first { $0.id == track.id })
        XCTAssertEqual(restored.clips.count, 2)
        XCTAssertEqual(restored.clips.filter { !$0.muted }.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before)
    }

    func testLockedVoiceTrackIsKeptAndANewTrackIsUsed() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        XCTAssertTrue(e.addVoiceTake(source: "media/one.wav", seconds: 1, at: 2))
        var locked = e.document
        let i = try XCTUnwrap(locked.sequence.tracks.firstIndex { $0.id.hasPrefix("track:voice:") })
        locked.sequence.tracks[i].locked = true
        e.loadDocument(locked)
        XCTAssertTrue(e.addVoiceTake(source: "media/two.wav", seconds: 1, at: 2))
        XCTAssertEqual(e.document.sequence.tracks[i], locked.sequence.tracks[i])
        XCTAssertEqual(e.document.sequence.tracks.filter { $0.id.hasPrefix("track:voice:") }.count, 2)
    }
}
