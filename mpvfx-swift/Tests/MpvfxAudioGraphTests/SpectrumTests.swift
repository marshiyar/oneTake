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

/// The spectrum behind the EQ curve reads where the energy is.
final class SpectrumTests: XCTestCase {
    let sr = 48000.0
    func sine(_ f: Double, amplitude: Double = 1, count: Int = 8192) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * f * Double($0) / sr)) }
    }

    func testASineOfOneKilohertzPeaksWithinASixthOfAnOctaveOfIt() {
        let points = 320
        for f in [250.0, 1000, 4000] {
            let s = AudioFxSpectrum.analyse(sine(f), sampleRate: sr, points: points)
            let peak = s.indices.max { s[$0] < s[$1] }!
            let at = AudioFxSpectrum.frequency(peak, of: points)
            XCTAssertLessThanOrEqual(abs(log2(at / f)), 1.0 / 6, "\(f) Hz peaked at \(at) Hz")
        }
    }

    func testAFullScaleSineReadsNearZeroAndSilenceReadsTheFloor() {
        let s = AudioFxSpectrum.analyse(sine(1000), sampleRate: sr, points: 320)
        XCTAssertGreaterThan(s.max() ?? -99, -3.5, "a full-scale sine is near 0 dBFS")
        XCTAssertLessThanOrEqual(s.max() ?? 99, 0)
        let quiet = AudioFxSpectrum.analyse(sine(1000, amplitude: 0.1), sampleRate: sr, points: 320)
        XCTAssertEqual((quiet.max() ?? 0) - (s.max() ?? 0), -20, accuracy: 0.5, "a tenth of the amplitude is 20 dB down")
        let silent = AudioFxSpectrum.analyse([Float](repeating: 0, count: 100), sampleRate: sr)
        XCTAssertEqual(Set(silent), [AudioFxSpectrum.floorDb])
    }

    func testShortAndNonFiniteInputIsSafe() {
        XCTAssertEqual(AudioFxSpectrum.analyse([], sampleRate: sr, points: 64).count, 64)
        let s = AudioFxSpectrum.analyse([.nan, .infinity, 0.5, -0.5], sampleRate: sr, points: 64)
        XCTAssertTrue(s.allSatisfy { $0.isFinite && $0 >= AudioFxSpectrum.floorDb && $0 <= 0 })
    }
}
