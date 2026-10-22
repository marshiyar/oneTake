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

/// Feedback lives inside the ring, so each repeat takes exactly the requested delay.
/// Unlike the legacy quantum cycle break, this also works for delays shorter than a block.
internal final class ExactFeedbackDelayUnit: FxUnit {
    private let time: ParamTimeline
    private let feedback: ParamTimeline
    private let mix: ParamTimeline
    private static let maximumDelaySeconds: Double = 5
    private static let millisecondsPerSecond: Double = 1_000
    private let sampleRate: Double
    private var buffers: [[Float]] = []
    private var position: Int = 0
    private let capacity: Int
    private var times: [Float] = [Float](repeating: 0, count: dspBlockSize)
    private var feedbacks: [Float] = [Float](repeating: 0, count: dspBlockSize)
    private var mixes: [Float] = [Float](repeating: 0, count: dspBlockSize)
    internal init(_ params: FxParams, _ rate: Double) {
        sampleRate = rate
        capacity = Int(ceil(Self.maximumDelaySeconds * rate)) + 2
        time = ParamTimeline(Float(params.num("time") / Self.millisecondsPerSecond), sampleRate: rate)
        feedback = ParamTimeline(Float(params.num("feedback")), sampleRate: rate)
        mix = ParamTimeline(Float(params.num("mix")), sampleRate: rate)
    }
    internal func process(_ input: [[Float]], frame: Int) -> [[Float]] {
        let count: Int = input.first?.count ?? 0
        while buffers.count < input.count {
            buffers.append([Float](repeating: 0, count: capacity))
        }
        time.fill(frame: frame, count: count, into: &times)
        feedback.fill(frame: frame, count: count, into: &feedbacks)
        mix.fill(frame: frame, count: count, into: &mixes)
        var output: [[Float]] = input
        for frameIndex in 0..<count {
            let delay: Double = max(
                1, min(Self.maximumDelaySeconds * sampleRate, Double(times[frameIndex]) * sampleRate))
            let read: Double = (Double(position) - delay + Double(capacity)).truncatingRemainder(
                dividingBy: Double(capacity))
            let firstIndex: Int = Int(read)
            let secondIndex: Int = (firstIndex + 1) % capacity
            let fraction: Double = read - floor(read)
            for channel in input.indices {
                let firstSample: Double = Double(buffers[channel][firstIndex]) * (1 - fraction)
                let secondSample: Double = Double(buffers[channel][secondIndex]) * fraction
                let wet: Float = Float(firstSample + secondSample)
                buffers[channel][position] = input[channel][frameIndex] + wet * feedbacks[frameIndex]
                output[channel][frameIndex] =
                    input[channel][frameIndex] * (1 - mixes[frameIndex]) + wet * mixes[frameIndex]
            }
            position = (position + 1) % capacity
        }
        return output
    }
    internal var automation: [String: [ParamTarget]] {
        [
            "time": [ParamTarget(param: time, map: { min(Self.maximumDelaySeconds, $0 / Self.millisecondsPerSecond) })],
            "feedback": [ParamTarget(param: feedback, map: nil)],
            "mix": [ParamTarget(param: mix, map: nil)],
        ]
    }
}
