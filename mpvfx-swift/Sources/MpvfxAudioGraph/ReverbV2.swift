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

/// Exact zero-latency convolution. The 128-tap head is evaluated directly; tail
/// partitions cover [128,256), [256,512), ... . A tail's offset equals its block
/// size, so its FFT is ready before its first output sample is due. Processing
/// uses only storage allocated by init; callers supply their own output buffer.
final class NonUniformConvolver {
    private let head: [Double]
    private var history = [Double](repeating: 0, count: dspBlockSize)
    private var cursor = 0
    private var position = 0
    private let stages: [TailPartition]
    private var pending: [Double]

    init(impulse: [Float]) {
        head = impulse.prefix(dspBlockSize).map(Double.init)
        var parts: [TailPartition] = []
        var size = dspBlockSize
        while size < impulse.count {
            parts.append(TailPartition(impulse: impulse, offset: size, size: size))
            size *= 2
        }
        stages = parts
        pending = [Double](repeating: 0, count: max(1, size * 2))
    }

    func process(_ input: [Float], into output: inout [Float]) {
        for i in input.indices {
            let sample = Double(input[i])
            history[cursor] = sample
            var value = 0.0
            for tap in head.indices {
                value += head[tap] * history[(cursor - tap + dspBlockSize) % dspBlockSize]
            }
            for stage in stages {
                stage.push(sample, position: position, into: &pending)
            }
            let slot = position % pending.count
            output[i] = Float(value + pending[slot])
            pending[slot] = 0
            cursor = (cursor + 1) % dspBlockSize
            position += 1
        }
    }
}

private final class TailPartition {
    let size: Int
    let offset: Int
    private let kernelReal: [Double]
    private let kernelImaginary: [Double]
    private var real: [Double]
    private var imaginary: [Double]
    private var filled = 0

    init(impulse: [Float], offset: Int, size: Int) {
        self.offset = offset
        self.size = size
        var re = [Double](repeating: 0, count: size * 2)
        var im = [Double](repeating: 0, count: size * 2)
        for i in 0..<min(size, impulse.count - offset) { re[i] = Double(impulse[offset + i]) }
        AudioCarve.fft(&re, &im)
        kernelReal = re
        kernelImaginary = im
        real = [Double](repeating: 0, count: size * 2)
        imaginary = [Double](repeating: 0, count: size * 2)
    }

    func push(_ sample: Double, position: Int, into pending: inout [Double]) {
        real[filled] = sample
        filled += 1
        guard filled == size else { return }
        for i in size..<real.count { real[i] = 0 }
        for i in imaginary.indices { imaginary[i] = 0 }
        AudioCarve.fft(&real, &imaginary)
        for i in real.indices {
            let re = real[i] * kernelReal[i] - imaginary[i] * kernelImaginary[i]
            imaginary[i] = -(real[i] * kernelImaginary[i] + imaginary[i] * kernelReal[i])
            real[i] = re
        }
        AudioCarve.fft(&real, &imaginary)
        let start = position + 1 - size + offset
        let scale = 1 / Double(real.count)
        for i in real.indices { pending[(start + i) % pending.count] += real[i] * scale }
        filled = 0
    }
}

/// Separate channel seeds retain the same decay envelope and energy. Width zero
/// gives both channels the same impulse; width one gives independent impulses.
func stereoReverbImpulse(sampleRate: Double, size: Double, damping: Double,
                         width: Double, channel: Int, preDelay: Double, lowCut: Double) -> [Float] {
    let count = max(1, Int(sampleRate * (0.6 + size * 2.6)))
    let delay = Int((preDelay * sampleRate / 1000).rounded())
    var commonSeed: UInt32 = 0x9e3779b9
    var sideSeed: UInt32 = channel == 0 ? 0x243f6a88 : 0xb7e15162
    var lp = 0.0, previous = 0.0, high = 0.0, energy = 0.0
    let cutoff = max(0.001, 1 - damping)
    let pole = lowCut > 0 ? exp(-2 * Double.pi * lowCut / sampleRate) : 0
    var impulse = [Float](repeating: 0, count: delay + count)
    for i in 0..<count {
        commonSeed = commonSeed &* 1664525 &+ 1013904223
        sideSeed = sideSeed &* 1664525 &+ 1013904223
        let common = Double(commonSeed) / Double(UInt32.max) * 2 - 1
        let side = Double(sideSeed) / Double(UInt32.max) * 2 - 1
        lp += cutoff * ((1 - width) * common + width * side - lp)
        high = lowCut > 0 ? pole * (high + lp - previous) : lp
        previous = lp
        let value = high * pow(1 - Double(i) / Double(count), 2.5)
        impulse[delay + i] = Float(value)
        energy += value * value
    }
    if energy > 0 {
        let gain = 1 / energy.squareRoot()
        for i in delay..<impulse.count { impulse[i] = Float(Double(impulse[i]) * gain) }
    }
    return impulse
}

/// The `reverb-v2` type is the persisted DSP version: legacy `reverb` nodes and
/// presets still use ReverbUnit, without migrating their parameters or samples.
final class ReverbV2Unit: FxUnit {
    private let convolvers: [NonUniformConvolver]
    private var output = [[Float]](repeating: [Float](repeating: 0, count: dspBlockSize), count: 2)
    let wet: GainStage, dry: GainStage

    init(_ p: FxParams, _ sampleRate: Double) {
        convolvers = (0..<2).map { channel in
            NonUniformConvolver(impulse: stereoReverbImpulse(
                sampleRate: sampleRate, size: p.num("size"), damping: p.num("damping"),
                width: p.num("width"), channel: channel, preDelay: p.num("preDelay"), lowCut: p.num("lowCut")))
        }
        wet = GainStage(p.num("wet"), sampleRate: sampleRate)
        dry = GainStage(p.num("dry"), sampleRate: sampleRate)
    }

    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        // Graph audio is mono or stereo. A mono input opens into the stereo room.
        guard let first = x.first else { return x }
        for channel in 0..<2 {
            convolvers[channel].process(x[min(channel, x.count - 1)], into: &output[channel])
        }
        let room = output.map { Array($0.prefix(first.count)) }
        let source = x.count == 1 ? [first, first] : x
        return sum(wet.process(room, frame: frame), dry.process(source, frame: frame))
    }

    var automation: [String: [ParamTarget]] {
        ["wet": [ParamTarget(param: wet.gain, map: nil)], "dry": [ParamTarget(param: dry.gain, map: nil)]]
    }
}
