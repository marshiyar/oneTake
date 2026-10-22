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

final class LoudnessTests: XCTestCase {
    private let sampleRate = 48_000

    private func sine(levelDBFS: Double, seconds: Int = 3) -> [Float] {
        let amplitude = pow(10, levelDBFS / 20)
        return (0..<(sampleRate * seconds)).map { Float(amplitude * sin(2 * .pi * 1_000 * Double($0) / Double(sampleRate))) }
    }

    /// ITU-R BS.1770-5 (November 2023), §2 and equations (4)-(5): K-weighting, 400 ms blocks and two-stage gating.
    /// A full-scale convention 1 kHz mono sine at -20 dBFS reads -23 LKFS (the reference alignment signal).
    func testBS1770ReferenceAlignmentSignalWithinPointOneLU() throws {
        XCTAssertEqual(try LoudnessMeter.integrated([sine(levelDBFS: -20)], sampleRate: Double(sampleRate)), -23, accuracy: 0.1)
    }

    func testThreeDifferentClipsMatchTargetWithinPointFiveLU() throws {
        let levels = [-12.0, -20.0, -28.0]
        let measured = try levels.enumerated().map { (id: "clip-\($0.offset)", loudness: try LoudnessMeter.integrated([sine(levelDBFS: $0.element)], sampleRate: Double(sampleRate))) }
        let matches = try LoudnessMatcher.gains(measured, targetLKFS: -18)
        for (level, match) in zip(levels, matches) {
            let adjusted = sine(levelDBFS: level).map { $0 * Float(match.gain) }
            XCTAssertEqual(try LoudnessMeter.integrated([adjusted], sampleRate: Double(sampleRate)), -18, accuracy: 0.5)
        }
    }

    func testAmplitudeChannelWeightsAreSquaredForPower() throws {
        let signal = sine(levelDBFS: -20)
        let unweighted = try LoudnessMeter.integrated([signal], sampleRate: Double(sampleRate), channelWeights: [1])
        let surround = try LoudnessMeter.integrated(
            [signal], sampleRate: Double(sampleRate), channelWeights: [sqrt(2)]
        )
        XCTAssertEqual(surround - unweighted, 10 * log10(2), accuracy: 0.001)
    }

    func testInvalidChannelWeightsProduceTypedErrors() {
        let signal = sine(levelDBFS: -20)
        for weight: Double in [-1, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(
                try LoudnessMeter.integrated([signal], sampleRate: Double(sampleRate), channelWeights: [weight])
            ) {
                guard case .invalidChannelWeight(index: 0, value: let value) = $0 as? LoudnessError else {
                    return XCTFail("unexpected error: \($0)")
                }
                if weight.isNaN { XCTAssertTrue(value.isNaN) } else { XCTAssertEqual(value, weight) }
            }
        }
    }

    func testUnrepresentableWindowSizesProduceTypedSampleRateError() {
        let sampleRate = Double.greatestFiniteMagnitude
        XCTAssertThrowsError(try LoudnessMeter.integrated([[0]], sampleRate: sampleRate)) {
            XCTAssertEqual($0 as? LoudnessError, .invalidSampleRate(sampleRate))
        }
    }

    func testTenMinuteStereoBudgetOffMainThread() async throws {
        let reusableSecond = sine(levelDBFS: -20, seconds: 1)
        let channel = Array(repeating: reusableSecond, count: 600).flatMap { $0 }
        let start = ContinuousClock.now
        let result = try await LoudnessMeter.integratedDetached([channel, channel], sampleRate: Double(sampleRate))
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(result, -20, accuracy: 0.1)
        // Calibrated 2026-10-22: a debug build on the shared self-hosted Linux runner measures ~1.3 s. 2 s keeps
        // the ratchet catching 10x regressions without flaking on runner noise.
        XCTAssertLessThan(elapsed, .seconds(2), "10 minutes stereo must measure in <= 2 s on the CI Linux runner")
    }

    func testFailuresAreTypedAndActionable() {
        XCTAssertThrowsError(try LoudnessMeter.integrated([], sampleRate: 48_000)) { XCTAssertEqual($0 as? LoudnessError, .noChannels) }
        XCTAssertThrowsError(try LoudnessMeter.integrated([[0]], sampleRate: 48_000)) {
            guard case .insufficientAudio = $0 as? LoudnessError else { return XCTFail("unexpected error: \($0)") }
        }
    }
}
