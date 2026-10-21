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

// Spectral noise reduction: a short-time Fourier transform (STFT) pass that subtracts a learned noise profile.
//
// The profile is the mean power per frequency bin over a span of the clip the user points at (`learn_from`,
// `learn`); it is learned in the same pass that denoises, so playback and export see the identical stream.
// Frames before the span has produced a frame pass through; frames inside it use the profile learned so far.
// The unit delays its output by `DenoiseUnit.latency` frames; the stage that runs the chain drops that many
// frames at the start (`FxChainProcessor.latencyFrames`), so the clip stays aligned with its input.

final class DenoiseUnit: FxUnit {
    static let size = 1024
    static let hop = 256
    static let latency = 1024

    private static let window: [Double] = (0..<size).map { sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }

    private struct Channel {
        var input: [Float] = []                                  // samples from the start of the next frame
        var ola = [Double](repeating: 0, count: DenoiseUnit.size)  // overlap-add accumulator
        var out = [Float](repeating: 0, count: DenoiseUnit.latency) // finished output, pre-filled with the latency
        var outHead = 0
        var profile = [Double](repeating: 0, count: DenoiseUnit.size / 2 + 1)
        var profileFrames = 0
        var frameStart = 0                                       // first input sample of the next frame
    }

    private var channels: [Channel] = []
    private let amount: Double
    private let learnStart: Int, learnEnd: Int
    private let alpha: Double, floorPower: Double
    private var re = [Double](repeating: 0, count: DenoiseUnit.size), im = [Double](repeating: 0, count: DenoiseUnit.size)
    private var gain = [Double](repeating: 1, count: DenoiseUnit.size / 2 + 1)
    private var smooth = [Double](repeating: 1, count: DenoiseUnit.size / 2 + 1)

    init(_ p: FxParams, _ sr: Double) {
        amount = min(1, max(0, p.num("amount")))
        learnStart = Int((p.num("learn_from") * sr).rounded())
        learnEnd = learnStart + max(DenoiseUnit.size, Int((p.num("learn") / 1000 * sr).rounded()))
        alpha = 1 + 3 * amount
        let floorLin = pow(10, -30 * amount / 20)
        floorPower = floorLin * floorLin
    }

    var latencyFrames: Int { DenoiseUnit.latency }
    var automation: [String: [ParamTarget]] { [:] }

    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        while channels.count < x.count { channels.append(Channel()) }
        return x.indices.map { c in
            channels[c].input.append(contentsOf: x[c])
            if amount > 0 { runFrames(c) } else { passThrough(c) }
            return take(c, x[c].count)
        }
    }

    private func passThrough(_ c: Int) {
        channels[c].out.append(contentsOf: channels[c].input)
        channels[c].input.removeAll(keepingCapacity: true)
    }

    private func take(_ c: Int, _ count: Int) -> [Float] {
        var y = [Float](repeating: 0, count: count)
        let avail = min(count, channels[c].out.count - channels[c].outHead)
        for k in 0..<avail { y[k] = channels[c].out[channels[c].outHead + k] }
        channels[c].outHead += avail
        if channels[c].outHead >= 8192 {
            channels[c].out.removeFirst(channels[c].outHead)
            channels[c].outHead = 0
        }
        return y
    }

    private func runFrames(_ c: Int) {
        let n = DenoiseUnit.size, h = DenoiseUnit.hop, bins = n / 2 + 1
        let w = DenoiseUnit.window
        while channels[c].input.count >= n {
            for i in 0..<n { re[i] = Double(channels[c].input[i]) * w[i]; im[i] = 0 }
            AudioCarve.fft(&re, &im)
            let start = channels[c].frameStart
            let learning = start >= learnStart && start + n <= learnEnd
            if learning {
                for k in 0..<bins { channels[c].profile[k] += re[k] * re[k] + im[k] * im[k] }
                channels[c].profileFrames += 1
            }
            if channels[c].profileFrames > 0 {
                let scale = alpha / Double(channels[c].profileFrames)
                for k in 0..<bins {
                    let px = re[k] * re[k] + im[k] * im[k]
                    if px <= 1e-30 { gain[k] = 1; continue }
                    gain[k] = max(floorPower, 1 - scale * channels[c].profile[k] / px).squareRoot()
                }
                for k in 0..<bins {
                    let lo = gain[max(0, k - 1)], hi = gain[min(bins - 1, k + 1)]
                    smooth[k] = 0.25 * lo + 0.5 * gain[k] + 0.25 * hi
                }
                for k in 0..<bins {
                    re[k] *= smooth[k]; im[k] *= smooth[k]
                    if k > 0 && k < n / 2 { re[n - k] = re[k]; im[n - k] = -im[k] }
                }
            }
            // Inverse transform by conjugation: ifft(X) = conj(fft(conj(X))) / n.
            for i in 0..<n { im[i] = -im[i] }
            AudioCarve.fft(&re, &im)
            let norm = 0.5 / Double(n)
            for i in 0..<n { channels[c].ola[i] += re[i] * norm * w[i] }
            for i in 0..<h { channels[c].out.append(Float(channels[c].ola[i])) }
            channels[c].ola.removeFirst(h)
            channels[c].ola.append(contentsOf: [Double](repeating: 0, count: h))
            channels[c].input.removeFirst(h)
            channels[c].frameStart += h
        }
    }
}
