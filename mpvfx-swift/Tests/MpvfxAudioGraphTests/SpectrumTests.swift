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

final class SpectrumTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let sixthOctave = pow(2.0, 1.0 / 6.0)

    private func pushSine(_ analyzer: SpectrumAnalyzer, frequency: Double, amplitude: Float, totalFrames: Int, leftGain: Float = 1, rightGain: Float = 1) {
        var phase = 0.0
        var pushed = 0
        while pushed < totalFrames {
            let count = min(128, totalFrames - pushed)
            var left = [Float](repeating: 0, count: count)
            var right = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let s = Float(sin(phase)) * amplitude
                left[i] = s * leftGain
                right[i] = s * rightGain
                phase += 2.0 * .pi * frequency / sampleRate
            }
            _ = analyzer.push([left, right])
            pushed += count
        }
    }

    private func loudestBand(_ analyzer: SpectrumAnalyzer) -> (index: Int, center: Double, level: Float) {
        let bands = analyzer.bands
        let index = bands.indices.max(by: { bands[$0] < bands[$1] })!
        return (index, SpectrumAnalyzer.bandCenter(index), bands[index])
    }

    func testSineOfOneKilohertzPeaksWithinASixthOfAnOctave() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        pushSine(analyzer, frequency: 1_000, amplitude: 0.5, totalFrames: 96_000)
        XCTAssertEqual(analyzer.bands.count, SpectrumAnalyzer.bandCount)
        let peak = loudestBand(analyzer)
        XCTAssertGreaterThan(peak.center, 1_000 / sixthOctave)
        XCTAssertLessThan(peak.center, 1_000 * sixthOctave)
        XCTAssertEqual(Double(peak.level), -6.0, accuracy: 3.0)
    }

    func testPeakFollowsTheFrequencyAcrossTheRange() {
        for frequency in [100.0, 440.0, 5_000.0, 12_000.0] {
            let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
            pushSine(analyzer, frequency: frequency, amplitude: 0.5, totalFrames: 96_000)
            let peak = loudestBand(analyzer)
            XCTAssertGreaterThan(peak.center, frequency / sixthOctave, "peak too low at \(frequency) Hz")
            XCTAssertLessThan(peak.center, frequency * sixthOctave, "peak too high at \(frequency) Hz")
        }
    }

    func testSilenceReadsTheFloor() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        XCTAssertEqual(SpectrumAnalyzer.fftSize, 4096)
        XCTAssertEqual(SpectrumAnalyzer.bandCount, 60)
        let silence = [Float](repeating: 0, count: 4096)
        XCTAssertTrue(analyzer.push([silence]))
        XCTAssertEqual(analyzer.bands.count, 60)
        for band in analyzer.bands {
            XCTAssertEqual(band, -90, accuracy: 0.001)
        }
    }

    func testBandsCoverTwentyHertzToTwentyKilohertz() {
        let first = SpectrumAnalyzer.bandCenter(0)
        XCTAssertGreaterThanOrEqual(first, 20)
        XCTAssertLessThanOrEqual(first, 23)
        let last = SpectrumAnalyzer.bandCenter(59)
        XCTAssertGreaterThanOrEqual(last, 17_000)
        XCTAssertLessThanOrEqual(last, 20_200)
        for i in 1..<60 {
            XCTAssertGreaterThan(SpectrumAnalyzer.bandCenter(i), SpectrumAnalyzer.bandCenter(i - 1))
        }
    }

    func testPushReportsAFrameOnlyEveryHop() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        var trueCount = 0
        var pushed = 0
        let total = 4096 + 2048 * 3
        var phase: Float = 0
        while pushed < total {
            var frame = [Float](repeating: 0, count: 128)
            for i in 0..<128 {
                frame[i] = sin(phase)
                phase += 2 * .pi * 440 / 48_000
            }
            pushed += 128
            if analyzer.push([frame]) { trueCount += 1 }
        }
        XCTAssertEqual(pushed, total)
        XCTAssertEqual(trueCount, 4)
    }

    func testAllBandsStayInRange() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        var state: UInt64 = 0x12345678
        func nextSample() -> Float {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: (state >> 33))
            return Float(bits) / Float(UInt32.max) * 2 - 1
        }
        let blocks = (4096 + 2048 * 2) / 128
        for _ in 0..<blocks {
            var left = [Float](repeating: 0, count: 128)
            var right = [Float](repeating: 0, count: 128)
            for i in 0..<128 {
                left[i] = nextSample()
                right[i] = nextSample()
            }
            _ = analyzer.push([left, right])
        }
        XCTAssertEqual(analyzer.bands.count, 60)
        for band in analyzer.bands {
            XCTAssertGreaterThanOrEqual(band, -90)
            XCTAssertLessThanOrEqual(band, 0)
        }
    }

    func testMonoSumsChannels() {
        let stereo = SpectrumAnalyzer(sampleRate: sampleRate)
        pushSine(stereo, frequency: 440, amplitude: 0.5, totalFrames: 4096 + 2048 * 2, leftGain: 1, rightGain: 1)
        let mono = SpectrumAnalyzer(sampleRate: sampleRate)
        pushSine(mono, frequency: 440, amplitude: 0.5, totalFrames: 4096 + 2048 * 2, leftGain: 1, rightGain: 0)
        let stereoPeak = loudestBand(stereo).level
        let monoPeak = loudestBand(mono).level
        XCTAssertEqual(Double(stereoPeak - monoPeak), 6.0, accuracy: 1.5)
    }
}
