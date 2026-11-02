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
@testable import MpvfxAudioGraph

/// Fixed-seed generator so the noise in these tests is the same on every run.
private struct SeededNoise {
    var state: UInt64
    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9007199254740992.0
    }
}

final class BeatAnalysisTests: XCTestCase {
    private let sampleRate = 48_000.0
    /// 120 BPM at 48 kHz.
    private let clickGap = 24_000

    /// A 25 ms burst: a decaying mix of 1 kHz and 3.1 kHz, starting at its first sample.
    private static let burst: [Float] = (0..<1_200).map { (j: Int) -> Float in
        let t = Double(j) / 48_000
        let body = sin(2 * Double.pi * 1_000 * t) + 0.5 * sin(2 * Double.pi * 3_100 * t)
        return Float(0.6 * exp(-t / 0.004) * body)
    }

    /// A kick: a sine sweeping from 120 Hz down to 50 Hz, decaying, 100 ms long.
    private static let kick: [Float] = {
        let rate = 48_000.0
        let count = Int(0.1 * rate)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            phase += 2 * Double.pi * (50 + 70 * exp(-t / 0.03)) / rate
            let fadeOut = min(1, (0.1 - t) / 0.005)
            out[i] = Float(0.9 * exp(-t / 0.035) * sin(phase) * fadeOut)
        }
        return out
    }()

    /// Bursts starting at the given sample positions in a silent signal of `length` samples.
    private func clicks(at positions: [Int], length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for start in positions {
            for (j, value) in Self.burst.enumerated() where start + j < length { out[start + j] += value }
        }
        return out
    }

    /// Clicks at 120 BPM: `count` of them from sample `first`, then `tail` samples after the last one.
    private func clickTrack(first: Int = 0, count: Int, tail: Int = 24_000) -> (samples: [Float], times: [Double]) {
        let positions = (0..<count).map { first + $0 * clickGap }
        let samples = clicks(at: positions, length: positions[count - 1] + tail)
        return (samples, positions.map { Double($0) / sampleRate })
    }

    /// Kicks at 100 BPM from 0.2 s, as many as fit in `seconds`, with optional white noise `noiseDb` below the kick RMS.
    private func kickTrack(seconds: Double, noiseDb: Double?) -> (samples: [Float], times: [Double]) {
        let length = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: length)
        var times: [Double] = []
        var i = 0
        while true {
            let start = Int(((0.2 + 0.6 * Double(i)) * sampleRate).rounded())
            if start + Self.kick.count > length { break }
            for (j, value) in Self.kick.enumerated() { out[start + j] += value }
            times.append(Double(start) / sampleRate)
            i += 1
        }
        if let noiseDb {
            var energy = 0.0
            for value in Self.kick { energy += Double(value) * Double(value) }
            let kickRMS = (energy / Double(Self.kick.count)).squareRoot()
            // Uniform noise in [-1, 1) has an RMS of 1/sqrt(3).
            let amplitude = kickRMS * pow(10, noiseDb / 20) * 1.7320508075688772
            var noise = SeededNoise(state: 12_345)
            for j in 0..<length { out[j] += Float((noise.next() * 2 - 1) * amplitude) }
        }
        return (out, times)
    }

    /// How many of `truth` have a beat within `tolerance` seconds.
    private func matched(_ beats: [BeatAnalysis.Beat], _ truth: [Double], tolerance: Double) -> Int {
        truth.filter { t in beats.contains { abs($0.time - t) <= tolerance } }.count
    }

    private func worstError(_ beats: [BeatAnalysis.Beat], _ truth: [Double]) -> Double {
        truth.map { t in beats.map { abs($0.time - t) }.min() ?? .infinity }.max() ?? 0
    }

    // MARK: A1, a click track

    private func assertClicksFound(first: Int, count: Int, tail: Int, _ label: String) {
        let track = clickTrack(first: first, count: count, tail: tail)
        guard let beats = BeatAnalysis.analyse(track.samples, sampleRate: sampleRate) else { return XCTFail("\(label): cancelled") }
        XCTAssertEqual(beats.count, track.times.count, "\(label): one mark per click and no extra marks")
        XCTAssertEqual(matched(beats, track.times, tolerance: 0.010), track.times.count, "\(label): every click within 10 ms")
        XCTAssertLessThanOrEqual(worstError(beats, track.times), 0.010, "\(label)")
        XCTAssertEqual(beats.map(\.time), beats.map(\.time).sorted(), "\(label): sorted by time")
        for beat in beats { XCTAssertTrue((0...1).contains(beat.strength), "\(label): strength \(beat.strength)") }
    }

    func testClickTrackFirstClickAtZeroAndRoomAfterTheLast() {
        assertClicksFound(first: 0, count: 24, tail: 24_000, "click at 0 s")
    }

    func testClickTrackOffGridWithTheLastClickJustBeforeTheEnd() {
        // The last click starts 40 ms before the end of the input.
        assertClicksFound(first: 14_400, count: 23, tail: 1_920, "click 40 ms before the end")
    }

    func testBeatTimesAreFinerThanOneHop() {
        let track = clickTrack(first: 7_001, count: 12)
        guard let beats = BeatAnalysis.analyse(track.samples, sampleRate: sampleRate) else { return XCTFail("cancelled") }
        XCTAssertEqual(beats.count, 12)
        // A hop is 10.7 ms; the attack search should do much better than half of that.
        XCTAssertLessThan(worstError(beats, track.times), 0.003)
    }

    // MARK: A2, a kick drum in noise

    func testKickAt100BpmWithNoiseTwentyDbDown() {
        let track = kickTrack(seconds: 20, noiseDb: -20)
        XCTAssertGreaterThanOrEqual(track.times.count, 30)
        guard let beats = BeatAnalysis.analyse(track.samples, sampleRate: sampleRate) else { return XCTFail("cancelled") }
        let found = matched(beats, track.times, tolerance: 0.020)
        let needed = Int((0.95 * Double(track.times.count)).rounded(.up))
        XCTAssertGreaterThanOrEqual(found, needed, "found \(found) of \(track.times.count) kicks within 20 ms")
        XCTAssertLessThanOrEqual(beats.count, track.times.count + 3, "not many extra marks")
    }

    func testTempoOfTheClickTrackAndTheKickTrack() {
        let click = clickTrack(count: 24).samples
        let clickEnvelope = BeatAnalysis.onsetStrength(click, sampleRate: sampleRate)
        let hopSeconds = Double(BeatAnalysis.hop) / sampleRate
        let clickTempo = BeatAnalysis.estimateTempo(onsetEnvelope: clickEnvelope, hopSeconds: hopSeconds)
        XCTAssertEqual(clickTempo ?? 0, 120, accuracy: 2)

        let kick = kickTrack(seconds: 20, noiseDb: -20).samples
        let kickEnvelope = BeatAnalysis.onsetStrength(kick, sampleRate: sampleRate)
        let kickTempo = BeatAnalysis.estimateTempo(onsetEnvelope: kickEnvelope, hopSeconds: hopSeconds)
        XCTAssertEqual(kickTempo ?? 0, 100, accuracy: 2)
    }

    // MARK: A3, speed and cancellation

    func testFiveMinutesOfStereoIsAnalysedQuickly() {
        let positions = (0..<600).map { $0 * clickGap }
        let left = clicks(at: positions, length: 300 * 48_000)
        let right = left.map { $0 * 0.5 }
        let started = Date()
        let mono = BeatAnalysis.monoMix([left, right])
        let beats = BeatAnalysis.analyse(mono, sampleRate: sampleRate)
        let elapsed = Date().timeIntervalSince(started)
        print("BeatAnalysis: 5 minutes of 48 kHz stereo analysed in \(String(format: "%.2f", elapsed)) s")
        XCTAssertNotNil(beats)
        XCTAssertLessThan(elapsed, 30, "generous bound for a debug build")
        // 120 BPM for 300 s is 600 beats.
        XCTAssertEqual(Double(beats?.count ?? 0), 600, accuracy: 6)
    }

    func testCancellationStopsWithinAFewPolls() {
        let signal = clickTrack(count: 40).samples
        var total = 0
        let full = BeatAnalysis.analyse(signal, sampleRate: sampleRate, isCancelled: { total += 1; return false })
        XCTAssertNotNil(full)
        XCTAssertGreaterThan(total, 20, "polled throughout the analysis")

        // Cancel early, in the onset stage, in the middle, and at the very last poll.
        for limit in [1, total / 4, total / 2, total] {
            var polls = 0
            let started = Date()
            let result = BeatAnalysis.analyse(signal, sampleRate: sampleRate, isCancelled: { polls += 1; return polls >= limit })
            XCTAssertNil(result, "cancelled at poll \(limit)")
            XCTAssertLessThanOrEqual(polls, limit + 2, "stopped soon after poll \(limit)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        }
    }

    func testCancelledFromTheStartReturnsNilWithoutWork() {
        var polls = 0
        let result = BeatAnalysis.analyse(clickTrack(count: 8).samples, sampleRate: sampleRate, isCancelled: { polls += 1; return true })
        XCTAssertNil(result)
        XCTAssertEqual(polls, 1)
    }

    // MARK: Inputs without beats

    func testSilenceEmptyShortAndBadRateGiveNoBeats() {
        XCTAssertEqual(BeatAnalysis.analyse([Float](repeating: 0, count: 5 * 48_000), sampleRate: sampleRate), [])
        XCTAssertEqual(BeatAnalysis.analyse([], sampleRate: sampleRate), [])
        XCTAssertEqual(BeatAnalysis.analyse([Float](repeating: 0.5, count: 500), sampleRate: sampleRate), [])
        let signal = clickTrack(count: 8).samples
        XCTAssertEqual(BeatAnalysis.analyse(signal, sampleRate: 0), [])
        XCTAssertEqual(BeatAnalysis.analyse(signal, sampleRate: -48_000), [])
        XCTAssertEqual(BeatAnalysis.analyse(signal, sampleRate: .nan), [])
    }

    func testSamplesThatAreNotFiniteAreIgnored() {
        var signal = clickTrack(count: 12).samples
        // Both sit in the silence between clicks, so ignoring them must change nothing.
        signal[12_000] = .nan
        signal[36_000] = .infinity
        let beats = BeatAnalysis.analyse(signal, sampleRate: sampleRate)
        XCTAssertEqual(beats?.count, 12)
    }

    // MARK: Options

    func testEveryKeepsEverySecondAndFourthBeat() {
        let signal = clickTrack(count: 24).samples
        guard let all = BeatAnalysis.analyse(signal, sampleRate: sampleRate),
              let two = BeatAnalysis.analyse(signal, sampleRate: sampleRate, options: .init(every: 2)),
              let four = BeatAnalysis.analyse(signal, sampleRate: sampleRate, options: .init(every: 4))
        else { return XCTFail("cancelled") }
        XCTAssertEqual(all.count, 24)
        XCTAssertEqual(two, stride(from: 0, to: all.count, by: 2).map { all[$0] })
        XCTAssertEqual(four, stride(from: 0, to: all.count, by: 4).map { all[$0] })
        XCTAssertEqual(two.count, 12)
        XCTAssertEqual(four.count, 6)
    }

    func testOtherEveryValuesCountAsOne() {
        XCTAssertEqual(BeatAnalysis.everyChoices, [1, 2, 4])
        for value in [0, -2, 3, 8, 100] { XCTAssertEqual(BeatAnalysis.validEvery(value), 1) }
        for value in BeatAnalysis.everyChoices { XCTAssertEqual(BeatAnalysis.validEvery(value), value) }
        let signal = clickTrack(count: 12).samples
        let one = BeatAnalysis.analyse(signal, sampleRate: sampleRate)
        XCTAssertNotNil(one)
        XCTAssertEqual(BeatAnalysis.analyse(signal, sampleRate: sampleRate, options: .init(every: 3)), one)
        XCTAssertEqual(BeatAnalysis.analyse(signal, sampleRate: sampleRate, options: .init(every: 0)), one)
    }

    func testSensitivityIsClampedAndNeverFindsFewerBeatsOnAClickTrack() {
        // Only checked on a clean click track: a lower threshold keeps every onset there. On real music a different set of
        // onsets can change which beats the tracker picks, so this is not promised in general.
        let signal = clickTrack(count: 24).samples
        let counts = [0.1, 0.5, 0.9].map {
            BeatAnalysis.analyse(signal, sampleRate: sampleRate, options: .init(sensitivity: $0))?.count ?? -1
        }
        XCTAssertLessThanOrEqual(counts[0], counts[1])
        XCTAssertLessThanOrEqual(counts[1], counts[2])
        XCTAssertEqual(counts[1], 24)

        XCTAssertEqual(BeatAnalysis.clampedSensitivity(-3), 0)
        XCTAssertEqual(BeatAnalysis.clampedSensitivity(7), 1)
        XCTAssertEqual(BeatAnalysis.clampedSensitivity(.nan), 0.5)
        XCTAssertEqual(BeatAnalysis.Options(), BeatAnalysis.Options(sensitivity: 0.5, every: 1))
    }

    // MARK: Progress

    func testProgressNeverGoesBackAndEndsAtOne() {
        var seen: [Double] = []
        let beats = BeatAnalysis.analyse(clickTrack(count: 24).samples, sampleRate: sampleRate, progress: { seen.append($0) })
        XCTAssertEqual(beats?.count, 24)
        XCTAssertGreaterThan(seen.count, 4)
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertTrue(seen.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(seen.last, 1.0)
    }

    // MARK: Mono mix

    func testMonoMixAveragesChannelsAndToleratesDifferentLengths() {
        XCTAssertEqual(BeatAnalysis.monoMix([]), [])
        XCTAssertEqual(BeatAnalysis.monoMix([[]]), [])
        XCTAssertEqual(BeatAnalysis.monoMix([[1, 2, 3]]), [1, 2, 3])
        XCTAssertEqual(BeatAnalysis.monoMix([[1, 3], [3, 5]]), [2, 4])
        // A short channel counts as silent after its end.
        XCTAssertEqual(BeatAnalysis.monoMix([[1, 3], [3, 5, 7]]), [2, 4, 3.5])
        XCTAssertEqual(BeatAnalysis.monoMix([[4, 4], []]), [2, 2])
    }

    // MARK: Stages

    func testOnsetStrengthHasOneValuePerHopAndPeaksAtTheClicks() {
        let track = clickTrack(first: 14_400, count: 12)
        let envelope = BeatAnalysis.onsetStrength(track.samples, sampleRate: sampleRate)
        XCTAssertEqual(envelope.count, (track.samples.count + BeatAnalysis.hop - 1) / BeatAnalysis.hop + 1)
        XCTAssertTrue(envelope.allSatisfy { $0 >= 0 && $0.isFinite })
        let strongest = envelope.max() ?? 0
        XCTAssertGreaterThan(strongest, 0)
        // A click between two frame centres reaches each through the window's slope, so its flux is well under the best click's.
        let strong = envelope.indices.filter { envelope[$0] > 0.2 * strongest }
        let positions = (0..<12).map { 14_400 + $0 * clickGap }
        // Every strong frame is centred within one frame of a click, and every click has a strong frame.
        for k in strong {
            XCTAssertTrue(positions.contains { abs(k * BeatAnalysis.hop - $0) < BeatAnalysis.frameSize }, "frame \(k)")
        }
        for p in positions {
            XCTAssertTrue(strong.contains { abs($0 * BeatAnalysis.hop - p) < BeatAnalysis.frameSize }, "click at \(p)")
        }
        // Silence far from any click is exactly zero.
        XCTAssertEqual(envelope[10], 0)
        XCTAssertEqual(BeatAnalysis.onsetStrength([Float](repeating: 0, count: 10_000), sampleRate: sampleRate).max(), 0)
        XCTAssertEqual(BeatAnalysis.onsetStrength([], sampleRate: sampleRate), [])
    }

    func testTempoOfPulseTrainsAndOfFlatInput() {
        let hopSeconds = Double(BeatAnalysis.hop) / sampleRate
        func pulses(every period: Int, count: Int) -> [Double] {
            (0..<count).map { $0 % period == 5 ? 1.0 : 0.0 }
        }
        // 47 frames is 119.7 BPM, 70 frames is 80.4 BPM.
        XCTAssertEqual(BeatAnalysis.estimateTempo(onsetEnvelope: pulses(every: 47, count: 700), hopSeconds: hopSeconds) ?? 0, 119.7, accuracy: 2)
        XCTAssertEqual(BeatAnalysis.estimateTempo(onsetEnvelope: pulses(every: 70, count: 700), hopSeconds: hopSeconds) ?? 0, 80.4, accuracy: 2)
        XCTAssertNil(BeatAnalysis.estimateTempo(onsetEnvelope: [Double](repeating: 0, count: 700), hopSeconds: hopSeconds))
        XCTAssertNil(BeatAnalysis.estimateTempo(onsetEnvelope: [Double](repeating: 3, count: 700), hopSeconds: hopSeconds))
        XCTAssertNil(BeatAnalysis.estimateTempo(onsetEnvelope: pulses(every: 47, count: 60), hopSeconds: hopSeconds))
        XCTAssertNil(BeatAnalysis.estimateTempo(onsetEnvelope: [], hopSeconds: hopSeconds))
    }

    func testTrackFollowsTheGridAndSkipsAnOffGridOnset() {
        var onsets = [Double](repeating: 0, count: 520)
        let grid = (0..<10).map { 10 + 47 * $0 }
        for frame in grid { onsets[frame] = 1 }
        onsets[10 + 47 * 3 + 20] = 1
        XCTAssertEqual(BeatAnalysis.track(onsets: onsets, period: 47), grid)
        XCTAssertEqual(BeatAnalysis.track(onsets: [Double](repeating: 0, count: 100), period: 47), [])
        XCTAssertEqual(BeatAnalysis.track(onsets: [], period: 47), [])
        XCTAssertNil(BeatAnalysis.track(onsets: onsets, period: 47, isCancelled: { true }))
    }

    func testAttackSampleFindsTheStartOfAHitFromEitherNeighbouringFrame() {
        let start = 100_017
        let signal = clicks(at: [start], length: 200_000)
        let frame = start / BeatAnalysis.hop
        // The hit lies in the second half of one frame and the first half of the next.
        for candidate in [frame, frame + 1] {
            let found = BeatAnalysis.attackSample(signal, aroundFrame: candidate)
            XCTAssertLessThanOrEqual(abs(found - start), 96, "frame \(candidate)")
        }
        XCTAssertEqual(BeatAnalysis.attackSample([Float](repeating: 0, count: 5_000), aroundFrame: 3), 1_536)
        XCTAssertEqual(BeatAnalysis.attackSample([], aroundFrame: 3), 0)
        XCTAssertEqual(BeatAnalysis.attackSample(signal, aroundFrame: 10_000_000), 199_999)
    }
}
