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
#if os(Windows)
import MpvfxShared   // usleep
#endif
@testable import MpvfxAudio

/// Constant-value reader: makes mix arithmetic exact.
final class ConstReader: AudioClipReader {
    let value: Float, channels: Int
    var opens: [Double]
    init(_ v: Float, channels: Int = 2, openedAt: Double) { value = v; self.channels = channels; opens = [openedAt] }
    func read(frames: Int) -> [Float] { [Float](repeating: value, count: frames * channels) }
}

final class AudioMixerTests: XCTestCase {
    let fmt = AudioFormat(sampleRate: 1000, channels: 2)

    func testMixesActiveClipsWithGainAndBoundaries() {
        var opened: [(String, Double)] = []
        let m = AudioMixer(format: fmt, clips: [
            AudioClip(id: "a", source: "a", start: 0, end: 1, gain: 0.5),
            AudioClip(id: "b", source: "b", start: 0.5, end: 2, sourceIn: 3, rate: 2),
            AudioClip(id: "m", source: "m", start: 0, end: 2, muted: true),
        ], time: 0) { clip, srcT in opened.append((clip.id, srcT)); return ConstReader(0.25, openedAt: srcT) }
        let block = m.render(frames: 1000)   // 0 … 1 s
        XCTAssertEqual(block[0], 0.125, accuracy: 1e-6, "a at half gain")
        XCTAssertEqual(block[600 * 2], 0.375, accuracy: 1e-6, "a + b overlap")
        XCTAssertEqual(m.time, 1, accuracy: 1e-9)
        XCTAssertEqual(opened.first { $0.0 == "b" }!.1, 3, accuracy: 1e-9, "b opens at sourceIn when it starts")
        let next = m.render(frames: 500)
        XCTAssertEqual(next[0], 0.25, accuracy: 1e-6, "a ended; only b")
    }

    func testSeekReopensAtRateMappedSourceTime() {
        var opened: [Double] = []
        let m = AudioMixer(format: fmt, clips: [AudioClip(id: "b", source: "b", start: 1, end: 5, sourceIn: 2, rate: 2)], time: 0) {
            _, t in opened.append(t); return ConstReader(0.1, openedAt: t)
        }
        m.seek(3); _ = m.render(frames: 10)
        XCTAssertEqual(opened, [6], "2 + (3 - 1) × 2")
    }

    func testMasterMuteAndClipping() {
        let m = AudioMixer(format: fmt, clips: [AudioClip(id: "a", source: "", start: 0, end: 1), AudioClip(id: "b", source: "", start: 0, end: 1)], time: 0) { _, t in ConstReader(0.8, openedAt: t) }
        XCTAssertEqual(m.render(frames: 4)[0], 1, "clamped to [-1, 1]")
        m.muted = true
        XCTAssertEqual(m.render(frames: 4)[0], 0)
    }
}

final class AudioClockTests: XCTestCase {
    func testAudioClockDrivesTimeAndPauseHoldsIt() throws {
        let fmt = AudioFormat(sampleRate: 1000, channels: 2)
        let out = NullAudioOutput(format: fmt); out.capacityFrames = 200; out.keepSamples = false
        let m = AudioMixer(format: fmt, clips: [], time: 0) { _, _ in nil }
        let p = AudioPlayback(output: out, mixer: m, blockFrames: 50)
        try p.play(from: 2)
        XCTAssertEqual(p.currentTime, 2, accuracy: 1e-9, "nothing played yet")
        let deadline = Date().addingTimeInterval(2)
        while out.framesQueued < 200 && Date() < deadline { usleep(1000) }
        out.advance(seconds: 0.1)
        XCTAssertEqual(p.currentTime, 2.1, accuracy: 1e-9, "clock = start + device frames played")
        p.stop()
        XCTAssertEqual(p.currentTime, 2.1, accuracy: 1e-9, "pause keeps the listener position")
        XCTAssertFalse(p.isPlaying)
    }
}
