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

/// One detector and one gain for all channels, preserving the stereo image.
internal final class LinkedDynamicsProcessor: BlockProcessor {
    private var params: FxParams
    private var envelope: EnvelopeFollowers
    private let gate: Bool
    private var held: Double = 1
    private let decibelsPerAmplitude: Double = 20
    private let minimumAmplitude: Double = 1e-12
    internal init(_ params: FxParams, sampleRate: Double, gate: Bool) {
        self.params = params
        self.gate = gate
        envelope = EnvelopeFollowers(params.num("attack"), params.num("release"), sampleRate: sampleRate)
    }
    internal func post(_ params: FxParams) {
        for (key, value) in params.entries {
            self.params[key] = value
        }
        envelope.set(self.params.num("attack"), self.params.num("release"))
    }
    internal func process(_ input: [[Float]], _ output: inout [[Float]]) {
        guard let first = input.first else {
            return
        }
        for frameIndex in first.indices {
            let peak: Double = input.reduce(0) { max($0, abs(Double($1[frameIndex]))) }
            let level: Double = decibelsPerAmplitude * log10(max(minimumAmplitude, envelope.push(0, peak)))
            let threshold: Double = params.num("threshold")
            let ratio: Double = params.num("ratio")
            let width: Double = params.num("knee")
            let gain: Double
            if gate {
                // Mirror the compressor knee around the threshold for downward expansion.
                let reflectedGain: Double = currentKneeGain(2 * threshold - level, threshold, 1 / ratio, width)
                let reduction: Double = max(params.num("range"), -reflectedGain)
                let target: Double = pow(10, reduction / decibelsPerAmplitude)
                let coefficient: Double = target < held ? envelope.r : envelope.a
                held = target + coefficient * (held - target)
                gain = held
            } else {
                let reduction: Double = currentKneeGain(level, threshold, ratio, width)
                let compressed: Double = pow(10, (reduction + params.num("makeup")) / decibelsPerAmplitude)
                gain = compressed * params.num("mix") + 1 - params.num("mix")
            }
            for channel in input.indices {
                output[channel][frameIndex] = Float(Double(input[channel][frameIndex]) * gain)
            }
        }
    }
}
