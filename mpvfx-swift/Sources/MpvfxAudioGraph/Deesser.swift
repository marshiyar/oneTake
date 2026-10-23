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

/// Static high-band gain law, also used by the rack's detector-level transfer curve.
func deesserReduction(_ level: Double, threshold: Double, range: Double) -> Double {
    max(range, min(0, threshold - level))
}

/// Fourth-order Butterworth sections; each channel owns its filter memories.
private struct DeesserFilter {
    var c: BiquadCoefficients
    var z1 = 0.0, z2 = 0.0
    mutating func push(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// Complementary split: low + (input - low) is exactly dry at unity gain.
/// The detector spans roughly 4–10 kHz at the default 6.5 kHz setting. A fourth-order
/// low-pass at half the detector frequency protects the voice body; only the remainder
/// is attenuated. A single envelope drives every channel, preserving stereo balance.
final class DeesserProcessor: BlockProcessor {
    var p: FxParams
    let sampleRate: Double
    var envelope: EnvelopeFollowers
    private var coefficients: [BiquadCoefficients] = []
    private var filters: [[DeesserFilter]] = []
    init(_ p: FxParams, sampleRate: Double) {
        self.p = p
        self.sampleRate = sampleRate
        envelope = EnvelopeFollowers(p.num("attack"), p.num("release"), sampleRate: sampleRate)
        configure()
    }
    private func configure() {
        let f = p.num("frequency")
        let nyquist = sampleRate / 2
        coefficients = [(BiquadType.highpass, f * 4 / 6.5), (.lowpass, f * 10 / 6.5), (.lowpass, f / 2)].flatMap {
            type, cutoff in
            [0.541196100146197, 1.306562964876377].map { q in
                BiquadCoefficients.make(type, frequency: min(0.95, cutoff / nyquist), q: q, gain: 0, linearPassQ: true)
            }
        }
        for ch in filters.indices {
            for k in coefficients.indices { filters[ch][k].c = coefficients[k] }
        }
    }
    func post(_ params: FxParams) {
        let oldFrequency = p.num("frequency")
        for (k, v) in params.entries { p[k] = v }
        envelope.set(p.num("attack"), p.num("release"))
        if p.num("frequency") != oldFrequency { configure() }
    }
    func process(_ input: [[Float]], _ output: inout [[Float]]) {
        guard let first = input.first else { return }
        while filters.count < input.count { filters.append(coefficients.map { DeesserFilter(c: $0) }) }
        // Use the already-sized output as detector scratch, avoiding per-frame allocation.
        for frame in first.indices {
            let peak = detectorPeak(input, frame: frame, scratch: &output)
            let level = 20 * log10(max(1e-12, envelope.push(0, peak)))
            let gain = dbToLin(deesserReduction(level, threshold: p.num("threshold"), range: p.num("range")))
            applyGain(input, frame: frame, gain: gain, output: &output)
        }
    }

    private func detectorPeak(_ input: [[Float]], frame: Int, scratch: inout [[Float]]) -> Double {
        var peak = 0.0
        for channel in input.indices {
            var detector = Double(input[channel][frame])
            for section in 0..<4 { detector = filters[channel][section].push(detector) }
            peak = max(peak, abs(detector))
            scratch[channel][frame] = Float(detector)
        }
        return peak
    }

    private func applyGain(_ input: [[Float]], frame: Int, gain: Double, output: inout [[Float]]) {
        for channel in input.indices {
            let sample = Double(input[channel][frame])
            var low = sample
            for section in 4..<6 { low = filters[channel][section].push(low) }
            if p["listen"]?.string != "on" {
                output[channel][frame] = gain == 1 ? input[channel][frame] : Float(low + (sample - low) * gain)
            }
        }
    }
}
