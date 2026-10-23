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
import MpvfxAudio
import MpvfxAudioGraph

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

    func testDisabledClipStateRoundTripsAndExportSkipsItsPictureAndSoundWithoutShortening() throws {
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        let saved = try serializeNativeProjectDocument(doc)
        let reopened = try parseNativeProjectDocument(try NativeJSONValue.parse(saved))
        XCTAssertEqual(reopened.sequence.tracks[0].clips[1].hidden, true)
        let visible = nativeExportVisibleProject(reopened)
        XCTAssertFalse(visible.sequence.tracks.flatMap(\.clips).contains { $0.id == "clip:hidden" })
        XCTAssertEqual(visible.sequence.durationFrames, 120)
    }

    func testDisabledDetachedAudioStaysSilentAfterExportVisibilityFiltering() throws {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        doc.sequence.tracks[1].clips[0].audioDetachedFrom = "clip:shown"
        func samples(_ project: NativeProjectDocument) throws -> [Float] {
            let visible = nativeExportVisibleProject(project)
            let inputs = DocumentAudioGraph.inputs(visible, duration: 4, projectDir: nil, fileExists: { _ in true })
            var issues: [String] = []
            let graph = DocumentAudioGraph.project(inputs, loadStem: { stem in
                [[Float](repeating: 0.25, count: Int(stem.duration * 48_000)),
                 [Float](repeating: 0.25, count: Int(stem.duration * 48_000))]
            }, issues: &issues)
            XCTAssertEqual(issues, [])
            return AudioGraphRenderer.renderOffline(graph)
        }
        XCTAssertTrue(try samples(doc).allSatisfy { $0 == 0 }, "hidden detached-audio track stays silent")
        XCTAssertFalse(doc.sequence.tracks[0].clips[0].muted, "export filtering never changes the saved source")
        doc.sequence.tracks[1].hidden = nil
        doc.sequence.tracks[1].clips[0].hidden = true
        XCTAssertTrue(try samples(doc).allSatisfy { $0 == 0 }, "disabled detached clip stays silent")
        doc.sequence.tracks[1].clips[0].hidden = nil
        XCTAssertTrue(try samples(doc).contains { $0 > 0 }, "enabling restores the detached sound")
        XCTAssertTrue(nativeExportVisibleProject(doc).sequence.tracks[2].clips[0].muted, "intentional mute stays set")
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
