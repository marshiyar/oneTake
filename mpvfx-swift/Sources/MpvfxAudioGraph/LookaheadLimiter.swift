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

/// Integer delay shared by preset dry mixing and latency-bearing processors.
final class FxFrameDelay {
    let frames: Int
    private var ring: [[Float]] = []
    private var cursor = 0
    init(frames: Int = 0) { self.frames = frames }
    func process(_ input: [[Float]]) -> [[Float]] {
        guard frames > 0 else { return input }
        while ring.count < input.count { ring.append([Float](repeating: 0, count: frames)) }
        var out = input
        for i in 0..<(input.first?.count ?? 0) {
            for ch in input.indices {
                out[ch][i] = ring[ch][cursor]
                ring[ch][cursor] = input[ch][i]
            }
            cursor = (cursor + 1) % frames
        }
        return out
    }
}

/// Linked sample-peak limiter: a sliding minimum holds each required gain for L+1 frames.
/// A boxcar of the same length smooths attack, reaching the target by the delayed peak:
/// all L+1 terms then contain that peak's bound. Release can only lower that bound.
/// Both filters use fixed rings, with amortized constant work per frame and no block resets.
final class LookaheadLimiterUnit: FxUnit {
    let latencyFrames: Int
    let ceiling: Double
    let release: Double
    let ceilingSample: Float
    let delay: FxFrameDelay
    var automation: [String: [ParamTarget]] { [:] }
    private var minima: [Double]
    private var deadlines: [Int]
    private var head = 0, tail = 0
    private var clock = 0
    private var smooth: [Double]
    private var cursor = 0
    private var smoothSum: Double
    private var gain = 1.0

    init(_ params: FxParams, _ sampleRate: Double) {
        latencyFrames = max(1, Int((params.num("lookahead") * sampleRate / 1000).rounded()))
        ceiling = pow(10, params.num("limit") / 20)
        let roundedCeiling = Float(ceiling)
        ceilingSample = Double(roundedCeiling) > ceiling ? roundedCeiling.nextDown : roundedCeiling
        release = exp(-1 / (params.num("release") * sampleRate / 1000))
        delay = FxFrameDelay(frames: latencyFrames)
        minima = [Double](repeating: 1, count: latencyFrames + 2)
        deadlines = [Int](repeating: 0, count: latencyFrames + 2)
        smooth = [Double](repeating: 1, count: latencyFrames + 1)
        smoothSum = Double(latencyFrames + 1)
    }

    func process(_ input: [[Float]], frame: Int) -> [[Float]] {
        var out = delay.process(input)
        for i in 0..<(input.first?.count ?? 0) {
            let peak = input.reduce(0.0) { max($0, abs(Double($1[i]))) }
            if head != tail, deadlines[head] < clock {
                head = (head + 1) % minima.count
            }
            let target = peak > ceiling ? ceiling / peak : 1
            while head != tail {
                let previous = (tail + minima.count - 1) % minima.count
                if minima[previous] < target { break }
                tail = previous
            }
            minima[tail] = target
            deadlines[tail] = clock + latencyFrames
            tail = (tail + 1) % minima.count
            gain = min(minima[head], 1 - (1 - gain) * release)
            smoothSum += gain - smooth[cursor]
            smooth[cursor] = gain
            cursor = (cursor + 1) % smooth.count
            clock += 1
            let smoothedGain = min(1, max(0, smoothSum / Double(smooth.count)))
            // Only guards float rounding at the bound; the detector supplies the limiting gain.
            let cap = ceilingSample
            for ch in out.indices {
                let sample = Float(Double(out[ch][i]) * smoothedGain)
                out[ch][i] = max(-cap, min(cap, sample))
            }
        }
        return out
    }
}
