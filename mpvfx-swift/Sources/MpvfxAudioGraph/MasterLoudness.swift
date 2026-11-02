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
// Export loudness: one final gain brings the mix to a programme loudness (ITU-R BS.1770, `LoudnessMeter`), then the
// lookahead limiter (`LookaheadLimiterUnit`, #205) holds the true-peak ceiling. True peak is the highest value the
// reconstructed signal reaches between samples: BS.1770-4 Annex 2 measures it on a 4x oversampled copy. The oversampler
// here is a 48-tap Blackman-windowed sinc split into four phases (the Annex gives a coefficient table; this one is
// derived from the same design, so a reading can differ from a certified meter by a few hundredths of a dB).
// ITU-R BS.1770: https://www.itu.int/rec/R-REC-BS.1770  EBU R128: https://tech.ebu.ch/publications/r128
import Foundation

/// The loudness an export is brought to: a programme loudness in LUFS (EBU R128 asks for -23) and the highest true
/// peak the output may reach in dBTP (-1 is the usual delivery ceiling).
public struct MasterLoudnessTarget: Equatable, Sendable {
    public static let defaultTarget = -23.0
    public static let defaultTruePeak = -1.0
    /// What the Renders tab offers and the validator accepts.
    public static let targetRange = -50.0 ... -5.0
    public static let truePeakRange = -9.0 ... 0.0

    public var target: Double
    public var truePeak: Double
    public init(target: Double = defaultTarget, truePeak: Double = defaultTruePeak) {
        self.target = target; self.truePeak = truePeak
    }

    /// The reason these values can't be used, or nil.
    public var issue: String? {
        guard target.isFinite, Self.targetRange.contains(target) else {
            return "The loudness target must be between \(Int(Self.targetRange.lowerBound)) and \(Int(Self.targetRange.upperBound)) LUFS"
        }
        guard truePeak.isFinite, Self.truePeakRange.contains(truePeak) else {
            return "The true-peak ceiling must be between \(Int(Self.truePeakRange.lowerBound)) and \(Int(Self.truePeakRange.upperBound)) dBTP"
        }
        return nil
    }
}

/// What normalising a mix measured and did.
public struct MasterLoudnessResult: Equatable, Sendable {
    /// Integrated loudness of the mix before the gain; nil when it is silent or shorter than one 400 ms block (the
    /// mix is then left as it is).
    public var before: Double?
    /// The final gain in dB (0 when nothing was applied).
    public var gainDB: Double
    /// Integrated loudness and true peak of what is exported; nil when the output is silent or too short.
    public var loudness: Double?
    public var truePeak: Double?
    /// The limiter had to act, so the output is quieter than the target.
    public var limited: Bool
}

public enum MasterLoudnessError: Error, Equatable, CustomStringConvertible {
    case invalidTarget(String)
    public var description: String {
        switch self { case .invalidTarget(let reason): return reason }
    }
}

public enum TruePeak {
    static let factor = 4, tapsPerPhase = 12

    /// phases[p][k] weights input frame `n + k - 5` for the output sample p/4 of the way from frame n to n + 1.
    static let phases: [[Float]] = (0..<factor).map { p in
        (0..<tapsPerPhase).map { k in
            let t = Double(k - (tapsPerPhase / 2 - 1)) - Double(p) / Double(factor)
            let half = Double(tapsPerPhase / 2)
            guard abs(t) < half else { return 0 }
            let x = Double.pi * t
            let sinc = abs(t) < 1e-12 ? 1 : sin(x) / x
            let w = 0.42 + 0.5 * cos(Double.pi * t / half) + 0.08 * cos(2 * Double.pi * t / half)
            return Float(sinc * w)
        }
    }

    /// Highest absolute value of the 4x oversampled channel.
    public static func peak(_ channel: [Float]) -> Float {
        let n = channel.count
        guard n > 0 else { return 0 }
        var peak: Float = 0
        let lead = tapsPerPhase / 2 - 1
        channel.withUnsafeBufferPointer { x in
            for i in 0..<n {
                peak = max(peak, abs(x[i]))
                for p in 1..<factor {
                    var sum: Float = 0
                    let taps = phases[p]
                    for k in 0..<tapsPerPhase {
                        let j = i + k - lead
                        if j >= 0 && j < n { sum += x[j] * taps[k] }
                    }
                    peak = max(peak, abs(sum))
                }
            }
        }
        return peak
    }

