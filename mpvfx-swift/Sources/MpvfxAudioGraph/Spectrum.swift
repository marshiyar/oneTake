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

/// The spectrum drawn behind the parametric EQ's curve: a 4096-point analysis of the latest samples, smoothed to
/// 1/6 octave, in dBFS from -90 to 0 (a full-scale sine peaks at 0).
public enum AudioFxSpectrum {
    public static let size = 4096
    public static let floorDb = -90.0
    public static let minHz = 20.0, maxHz = 20_000.0

    /// The frequency of point `k` of `points`, log-spaced from 20 Hz to 20 kHz.
    public static func frequency(_ k: Int, of points: Int) -> Double {
        minHz * pow(maxHz / minHz, Double(k) / Double(max(1, points - 1)))
    }

    /// Level in dBFS at `points` log-spaced frequencies for the last `size` samples of `mono` (silence-padded in front).
    /// Each point is the power in the bins within a sixth of an octave around it (divided by the Hann window's 1.5-bin
    /// noise bandwidth, so a sine reads its own level wherever it falls), or the nearest bin when the band is narrower
    /// than one.
    public static func analyse(_ mono: [Float], sampleRate: Double, points: Int = 160) -> [Double] {
        let n = size
        let tail = mono.suffix(n)
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        let offset = n - tail.count
        for (i, x) in tail.enumerated() where x.isFinite { re[offset + i] = Double(x) * window[offset + i] }
        AudioCarve.fft(&re, &im)
        // A sine of amplitude A leaves A * sum(window) / 2 in its bin.
        let scale = window.reduce(0, +) / 2
        let bins = n / 2 + 1
        let power = (0..<bins).map { (re[$0] * re[$0] + im[$0] * im[$0]) / (scale * scale) }
        let binHz = sampleRate / Double(n)
        let sixth = pow(2, 1.0 / 12)
        return (0..<points).map { k in
            let f = frequency(k, of: points)
            let lo = Int((f / sixth / binHz).rounded(.up)), hi = Int((f * sixth / binHz).rounded(.down))
            let low = max(1, min(bins - 1, lo)), high = max(low, min(bins - 1, hi))
            let mean: Double   // power in the band
            if lo > hi {
                mean = power[max(1, min(bins - 1, Int((f / binHz).rounded())))]
            } else {
                mean = power[low...high].reduce(0, +) / 1.5
            }
            return max(floorDb, min(0, 10 * log10(max(1e-12, mean))))
        }
    }
}
