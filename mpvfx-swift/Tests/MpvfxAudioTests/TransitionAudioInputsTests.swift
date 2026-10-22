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

/// A cut transition in the document becomes the equal-power crossfade of the two clips' sound in the graph inputs
/// that live playback and the export mix both build (issue #265, A6); detached audio follows its video.
final class TransitionAudioInputsTests: XCTestCase {
    /// Video "A" [0, 30) and "B" [30, 60) at 10 fps from source frame 15, a centred dissolve of `length` frames;
    /// "B" also has its sound detached to clip "Bsnd" on an audio track.
    func document(kind: String = "dissolve", length: Int = 10) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"a","source":"/m/a.mov","durationFrames":60},
                   {"id":"b","kind":"video","name":"b","source":"/m/b.mov","durationFrames":60},
                   {"id":"bs","kind":"audio","name":"b audio","source":"/m/b.mov","durationFrames":60}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":15,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"B","assetId":"b","startFrame":30,"durationFrames":30,"sourceInFrame":15,"muted":true,"effects":[],"parameterTracks":[]}],
           "transitions":[{"v":1,"id":"t","fromClipId":"A","toClipId":"B","kind":"\#(kind)","durationFrames":\#(length),"alignment":"centre"}]},
          {"id":"a1","kind":"audio","lane":{"authoredTrack":0,"displayTrack":1},"clips":[
           {"id":"Bsnd","assetId":"bs","audioDetachedFrom":"B","startFrame":30,"durationFrames":30,"sourceInFrame":15,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func track(_ inputs: DocumentAudioGraph.Inputs, _ id: String) throws -> DocumentAudioGraph.Inputs.Track {
        try XCTUnwrap(inputs.tracks.first { $0.id == id })
    }

    func testADissolveWidensBothClipsOverTheirHandlesAndCrossfadesThem() throws {
        let inputs = DocumentAudioGraph.inputs(try document(), duration: 6, projectDir: nil, fileExists: { _ in true })
        let a = try track(inputs, "A"), b = try track(inputs, "Bsnd")
        XCTAssertEqual(a.start, 0); XCTAssertEqual(a.end, 3.5, accuracy: 1e-12, "plays 5 frames past its out point")
        XCTAssertEqual(a.stem.duration, 3.5, accuracy: 1e-12)
        XCTAssertEqual(a.transitionGain?.fadeOut, AudioGainRamp(start: 2.5, end: 3.5, fadeIn: false))
        XCTAssertEqual(b.start, 2.5, accuracy: 1e-12, "the detached sound follows its video: 5 frames before the in point")
        XCTAssertEqual(b.stem.sourceIn, 1.0, accuracy: 1e-12)
        XCTAssertEqual(b.transitionGain?.fadeIn, AudioGainRamp(start: 2.5, end: 3.5, fadeIn: true))
    }

    func testADipFadesOutToTheCutAndInAfterItWithoutHandles() throws {
        let inputs = DocumentAudioGraph.inputs(try document(kind: "dip"), duration: 6, projectDir: nil, fileExists: { _ in true })
        let a = try track(inputs, "A"), b = try track(inputs, "Bsnd")
        XCTAssertEqual(a.end, 3, accuracy: 1e-12); XCTAssertEqual(b.start, 3, accuracy: 1e-12)
        XCTAssertEqual(a.transitionGain?.fadeOut, AudioGainRamp(start: 2.5, end: 3, fadeIn: false))
        XCTAssertEqual(b.transitionGain?.fadeIn, AudioGainRamp(start: 3, end: 3.5, fadeIn: true))
    }

    func testTheGraphProjectCarriesTheFadesToTheRenderer() throws {
        let inputs = DocumentAudioGraph.inputs(try document(), duration: 6, projectDir: nil, fileExists: { _ in true })
        var issues: [String] = []
        let project = DocumentAudioGraph.project(inputs, loadStem: { key in
            [[Float](repeating: 0.5, count: Int(key.duration * 48_000)), [Float](repeating: 0.5, count: Int(key.duration * 48_000))]
        }, issues: &issues)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(project.tracks.first { $0.id == "A" }?.transitionGain, try track(inputs, "A").transitionGain)
    }
}
