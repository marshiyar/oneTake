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
@testable import MpvfxAudioGraph

/// The equal-power crossfade a cut transition puts on two clips' sound (issue #265, A6), through the one graph live
/// playback (consecutive blocks from one renderer) and the export mix (an offline render) share.
final class TransitionCrossfadeTests: XCTestCase {
    static let sr = 48_000.0
    static let amplitude: Float = 0.25

    /// A 1 kHz tone, `phase` 0 (sine) or π/2 (cosine): the two are uncorrelated over whole cycles, the case equal
    /// power keeps level for (two in-phase copies of one signal would rise 3 dB at the middle instead).
    static func tone(seconds: Double, phase: Double) -> [[Float]] {
        let n = Int(seconds * sr)
        let s = (0..<n).map { (i: Int) -> Float in amplitude * Float(sin(2 * .pi * 1000 * Double(i) / sr + phase)) }
        return [s, s]
    }

    /// Clip one [0, 2) s fading out over [0.5, 1.5); clip two [0.5, 2.5) s fading in over the same second.
    static func project() -> AudioGraphProject {
        var out = AudioGraphTrack(id: "out", stem: tone(seconds: 2, phase: 0), start: 0, end: 2)
        out.transitionGain = AudioTransitionGain(fadeOut: AudioGainRamp(start: 0.5, end: 1.5, fadeIn: false))
        var into = AudioGraphTrack(id: "in", stem: tone(seconds: 2, phase: .pi / 2), start: 0.5, end: 2.5)
        into.transitionGain = AudioTransitionGain(fadeIn: AudioGainRamp(start: 0.5, end: 1.5, fadeIn: true))
        return AudioGraphProject(duration: 2.5, sampleRate: sr, tracks: [out, into])
    }

    /// RMS in dB of the left channel over [from, from + count) interleaved stereo frames.
    static func rmsDB(_ mix: [Float], from: Int, count: Int) -> Double {
        let sum = (from..<(from + count)).reduce(0.0) { acc, i in let v = Double(mix[2 * i]); return acc + v * v }
        return 10 * log10(sum / Double(count))
    }

    func assertEqualPower(_ mix: [Float], _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = 480   // 10 ms: ten whole cycles of the tone
        let single = Self.rmsDB(mix, from: Int(0.2 * Self.sr), count: window)
        XCTAssertEqual(single, 20 * log10(Double(Self.amplitude) / 2.0.squareRoot()), accuracy: 0.05, "\(path): one tone alone", file: file, line: line)
        var worst = 0.0
        for start in stride(from: Int(0.5 * Self.sr), to: Int(1.5 * Self.sr) - window, by: window) {
            worst = max(worst, abs(Self.rmsDB(mix, from: start, count: window) - single))
        }
        XCTAssertLessThanOrEqual(worst, 0.5, "\(path): summed level across the crossfade stays within ±0.5 dB of one tone", file: file, line: line)
        XCTAssertEqual(Self.rmsDB(mix, from: Int(2.0 * Self.sr), count: window), single, accuracy: 0.05, "\(path): the second tone alone",
                       file: file, line: line)
    }

    func testA6TwoTonesCrossfadingOverOneSecondKeepTheirLevelLiveAndInTheExportMix() {
        let live = AudioGraphRenderer(Self.project())
        var played: [Float] = []
        while played.count < Int(2.5 * Self.sr) * 2 { played += live.render(512) }
        assertEqualPower(played, "live graph")
        let exported = AudioGraphRenderer.render(Self.project(), from: 0, frames: Int(2.5 * Self.sr))
        assertEqualPower(exported, "export mix")
        XCTAssertEqual(Array(played.prefix(exported.count)), exported, "live playback and export are the same samples")
    }

    func testTheGainRampsAreEqualPowerAndHoldOutsideTheirRange() {
        let g = AudioTransitionGain(fadeIn: AudioGainRamp(start: 1, end: 2, fadeIn: true), fadeOut: AudioGainRamp(start: 3, end: 4, fadeIn: false))
        XCTAssertEqual(g.gain(at: 0.5), 0); XCTAssertEqual(g.gain(at: 1.5), sin(.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(g.gain(at: 2.5), 1); XCTAssertEqual(g.gain(at: 3.5), cos(.pi / 4), accuracy: 1e-12); XCTAssertEqual(g.gain(at: 4.5), 0, accuracy: 1e-12)
    }
}