    /// True peak of de-interleaved channels in dBTP; nil for silence.
    public static func dBTP(_ channels: [[Float]]) -> Double? {
        let top = channels.map { peak($0) }.max() ?? 0
        return top > 0 ? 20 * log10(Double(top)) : nil
    }
}

public enum MasterLoudness {
    /// Lookahead and release of the limiter that holds the ceiling.
    static let lookaheadMs = 5.0, releaseMs = 100.0

    /// Brings an interleaved stereo mix to `target.target` LUFS with its true peak at or under `target.truePeak`.
    /// A silent mix, or one shorter than a 400 ms block, comes back unchanged. Where the ceiling stops the mix reaching
    /// the target the output is quieter than asked and `limited` says so; the result always reports what was measured on
    /// the samples returned.
    public static func normalise(_ interleaved: [Float], sampleRate: Double,
                                 target: MasterLoudnessTarget) throws -> (samples: [Float], result: MasterLoudnessResult) {
        if let issue = target.issue { throw MasterLoudnessError.invalidTarget(issue) }
        let channels = deinterleave(interleaved)
        let before: Double
        do { before = try LoudnessMeter.integrated(channels, sampleRate: sampleRate) } catch LoudnessError.silence {
            return unchanged(interleaved, channels, sampleRate)
        } catch LoudnessError.insufficientAudio {
            return unchanged(interleaved, channels, sampleRate)
        }
        let gainDB = target.target - before
        let gain = Float(pow(10, gainDB / 20))
        let scaled = channels.map { $0.map { $0 * gain } }
        // The limiter works on sample peaks; if the oversampled peak of its output is still over, lower its ceiling by
        // the excess and run again. Linear scaling is the last resort, and it is exact because oversampling is linear.
        var ceiling = target.truePeak
        var out = scaled
        var limited = false
        for _ in 0..<4 {
            out = limit(scaled, ceilingDB: ceiling, sampleRate: sampleRate, limited: &limited)
            guard let tp = TruePeak.dBTP(out), tp > target.truePeak else { break }
            ceiling -= (tp - target.truePeak) + 0.01
        }
        if let tp = TruePeak.dBTP(out), tp > target.truePeak {
            let k = Float(pow(10, (target.truePeak - tp - 0.001) / 20))
            out = out.map { $0.map { $0 * k } }
            limited = true
        }
        let finalLoudness = try? LoudnessMeter.integrated(out, sampleRate: sampleRate)
        let finalGain = finalLoudness.map { $0 - before } ?? gainDB
        return (interleave(out), MasterLoudnessResult(before: before, gainDB: finalGain, loudness: finalLoudness,
                                                      truePeak: TruePeak.dBTP(out), limited: limited))
    }

    /// Runs the lookahead limiter over a whole buffer and removes its delay.
    static func limit(_ channels: [[Float]], ceilingDB: Double, sampleRate: Double, limited: inout Bool) -> [[Float]] {
        let params = FxParams([("limit", .number(ceilingDB)), ("lookahead", .number(lookaheadMs)), ("release", .number(releaseMs))])
        let unit = LookaheadLimiterUnit(params, sampleRate)
        let count = channels.first?.count ?? 0
        let ceiling = Float(pow(10, ceilingDB / 20))
        if channels.contains(where: { $0.contains { abs($0) > ceiling } }) { limited = true }
        let padded = channels.map { $0 + [Float](repeating: 0, count: unit.latencyFrames) }
        let processed = unit.process(padded, frame: 0)
        return processed.map { Array($0[unit.latencyFrames..<(unit.latencyFrames + count)]) }
    }

    static func unchanged(_ interleaved: [Float], _ channels: [[Float]],
                          _ sampleRate: Double) -> (samples: [Float], result: MasterLoudnessResult) {
        (interleaved, MasterLoudnessResult(before: nil, gainDB: 0, loudness: nil, truePeak: TruePeak.dBTP(channels), limited: false))
    }

    public static func deinterleave(_ samples: [Float]) -> [[Float]] {
        var left = [Float](), right = [Float]()
        left.reserveCapacity(samples.count / 2); right.reserveCapacity(samples.count / 2)
        var i = 0
        while i + 1 < samples.count { left.append(samples[i]); right.append(samples[i + 1]); i += 2 }
        return [left, right]
    }

    public static func interleave(_ channels: [[Float]]) -> [Float] {
        guard channels.count == 2 else { return channels.first ?? [] }
        var out = [Float](repeating: 0, count: channels[0].count * 2)
        for i in 0..<channels[0].count { out[2 * i] = channels[0][i]; out[2 * i + 1] = channels[1][i] }
        return out
    }
}
