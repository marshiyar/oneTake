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
import MpvfxShared
import MpvfxAudioGraph
@testable import MpvfxAudio

final class DisabledClipAudioTests: XCTestCase {
    func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"audio","name":"a.wav","source":"a.wav","durationFrames":60}],
         "sequence":{"id":"s","name":"Main","durationFrames":60,"tracks":[
          {"id":"t","kind":"audio","clips":[{"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":60,
           "sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func inputs(_ doc: NativeProjectDocument) -> DocumentAudioGraph.Inputs {
        DocumentAudioGraph.inputs(doc, duration: 2, projectDir: URL(fileURLWithPath: "/p"), fileExists: { _ in true })
    }

    func testDisabledClipsAreNotDecodedOrHeardInTheSharedPreviewExportGraph() throws {
        var doc = try document()
        XCTAssertEqual(inputs(doc).tracks.map(\.id), ["clip:a"])
        doc.sequence.tracks[0].clips[0].hidden = true
        let silent = inputs(doc)
        XCTAssertEqual(silent.duration, 2, "disabling never shortens the project")
        XCTAssertEqual(silent.tracks, [])
        var decodes = 0, issues: [String] = []
        let graph = DocumentAudioGraph.project(silent, loadStem: { _ in
            decodes += 1
            return [[Float](repeating: 1, count: 96_000), [Float](repeating: 1, count: 96_000)]
        }, issues: &issues)
        XCTAssertEqual(decodes, 0)
        XCTAssertTrue(AudioGraphRenderer.renderOffline(graph).allSatisfy { $0 == 0 })
        XCTAssertEqual(issues, [])
        doc.sequence.tracks[0].clips[0].hidden = nil
        XCTAssertEqual(inputs(doc).tracks.map(\.id), ["clip:a"], "enabling restores its stem")
    }

    func testDisablingDetachedAudioNeverRestoresTheOriginalVideoSound() throws {
        var doc = try document()
        var videoAsset = doc.assets[0]
        videoAsset.id = "asset:v"; videoAsset.kind = .video
        doc.assets.append(videoAsset)
        var video = doc.sequence.tracks[0].clips[0]
        video.id = "clip:v"; video.assetId = videoAsset.id
        var videoTrack = doc.sequence.tracks[0]
        videoTrack.id = "video"; videoTrack.kind = .video; videoTrack.clips = [video]
        doc.sequence.tracks.append(videoTrack)
        doc.sequence.tracks[0].clips[0].audioDetachedFrom = video.id
        XCTAssertEqual(inputs(doc).tracks.map(\.id), ["clip:a"])
        doc.sequence.tracks[0].clips[0].hidden = true
        XCTAssertEqual(inputs(doc).tracks, [], "disabled detached audio stays silent")
        doc.sequence.tracks[0].clips[0].hidden = nil
        doc.sequence.tracks[0].hidden = true
        XCTAssertEqual(inputs(doc).tracks, [], "a hidden detached-audio track stays silent")
        doc.sequence.tracks[0].hidden = nil
        XCTAssertEqual(inputs(doc).tracks.map(\.id), ["clip:a"])
        doc.sequence.tracks[0].clips = []
        XCTAssertEqual(inputs(doc).tracks.map(\.id), ["clip:v"], "only reattaching restores the source sound")
    }

    func testHiddenAudioTracksAreSkippedBeforeDecodingButMuteStateIsPreserved() throws {
        var doc = try document()
        doc.sequence.tracks[0].clips[0].muted = true
        XCTAssertEqual(inputs(doc).tracks.first?.muted, true)
        doc.sequence.tracks[0].hidden = true
        XCTAssertEqual(inputs(doc).tracks, [])
    }
}
