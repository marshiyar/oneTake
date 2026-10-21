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
// Narration from text plays from its WAV (#349 A4): the `narration` record never reaches the audio graph, so a
// project whose voice is not installed on this machine plays and exports exactly as on the machine that spoke it.
import XCTest
import MpvfxShared
import MpvfxAudioGraph
@testable import MpvfxAudio

final class NarrationClipPlaybackTests: XCTestCase {
    static func json(narration: String) -> String {
        #"""
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":640,"height":360,"background":"#000000"},
         "assets":[{"id":"a","kind":"audio","name":"Narration.wav","source":"Narration/Narration.wav","durationFrames":30}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"audio","clips":[
          {"id":"c","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]
        """# + narration + "}]}]}}"
    }

    func testA4ANarrationClipWhoseVoiceIsNotInstalledPlaysAndExportsFromItsWav() throws {
        let dir = try WavFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Narration"), withIntermediateDirectories: true)
        let tone = WavFixtures.sine(440, seconds: 1, amp: 0.25, sampleRate: 48_000)
        _ = try WavFixtures.write("Narration/Narration.wav", in: dir, tone, sampleRate: 48_000, encoding: .s16)
        let spoken = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json(
            narration: #","narration":{"v":1,"text":"Hello","voiceId":"voice.on.another.machine","voiceName":"Studio Voice"}"#)))
        let unread = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json(narration: #","narration":{"v":9,"anything":true}"#)))
        let plain = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json(narration: "")))
        // The graph inputs (what live playback and export both build from) ignore the record entirely.
        let inputs = DocumentAudioGraph.inputs(spoken, duration: 1, projectDir: dir)
        XCTAssertEqual(inputs, DocumentAudioGraph.inputs(plain, duration: 1, projectDir: dir))
        XCTAssertEqual(inputs, DocumentAudioGraph.inputs(unread, duration: 1, projectDir: dir))
        XCTAssertEqual(inputs.tracks.map(\.stem.path), [dir.appendingPathComponent("Narration/Narration.wav").path])
        // The stem decodes from the WAV with the media engine: the sound is the file's, sample for sample within 16 bits.
        let stem = try DocumentAudioGraph.decodeStem(try XCTUnwrap(inputs.tracks.first?.stem))
        let plane = try XCTUnwrap(stem.first)
        XCTAssertEqual(plane.count, 48_000)
        XCTAssertEqual(crossingsPerSecond(plane, sampleRate: 48_000), 880, accuracy: 4)
        XCTAssertEqual(rmsOf(plane[...]), 0.25 / 2.0.squareRoot(), accuracy: 0.002)
    }
}
