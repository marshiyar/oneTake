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
@testable import MpvfxRuntime
import MpvfxShared

/// Export leaves out what the timeline eye hides (clip.hidden, track.hidden) and keeps the sequence length.
final class ExportVisibilityTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"id":"project:vis","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":640,"height":360,"background":"#000000"},
     "assets":[{"id":"asset:v","kind":"video","name":"v.mp4","source":"v.mp4","durationFrames":600},
               {"id":"asset:m","kind":"audio","name":"m.wav","source":"m.wav","durationFrames":600}],
     "sequence":{"id":"sequence:main","name":"Main","durationFrames":60,"tracks":[
      {"id":"track:v1","kind":"video","clips":[
       {"id":"clip:shown","assetId":"asset:v","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:hidden","assetId":"asset:v","startFrame":30,"durationFrames":90,"sourceInFrame":0,"muted":false,"hidden":true,"effects":[],"parameterTracks":[]}]},
      {"id":"track:a1","kind":"audio","hidden":true,"clips":[
       {"id":"clip:music","assetId":"asset:m","startFrame":0,"durationFrames":60,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:a2","kind":"audio","clips":[
       {"id":"clip:muted","assetId":"asset:m","startFrame":0,"durationFrames":60,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
    """#

    func testDropsHiddenClipsAndTracksKeepingLength() throws {
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        let out = nativeExportVisibleProject(doc)
        XCTAssertEqual(out.sequence.tracks.map(\.id), ["track:v1", "track:a2"])
        XCTAssertEqual(out.sequence.tracks[0].clips.map(\.id), ["clip:shown"])
        // Length still covers the hidden clip's span, so the export doesn't shorten.
        XCTAssertEqual(out.sequence.durationFrames, 120)
        // A muted track stays in; its clips carry muted, which the mix silences.
        XCTAssertEqual(out.sequence.tracks[1].clips.map(\.muted), [true])
    }

    func testLeavesAFullyVisibleDocumentUntouched() throws {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        for t in doc.sequence.tracks.indices {
            doc.sequence.tracks[t].hidden = nil
            for c in doc.sequence.tracks[t].clips.indices { doc.sequence.tracks[t].clips[c].hidden = nil }
        }
        XCTAssertEqual(nativeExportVisibleProject(doc), doc)
    }
}
