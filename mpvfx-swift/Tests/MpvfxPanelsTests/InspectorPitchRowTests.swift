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
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Media group's "Keep audio pitch" row goes with the clip that plays the sound.
final class InspectorPitchRowTests: XCTestCase {
    static let json = ##"""
    {"schemaVersion":1,"id":"project:pitch","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:a","kind":"video","name":"a.mp4","source":"media/a.mp4","durationFrames":600}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """##

    func pitchRow(_ p: InspectorPanel) -> InspectorRow.Toggle? {
        for r in p.groups.flatMap(\.addressableRows) { if case .toggle(let t) = r.kind, t.key == "keepPitch" { return t } }
        return nil
    }

    func testDetachedVideoHasNoPitchRowAndItsAudioDoes() throws {
        let editor = try TimelineEditor(json: Self.json)
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]
        XCTAssertNotNil(pitchRow(p), "a video playing its own sound")
        XCTAssertTrue(editor.detachAudio(clipId: "clip:a"))
        XCTAssertNil(pitchRow(p), "the detached video is silent")
        let audio = try XCTUnwrap(editor.document.sequence.tracks.flatMap(\.clips).first { $0.audioDetachedFrom == "clip:a" })
        p.selection = [audio.id]
        let row = try XCTUnwrap(pitchRow(p))
        row.set(false)
        XCTAssertEqual(editor.preservesPitch(clipId: audio.id), false)
    }
}
