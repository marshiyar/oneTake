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
@testable import MpvfxAudio

/// 440 Hz sine reader at amplitude 0.1, fed through AudioMixer → AudioPlayback.pump → AudioOutput.write
/// (the same path the editor's feeder thread runs).
final class ToneReader: AudioClipReader {
    let format: AudioFormat; var frame = 0
    init(_ format: AudioFormat) { self.format = format }
    func read(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * format.channels)
        for i in 0..<frames {
            let v = Float(sin(2 * Double.pi * 440 * Double(frame + i) / Double(format.sampleRate)) * 0.1)
            for ch in 0..<format.channels { out[i * format.channels + ch] = v }
        }
        frame += frames; return out
    }
}

enum ToneCheck {
    /// Plays 250 ms of tone into `output` via AudioPlayback.pump.
    static func play(into output: AudioOutput) throws -> Int {
        let f = output.format
        let mixer = AudioMixer(format: f, clips: [AudioClip(id: "tone", source: "tone", start: 0, end: 10)], time: 0) { _, _ in ToneReader(f) }
        let playback = AudioPlayback(output: output, mixer: mixer, blockFrames: 1024)
        let blocks = (f.sampleRate / 4 + 1023) / 1024
        for _ in 0..<blocks { try playback.pump() }
        return blocks * 1024
    }
    /// Asserts captured interleaved PCM is a 440 Hz, 0.1-peak sine on every channel.
    static func assertTone(_ pcm: [Float], _ f: AudioFormat, frames: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pcm.count, frames * f.channels, file: file, line: line)
        for ch in 0..<f.channels {
            let x = stride(from: ch, to: pcm.count, by: f.channels).map { Double(pcm[$0]) }
            let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(x.count))
            XCTAssertEqual(rms, 0.1 / 2.0.squareRoot(), accuracy: 1e-3, "level ch\(ch)", file: file, line: line)
            XCTAssertEqual(x.map(abs).max() ?? 0, 0.1, accuracy: 1e-4, "peak ch\(ch)", file: file, line: line)
            // Frequency: Goertzel power at 440 Hz vs. neighbours, plus rising zero-crossing rate.
            func power(_ hz: Double) -> Double {
                let w = 2 * Double.pi * hz / Double(f.sampleRate), c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
                for v in x { let s = v + c * s1 - s2; s2 = s1; s1 = s }
                return s1 * s1 + s2 * s2 - c * s1 * s2
            }
            XCTAssertGreaterThan(power(440), 1000 * power(400), file: file, line: line)
            XCTAssertGreaterThan(power(440), 1000 * power(480), file: file, line: line)
            var rising = 0; for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 { rising += 1 }
            let hz = Double(rising) * Double(f.sampleRate) / Double(x.count)
            XCTAssertEqual(hz, 440, accuracy: 5, "zero-crossing frequency ch\(ch)", file: file, line: line)
        }
    }
}

/// Always runs (no sound server needed): captures the PCM in NullAudioOutput.
final class ToneCaptureTests: XCTestCase {
    func testToneThroughPlaybackPathIntoCapturingSink() throws {
        let out = NullAudioOutput()
        try out.start()
        let frames = try ToneCheck.play(into: out)
        ToneCheck.assertTone(out.written, out.format, frames: frames)
        XCTAssertEqual(out.framesQueued, frames)
        out.advance(seconds: 0.1); XCTAssertEqual(out.framesPlayed, 4800)
        out.flush(); XCTAssertEqual(out.framesPlayed, 0); XCTAssertTrue(out.written.isEmpty)
        out.stop()
    }
}
