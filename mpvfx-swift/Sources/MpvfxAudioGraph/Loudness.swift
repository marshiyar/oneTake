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

public enum LoudnessError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidSampleRate(Double)
    case noChannels
    case unequalChannelLengths
    case invalidChannelWeights(expected: Int, actual: Int)
    case nonFiniteSample(channel: Int, frame: Int)
    case insufficientAudio(minimumFrames: Int, actualFrames: Int)
    case silence
    case invalidTarget(Double)

    public var description: String {
        switch self {
        case .invalidSampleRate(let rate): "Loudness measurement needs a finite sample rate above 1 kHz; got \(rate)"
        case .noChannels: "Loudness measurement needs at least one audio channel"
        case .unequalChannelLengths: "Loudness measurement needs channels with equal frame counts"
        case .invalidChannelWeights(let expected, let actual): "Loudness measurement needs \(expected) channel weights; got \(actual)"
        case .nonFiniteSample(let channel, let frame): "Audio channel \(channel) has a non-finite sample at frame \(frame)"
        case .insufficientAudio(let minimum, let actual): "Integrated loudness needs at least \(minimum) frames; got \(actual)"
        case .silence: "Integrated loudness is below the BS.1770 absolute gate (-70 LKFS)"
        case .invalidTarget(let value): "The loudness target must be finite; got \(value)"
        }
    }
}

/// ITU-R BS.1770 integrated programme loudness. Input is non-interleaved, full-scale Float PCM.
/// `channelWeights` defaults to 1 for mono/stereo. For surround, pass the BS.1770 weights in
/// channel order (LFE is 0; left/right surrounds are sqrt(2)).
public enum LoudnessMeter {
    public static func integrated(_ channels: [[Float]], sampleRate: Double,
                                  channelWeights: [Double]? = nil) throws -> Double {
        guard sampleRate.isFinite, sampleRate > 1_000 else { throw LoudnessError.invalidSampleRate(sampleRate) }
        guard let count = channels.first?.count else { throw LoudnessError.noChannels }
        guard channels.allSatisfy({ $0.count == count }) else { throw LoudnessError.unequalChannelLengths }
        let weights = channelWeights ?? [Double](repeating: 1, count: channels.count)
        guard weights.count == channels.count else {
            throw LoudnessError.invalidChannelWeights(expected: channels.count, actual: weights.count)
        }
        let block = Int((sampleRate * 0.4).rounded())
        let hop = Int((sampleRate * 0.1).rounded())
        guard count >= block else { throw LoudnessError.insufficientAudio(minimumFrames: block, actualFrames: count) }

        var power = [Float](repeating: 0, count: count)
        for channelIndex in channels.indices where weights[channelIndex] != 0 {
            var shelf = Biquad.highShelf(sampleRate: sampleRate)
            var highPass = Biquad.highPass(sampleRate: sampleRate)
            let weight = Float(weights[channelIndex])
            for frame in 0..<count {
                let input = channels[channelIndex][frame]
                guard input.isFinite else { throw LoudnessError.nonFiniteSample(channel: channelIndex, frame: frame) }
                let value = highPass.process(shelf.process(input))
                power[frame] += weight * value * value
            }
        }

        var energies: [Double] = []
        energies.reserveCapacity((count - block) / hop + 1)
        var sum = power[..<block].reduce(0.0) { $0 + Double($1) }
        var start = 0
        while true {
            energies.append(sum / Double(block))
            let next = start + hop
            if next + block > count { break }
            for frame in start..<next { sum -= Double(power[frame]) }
            for frame in (start + block)..<(next + block) { sum += Double(power[frame]) }
            start = next
        }
        let absolute = energies.filter { loudness($0) >= -70 }
        guard !absolute.isEmpty else { throw LoudnessError.silence }
        let absoluteMean = absolute.reduce(0, +) / Double(absolute.count)
        let relativeGate = loudness(absoluteMean) - 10
        let relative = absolute.filter { loudness($0) >= relativeGate }
        guard !relative.isEmpty else { throw LoudnessError.silence }
        return loudness(relative.reduce(0, +) / Double(relative.count))
    }

    /// Runs filtering and gating on a detached task, so callers cannot accidentally measure on the UI executor.
    public static func integratedDetached(_ channels: [[Float]], sampleRate: Double,
                                          channelWeights: [Double]? = nil) async throws -> Double {
        try await Task.detached(priority: .userInitiated) {
            try integrated(channels, sampleRate: sampleRate, channelWeights: channelWeights)
        }.value
    }

    /// Measures the exact graph render used by both preview and export.
    public static func integrated(_ project: AudioGraphProject) throws -> Double {
        let interleaved = AudioGraphRenderer.renderOffline(project)
        var left = [Float](); var right = [Float]()
        left.reserveCapacity(interleaved.count / 2); right.reserveCapacity(interleaved.count / 2)
        var index = 0
        while index + 1 < interleaved.count { left.append(interleaved[index]); right.append(interleaved[index + 1]); index += 2 }
        return try integrated([left, right], sampleRate: project.sampleRate)
    }

    private static func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
}

public struct LoudnessMatch: Equatable, Sendable {
    public let id: String
    public let measuredLKFS: Double
    public let gain: Double
}

public enum LoudnessMatcher {
    /// Returns linear gains which put each independently measured clip at `targetLKFS`.
    public static func gains(_ measurements: [(id: String, loudness: Double)], targetLKFS: Double) throws -> [LoudnessMatch] {
        guard targetLKFS.isFinite else { throw LoudnessError.invalidTarget(targetLKFS) }
        return try measurements.map { item in
            guard item.loudness.isFinite else { throw LoudnessError.silence }
            return LoudnessMatch(id: item.id, measuredLKFS: item.loudness,
                                 gain: pow(10, (targetLKFS - item.loudness) / 20))
        }
    }
}

private struct Biquad {
    let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    static func highShelf(sampleRate: Double) -> Biquad {
        if sampleRate == 48_000 {
            return Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                          a1: -1.69065929318241, a2: 0.73248077421585)
        }
        let frequency = 1_681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        let amplitude = pow(10, gain / 40), w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q), root = 2 * sqrt(amplitude) * alpha
        let a0 = (amplitude + 1) - (amplitude - 1) * cos(w) + root
        return Biquad(b0: Float(amplitude * ((amplitude + 1) + (amplitude - 1) * cos(w) + root) / a0),
                      b1: Float(-2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cos(w)) / a0),
                      b2: Float(amplitude * ((amplitude + 1) + (amplitude - 1) * cos(w) - root) / a0),
                      a1: Float(2 * ((amplitude - 1) - (amplitude + 1) * cos(w)) / a0),
                      a2: Float(((amplitude + 1) - (amplitude - 1) * cos(w) - root) / a0))
    }

    static func highPass(sampleRate: Double) -> Biquad {
        if sampleRate == 48_000 {
            return Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
        }
        let frequency = 38.13547087602444, q = 0.5003270373238773
        let w = 2 * Double.pi * frequency / sampleRate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: Float((1 + cos(w)) / (2 * a0)), b1: Float(-(1 + cos(w)) / a0),
                      b2: Float((1 + cos(w)) / (2 * a0)), a1: Float(-2 * cos(w) / a0), a2: Float((1 - alpha) / a0))
    }
}
