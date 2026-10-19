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

/// Stem decode through the media engine (`StemDecoder`, `DocumentAudioGraph.decodeStem`): inputs are WAV bytes this
/// file writes, plus the committed FLAC/MP4/MOV fixtures of `Tests/EngineFixtures/` (provenance in its README).
final class StemDecoderTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try WavFixtures.tempDir() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func key(_ path: String, from sourceIn: Double = 0, seconds: Double, rate: Double = 1) -> DocumentAudioGraph.StemKey {
        .init(path: path, sourceIn: sourceIn, duration: seconds, rate: rate)
    }

    func testStereoWavDecodesSampleExactAtTheGraphRate() throws {
        let tone = WavFixtures.sine(440, seconds: 1, amp: 0.5, sampleRate: 48_000)
        let interleaved = tone.flatMap { [$0, -0.5 * $0] }
        let path = try WavFixtures.write("st.wav", in: dir, interleaved, sampleRate: 48_000, channels: 2, encoding: .s16)
        let stem = try DocumentAudioGraph.decodeStem(key(path, seconds: 1), sampleRate: 48_000)
        XCTAssertEqual(stem.count, 2)
        XCTAssertEqual(stem[0].count, 48_000)
        XCTAssertEqual(stem[1].count, 48_000)
        XCTAssertEqual(maxDiff(stem[0], tone), 0, accuracy: 1.0 / 32768, "left = the 16-bit samples written")
        XCTAssertEqual(maxDiff(stem[1], tone.map { -0.5 * $0 }), 0, accuracy: 1.0 / 32768, "right = the 16-bit samples written")
        XCTAssertEqual(stem[0].map(abs).max()!, 0.5, accuracy: 0.001)
    }

    func testSeekStartsAtTheSourceInPointExactly() throws {
        let ramp = (0..<72_000).map { Float($0 % 4800) / 4800 - 0.5 }   // 1.5 s, mono, every frame distinct per 0.1 s
        let path = try WavFixtures.write("ramp.wav", in: dir, ramp, sampleRate: 48_000)
        let stem = try DocumentAudioGraph.decodeStem(key(path, from: 0.25, seconds: 1), sampleRate: 48_000)
        XCTAssertEqual(stem[0].count, 48_000, "1 s requested, 1.25 s available")
        XCTAssertTrue(stem[0] == Array(ramp[12_000..<60_000]), "every frame after seeking to 0.25 s")
        XCTAssertTrue(stem[1] == stem[0], "mono plays on both channels")
        let tail = try DocumentAudioGraph.decodeStem(key(path, from: 1.0, seconds: 1), sampleRate: 48_000)
        XCTAssertEqual(tail[0].count, 24_000, "the stem ends with the source")
    }

    func testOtherSourceRateIsResampledToTheGraphRate() throws {
        let tone = WavFixtures.sine(1000, seconds: 1, amp: 0.4, sampleRate: 44_100)
        let path = try WavFixtures.write("44k.wav", in: dir, tone, sampleRate: 44_100, encoding: .s16)
        let stem = try DocumentAudioGraph.decodeStem(key(path, seconds: 1), sampleRate: 48_000)
        XCTAssertEqual(Double(stem[0].count), 48_000, accuracy: 2)
        XCTAssertEqual(crossingsPerSecond(Array(stem[0][2400..<45_600]), sampleRate: 48_000), 2000, accuracy: 10, "still 1 kHz")
        XCTAssertEqual(rmsOf(stem[0][2400..<45_600]), 0.4 / 2.0.squareRoot(), accuracy: 0.01, "level kept")
    }

    func testClipRateIsPitchPreservingTempo() throws {
        let tone = WavFixtures.sine(440, seconds: 2, amp: 0.3, sampleRate: 48_000)
        let path = try WavFixtures.write("tone.wav", in: dir, tone, sampleRate: 48_000)
        let fast = try DocumentAudioGraph.decodeStem(key(path, seconds: 2, rate: 2), sampleRate: 48_000)
        XCTAssertEqual(fast[0].count, 48_000, "2 s of source at 2x lasts 1 s")
        XCTAssertEqual(crossingsPerSecond(Array(fast[0][4800..<43_200]), sampleRate: 48_000), 880, accuracy: 20, "pitch kept at 440 Hz")
        XCTAssertEqual(rmsOf(fast[0][4800..<43_200]), 0.3 / 2.0.squareRoot(), accuracy: 0.03)
        let slow = try DocumentAudioGraph.decodeStem(key(path, seconds: 6, rate: 0.5), sampleRate: 48_000)
        XCTAssertEqual(slow[0].count, 192_000, "2 s of source at 0.5x lasts 4 s")
        XCTAssertEqual(crossingsPerSecond(Array(slow[0][9600..<182_400]), sampleRate: 48_000), 880, accuracy: 20)
    }

    func testSeekWithTempoMapsSourceTime() throws {
        // 1 s silence, then a tone: from source 0.5 s at 2x, the tone starts 0.25 s into the stem.
        let pcm = [Float](repeating: 0, count: 48_000) + WavFixtures.sine(440, seconds: 1, amp: 0.5, sampleRate: 48_000)
        let path = try WavFixtures.write("late.wav", in: dir, pcm, sampleRate: 48_000)
        let stem = try DocumentAudioGraph.decodeStem(key(path, from: 0.5, seconds: 0.6, rate: 2), sampleRate: 48_000)
        XCTAssertEqual(stem[0].count, 28_800)
        let onset = try XCTUnwrap(stem[0].firstIndex { abs($0) > 0.05 })
        XCTAssertEqual(Double(onset) / 48_000, 0.25, accuracy: 0.025)
        XCTAssertEqual(rmsOf(stem[0][0..<9600]), 0, accuracy: 1e-4, "silence before the onset")
    }

    func testLongStemIsReadInBoundedChunks() throws {
        let frames = StemDecoder.chunkFrames * 3 + 1234
        let pcm = (0..<frames).map { Float($0 % 1000) / 1000 }
        let path = try WavFixtures.write("long.wav", in: dir, pcm, sampleRate: 48_000)
        let stem = try DocumentAudioGraph.decodeStem(key(path, seconds: Double(frames) / 48_000), sampleRate: 48_000)
        XCTAssertEqual(stem[0].count, frames)
        XCTAssertTrue(stem[0] == pcm, "every frame, across the chunk boundaries")
    }

    func testFlacAndPcmContainersDecode() throws {
        let cases: [(String, Double, Int)] = [
            ("flac/c5_48k_s16_stereo.flac", 0.3, 14_400),   // FLAC file
            ("flac/c0_44k_s16_stereo.flac", 0.3, 14_400),   // FLAC at 44.1 kHz, resampled (13230 frames)
            ("isobmff/mp4_flac.mp4", 0.5, 24_000),          // FLAC in MP4
            ("isobmff/mov_in24.mov", 0.5, 24_000),          // 24-bit LPCM in MOV, 8 kHz
            ("isobmff/mov_fl32.mov", 0.5, 24_000),          // float LPCM in MOV, 8 kHz
        ]
        let decoded = try cases.map { c in
            try DocumentAudioGraph.decodeStem(key(WavFixtures.mediaFixtures.appendingPathComponent(c.0).path, seconds: c.1), sampleRate: 48_000)
        }
        let wrongLength = zip(cases, decoded).filter { c, stem in abs(stem[0].count - c.2) > c.2 / 100 }.map(\.0.0)
        XCTAssertEqual(wrongLength, [], "frame count at 48 kHz within 1%")
        let silent = zip(cases, decoded).filter { _, stem in rmsOf(stem[0][...]) <= 0.01 || stem[1].count != stem[0].count }.map(\.0.0)
        XCTAssertEqual(silent, [], "every container decodes sound on both channels")
    }

    /// AAC-LC in MP4, MOV and ADTS decodes (mpvfx-media crates/aac); MP4/MOV drop the encoder delay their edit
    /// list names, ADTS has none to drop. The clip plays in the mix.
    func testAacDecodesAndTheClipPlays() throws {
        let cases: [(String, Double, Int)] = [
            ("isobmff/mp4_aac.mp4", 0.5, 24_000),       // 48 kHz mono sine, FFmpeg's encoder
            ("isobmff/mov_aac.mov", 0.5, 24_000),
            ("aac/lc_44k_stereo.mp4", 0.3, 14_400),     // 44.1 kHz stereo (13230 frames), resampled
            ("aac/lc_44k_stereo.aac", 0.325, 15_604),   // the same access units as ADTS: 14 x 1024 frames
        ]
        let decoded = try cases.map { c in
            try DocumentAudioGraph.decodeStem(key(WavFixtures.mediaFixtures.appendingPathComponent(c.0).path, seconds: c.1), sampleRate: 48_000)
        }
        let wrongLength = zip(cases, decoded).filter { c, stem in abs(stem[0].count - c.2) > c.2 / 100 }.map(\.0.0)
        XCTAssertEqual(wrongLength, [], "frame count at 48 kHz within 1%")
        let silent = zip(cases, decoded).filter { _, stem in rmsOf(stem[0][...]) <= 0.01 || stem[1].count != stem[0].count }.map(\.0.0)
        XCTAssertEqual(silent, [], "every file decodes sound on both channels")

        let path = WavFixtures.mediaFixtures.appendingPathComponent("isobmff/mp4_aac.mp4").path
        let inputs = DocumentAudioGraph.Inputs(duration: 1, tracks: [
            .init(id: "aac", stem: key(path, seconds: 0.5), start: 0, end: 0.5, volume: 1, muted: false, fxChain: nil, automation: nil, groupId: nil),
        ], groups: [])
        var issues: [String] = []
        let project = DocumentAudioGraph.project(inputs, sampleRate: 48_000, issues: &issues)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(project.tracks.count, 1, "the clip is in the mix")
        XCTAssertGreaterThan(rmsOf(AudioGraphRenderer.renderOffline(project)[...]), 0.01)
    }

    func testVideoWithoutAudioIsASilentStem() throws {
        let path = WavFixtures.mediaFixtures.appendingPathComponent("isobmff/h264_moov_end.mp4").path
        let stem = try DocumentAudioGraph.decodeStem(key(path, seconds: 1))
        XCTAssertEqual(stem.map(\.count), [0, 0])
    }

    func testTempoOutsideTheEngineRangeIsReported() throws {
        let path = try WavFixtures.write("t.wav", in: dir, WavFixtures.sine(440, seconds: 1, amp: 0.3, sampleRate: 48_000), sampleRate: 48_000)
        XCTAssertThrowsError(try DocumentAudioGraph.decodeStem(key(path, seconds: 1, rate: 8)))
    }
}

