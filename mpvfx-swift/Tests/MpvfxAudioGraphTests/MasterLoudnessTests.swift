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

final class MasterLoudnessTests: XCTestCase {
    private let rate = 48_000.0

    private func sine(_ dBFS: Double, hz: Double = 1_000, phase: Double = 0, seconds: Double = 4) -> [Float] {
        let amplitude = pow(10, dBFS / 20)
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate + phase)) }
    }

    private func stereo(_ channel: [Float]) -> [Float] { MasterLoudness.interleave([channel, channel]) }

    func testA1TargetMinus23IsReachedWithinHalfALUAndTheCeilingHolds() throws {
        for dBFS in [-45.0, -30.0, -12.0] {
            let (out, result) = try MasterLoudness.normalise(stereo(sine(dBFS)), sampleRate: rate, target: MasterLoudnessTarget())
            let measured = try LoudnessMeter.integrated(MasterLoudness.deinterleave(out), sampleRate: rate)
            XCTAssertEqual(measured, -23, accuracy: 0.5, "\(dBFS) dBFS")
            XCTAssertEqual(result.loudness ?? 0, measured, accuracy: 1e-9)
            let peak = try XCTUnwrap(TruePeak.dBTP(MasterLoudness.deinterleave(out)))
            XCTAssertLessThanOrEqual(peak, -1, "\(dBFS) dBFS")
            XCTAssertEqual(result.truePeak ?? 0, peak, accuracy: 1e-9)
        }
    }

    func testPeakyMixStaysUnderTheCeilingAndReportsItWasLimited() throws {
        // A quiet bed with a loud click every half second: the gain that brings the bed to -23 LUFS puts the clicks far over.
        var bed = sine(-40)
        for i in stride(from: 12_000, to: bed.count, by: 24_000) { bed[i] = 0.95 }
        let target = MasterLoudnessTarget(target: -23, truePeak: -1)
        let (out, result) = try MasterLoudness.normalise(stereo(bed), sampleRate: rate, target: target)
        let peak = try XCTUnwrap(TruePeak.dBTP(MasterLoudness.deinterleave(out)))
        XCTAssertLessThanOrEqual(peak, -1)
        XCTAssertTrue(result.limited)
        XCTAssertEqual(out.count, bed.count * 2, "no samples are added or lost")
    }

    func testCeilingIsHeldInTruePeakTermsNotJustSamplePeak() throws {
        // A sine at a quarter of the sample rate, 45 degrees in: every sample is +-0.707 of the amplitude, the real peak is the full amplitude.
        let signal = sine(-6, hz: rate / 4, phase: .pi / 4)
        let samplePeak = signal.map { abs($0) }.max() ?? 0
        let reading = try XCTUnwrap(TruePeak.dBTP([signal]))
        XCTAssertEqual(reading, -6, accuracy: 0.1)
        XCTAssertLessThan(20 * log10(Double(samplePeak)), reading - 2.5, "the premise: the samples alone under-read")
        // K-weighting lifts 12 kHz by about 4 dB, so -5 LUFS asks for a true peak near -9 dBTP while the samples read 3 dB lower:
        // a limiter that only watched samples would let it through.
        let target = MasterLoudnessTarget(target: -5, truePeak: -9)
        let (out, result) = try MasterLoudness.normalise(stereo(signal), sampleRate: rate, target: target)
        let channels = MasterLoudness.deinterleave(out)
        XCTAssertLessThanOrEqual(try XCTUnwrap(TruePeak.dBTP(channels)), -9)
        XCTAssertEqual(result.truePeak ?? 0, try XCTUnwrap(TruePeak.dBTP(channels)), accuracy: 1e-9)
    }

    func testSilentOrTooShortMixIsReturnedUnchanged() throws {
        let silent = [Float](repeating: 0, count: 48_000 * 2 * 2)
        let a = try MasterLoudness.normalise(silent, sampleRate: rate, target: MasterLoudnessTarget())
        XCTAssertEqual(a.samples, silent)
        XCTAssertNil(a.result.before)
        XCTAssertEqual(a.result.gainDB, 0)
        let short = stereo(Array(sine(-20).prefix(4_800)))
        let b = try MasterLoudness.normalise(short, sampleRate: rate, target: MasterLoudnessTarget())
        XCTAssertEqual(b.samples, short)
        XCTAssertNil(b.result.before)
    }

    func testResultReportsTheGainThatWasApplied() throws {
        let signal = stereo(sine(-33))
        let (out, result) = try MasterLoudness.normalise(signal, sampleRate: rate, target: MasterLoudnessTarget())
        // A mono 1 kHz sine at -20 dBFS reads -23 LKFS, and the same sine on both channels reads 3 LU more.
        XCTAssertEqual(try XCTUnwrap(result.before), -33, accuracy: 0.2)
        XCTAssertEqual(result.gainDB, -23 - (result.before ?? 0), accuracy: 0.5)
        XCTAssertFalse(result.limited)
        XCTAssertEqual(out.count, signal.count)
    }

    func testInvalidTargetsAreRefusedWithAReason() {
        let signal = stereo(sine(-20))
        for bad in [MasterLoudnessTarget(target: .nan), MasterLoudnessTarget(target: 3), MasterLoudnessTarget(target: -60),
                    MasterLoudnessTarget(truePeak: 1), MasterLoudnessTarget(truePeak: -20), MasterLoudnessTarget(truePeak: .infinity)] {
            XCTAssertNotNil(bad.issue)
            XCTAssertThrowsError(try MasterLoudness.normalise(signal, sampleRate: rate, target: bad))
        }
        XCTAssertNil(MasterLoudnessTarget().issue)
    }
}
