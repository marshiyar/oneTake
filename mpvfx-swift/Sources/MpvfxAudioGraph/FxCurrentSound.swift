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

/// A continuous soft knee whose width is expressed in dB.
func currentKneeGain(_ input: Double, _ threshold: Double, _ ratio: Double, _ width: Double) -> Double {
    let over = input - threshold
    let half = width / 2
    if width > 0, abs(over) < half {
        return (1 / ratio - 1) * pow(over + half, 2) / (2 * width)
    }
    return over > 0 ? over * (1 / ratio - 1) : 0
}

/// One detector and one gain for all channels, preserving the stereo image.
final class LinkedDynamicsProcessor: BlockProcessor {
    var p: FxParams
    var env: EnvelopeFollowers
    let gate: Bool
    var held = 1.0
    init(_ p: FxParams, sampleRate: Double, gate: Bool) {
        self.p = p; self.gate = gate
        env = EnvelopeFollowers(p.num("attack"), p.num("release"), sampleRate: sampleRate)
    }
    func post(_ params: FxParams) {
        for (k, v) in params.entries { p[k] = v }
        env.set(p.num("attack"), p.num("release"))
    }
    func process(_ input: [[Float]], _ output: inout [[Float]]) {
        guard let first = input.first else { return }
        for n in first.indices {
            let peak = input.reduce(0.0) { max($0, abs(Double($1[n]))) }
            let level = 20 * log10(max(1e-12, env.push(0, peak)))
            let threshold = p.num("threshold"), ratio = p.num("ratio"), width = p.num("knee")
            let gain: Double
            if gate {
                // Mirror the compressor knee around the threshold for downward expansion.
                let reduction = max(p.num("range"), currentKneeGain(2 * threshold - level, threshold, 1 / ratio, width) * -1)
                let target = pow(10, reduction / 20)
                let coefficient = target < held ? env.r : env.a
                held = target + coefficient * (held - target)
                gain = held
            } else {
                let compressed = pow(10, (currentKneeGain(level, threshold, ratio, width) + p.num("makeup")) / 20)
                gain = compressed * p.num("mix") + 1 - p.num("mix")
            }
            for ch in input.indices { output[ch][n] = Float(Double(input[ch][n]) * gain) }
        }
    }
}

/// Feedback lives inside the ring, so each repeat takes exactly the requested delay.
/// Unlike the legacy quantum cycle break, this also works for delays shorter than a block.
final class ExactFeedbackDelayUnit: FxUnit {
    let time: ParamTimeline, feedback: ParamTimeline, mix: ParamTimeline
    let sampleRate: Double
    var buffers: [[Float]] = []
    var position = 0
    let capacity: Int
    var times = [Float](repeating: 0, count: dspBlockSize)
    var feedbacks = [Float](repeating: 0, count: dspBlockSize)
    var mixes = [Float](repeating: 0, count: dspBlockSize)
    init(_ p: FxParams, _ sr: Double) {
        sampleRate = sr; capacity = Int(ceil(5 * sr)) + 2
        time = ParamTimeline(Float(p.num("time") / 1000), sampleRate: sr)
        feedback = ParamTimeline(Float(p.num("feedback")), sampleRate: sr)
        mix = ParamTimeline(Float(p.num("mix")), sampleRate: sr)
    }
    func process(_ input: [[Float]], frame: Int) -> [[Float]] {
        let count = input.first?.count ?? 0
        while buffers.count < input.count { buffers.append([Float](repeating: 0, count: capacity)) }
        time.fill(frame: frame, count: count, into: &times)
        feedback.fill(frame: frame, count: count, into: &feedbacks)
        mix.fill(frame: frame, count: count, into: &mixes)
        var output = input
        for n in 0..<count {
            let delay = max(1, min(5 * sampleRate, Double(times[n]) * sampleRate))
            let read = (Double(position) - delay + Double(capacity)).truncatingRemainder(dividingBy: Double(capacity))
            let a = Int(read), b = (a + 1) % capacity, fraction = read - floor(read)
            for ch in input.indices {
                let wet = Float(Double(buffers[ch][a]) * (1 - fraction) + Double(buffers[ch][b]) * fraction)
                buffers[ch][position] = input[ch][n] + wet * feedbacks[n]
                output[ch][n] = input[ch][n] * (1 - mixes[n]) + wet * mixes[n]
            }
            position = (position + 1) % capacity
        }
        return output
    }
    var automation: [String: [ParamTarget]] {
        ["time": [ParamTarget(param: time, map: { min(5, $0 / 1000) })],
         "feedback": [ParamTarget(param: feedback, map: nil)],
         "mix": [ParamTarget(param: mix, map: nil)]]
    }
}