/// A document's WAV clip played by the live graph with the app's default (media engine) stem loader.
final class EngineGraphPlaybackTests: XCTestCase {
    func testDocumentClipPlaysAtItsTimelinePositionWithSeekAndVolume() throws {
        let dir = try WavFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 2 s mono: 0.25 until source 0.2 s, then 0.5 (both exact in 16-bit, so the graph's s16 stage keeps them).
        let pcm = (0..<96_000).map { $0 < 9600 ? Float(0.25) : Float(0.5) }
        _ = try WavFixtures.write("a.wav", in: dir, pcm, sampleRate: 48_000)
        let json = #"""
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":640,"height":360,"background":"#000000"},
         "assets":[{"id":"a","kind":"audio","name":"a.wav","source":"a.wav","durationFrames":60}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"audio","clips":[
           {"id":"ca","assetId":"a","startFrame":6,"durationFrames":24,"sourceInFrame":3,"muted":false,"effects":[],"parameterTracks":[],
            "staticParameters":{"audio.volume":0.5}}]}]}}
        """#
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(json))
        let inputs = DocumentAudioGraph.inputs(doc, duration: 1.2, projectDir: dir)
        XCTAssertEqual(inputs.tracks.map(\.id), ["ca"])
        let source = GraphAudioSource(project: AudioGraphProject(duration: 1.2, tracks: []))
        let updater = LiveAudioGraphUpdater(source: source)
        var reported: [String] = []
        updater.onIssues = { reported = $0 }
        updater.submit(inputs)
        updater.waitUntilIdle()
        XCTAssertEqual(reported, [])
        XCTAssertEqual(updater.builds, 1)
        source.seek(0)
        let out = source.render(frames: 57_600)
        func level(at t: Double) -> Float { out[2 * Int(t * 48_000)] }
        XCTAssertEqual(level(at: 0.1), 0, "before the clip (starts at 0.2 s)")
        XCTAssertEqual(level(at: 0.25), 0.125, "source 0.1 s + 0.05 s: 0.25 at volume 0.5")
        XCTAssertEqual(level(at: 0.5), 0.25, "past the step at source 0.2 s (timeline 0.3 s)")
        XCTAssertEqual(out[2 * 14_400 - 2], 0.125, "last frame before the step")
        XCTAssertEqual(out[2 * 14_400], 0.25, "the step lands on timeline frame 14400 exactly")
        XCTAssertEqual(level(at: 1.1), 0, "after the clip (ends at 1.0 s)")
        XCTAssertEqual(out[2 * 30_000 + 1], out[2 * 30_000], "mono on both channels")
        source.seek(0.75)
        let after = source.render(frames: 128)
        XCTAssertTrue(after == Array(out[(2 * 36_000)..<(2 * 36_000 + 256)]), "seek lands on the same samples")
    }
}
