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

// Native DSP primitives used by the FX graph builders. Their algorithms follow
// the Web Audio API and Chromium's implementation structure (biquad.cc,
// delay_dsp_kernel.cc, audio_buffer_source_node.cc, wave_shaper_dsp_kernel.cc,
// up_sampler.cc / down_sampler.cc, reverb.cc). Samples between nodes are Float;
// filter state is Double, as in Chromium.

public let dspBlockSize = 128

// MARK: Biquad

public enum BiquadType: Sendable { case lowpass, highpass, peaking, lowshelf, highshelf, allpass }

struct BiquadCoefficients: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    static func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        let inv = 1 / a0
        return BiquadCoefficients(b0: b0 * inv, b1: b1 * inv, b2: b2 * inv, a1: a1 * inv, a2: a2 * inv)
    }

    /// `frequency` normalised to Nyquist (0...1); `q` linear or dB per type; `gain` in dB.
    static func make(_ type: BiquadType, frequency: Double, q: Double, gain: Double, linearPassQ: Bool = false) -> BiquadCoefficients {
        let f = min(1, max(0, frequency))
        switch type {
        case .lowpass:
            if f == 1 { return normalized(1, 0, 0, 1, 0, 0) }
            if f > 0 {
                let resonance = linearPassQ ? max(0.0001, q) : pow(10, q / 20)
                let theta = Double.pi * f
                let alpha = sin(theta) / (2 * resonance)
                let cosw = cos(theta), beta = (1 - cosw) / 2
                return normalized(beta, 2 * beta, beta, 1 + alpha, -2 * cosw, 1 - alpha)
            }
            return normalized(0, 0, 0, 1, 0, 0)
        case .highpass:
            if f == 1 { return normalized(0, 0, 0, 1, 0, 0) }
            if f > 0 {
                let resonance = linearPassQ ? max(0.0001, q) : pow(10, q / 20)
                let theta = Double.pi * f
                let alpha = sin(theta) / (2 * resonance)
                let cosw = cos(theta), beta = (1 + cosw) / 2
                return normalized(beta, -2 * beta, beta, 1 + alpha, -2 * cosw, 1 - alpha)
            }
            return normalized(1, 0, 0, 1, 0, 0)
        case .lowshelf, .highshelf:
            let a = pow(10, gain / 40)
            if f == 1 { return type == .lowshelf ? normalized(a * a, 0, 0, 1, 0, 0) : normalized(1, 0, 0, 1, 0, 0) }
            if f > 0 {
                let w0 = Double.pi * f
                let s = 1.0
                let alpha = 0.5 * sin(w0) * ((a + 1 / a) * (1 / s - 1) + 2).squareRoot()
                let k = cos(w0), k2 = 2 * a.squareRoot() * alpha
                let ap1 = a + 1, am1 = a - 1
                if type == .lowshelf {
                    return normalized(a * (ap1 - am1 * k + k2), 2 * a * (am1 - ap1 * k), a * (ap1 - am1 * k - k2),
                                      ap1 + am1 * k + k2, -2 * (am1 + ap1 * k), ap1 + am1 * k - k2)
                }
                return normalized(a * (ap1 + am1 * k + k2), -2 * a * (am1 + ap1 * k), a * (ap1 + am1 * k - k2),
                                  ap1 - am1 * k + k2, 2 * (am1 - ap1 * k), ap1 - am1 * k - k2)
            }
            return type == .lowshelf ? normalized(1, 0, 0, 1, 0, 0) : normalized(a * a, 0, 0, 1, 0, 0)
        case .peaking:
            let qq = max(0, q)
            let a = pow(10, gain / 40)
            if f > 0 && f < 1 {
                if qq > 0 {
                    let w0 = Double.pi * f, alpha = sin(w0) / (2 * qq), k = cos(w0)
                    return normalized(1 + alpha * a, -2 * k, 1 - alpha * a, 1 + alpha / a, -2 * k, 1 - alpha / a)
                }
                return normalized(a * a, 0, 0, 1, 0, 0)
            }
            return normalized(1, 0, 0, 1, 0, 0)
        case .allpass:
            let qq = max(0, q)
            if f > 0 && f < 1 {
                if qq > 0 {
                    let w0 = Double.pi * f, alpha = sin(w0) / (2 * qq), k = cos(w0)
                    return normalized(1 - alpha, -2 * k, 1 + alpha, 1 + alpha, -2 * k, 1 - alpha)
                }
                return normalized(-1, 0, 0, 1, 0, 0)
            }
            return normalized(1, 0, 0, 1, 0, 0)
        }
    }
}

/// Per-channel Direct Form I biquad in Double, with audio-rate frequency/Q/gain.
final class BiquadFilter {
    let type: BiquadType
    let linearPassQ: Bool
    let frequency: ParamTimeline, q: ParamTimeline, gain: ParamTimeline
    /// Audio-rate signal summed into `frequency` (the phaser's LFO), mono.
    var frequencyInput: [Float]? = nil
    let nyquist: Double
    var state: [(x1: Double, x2: Double, y1: Double, y2: Double)] = []
    private var cachedKey: (Float, Float, Float) = (.nan, .nan, .nan)
    private var cached = BiquadCoefficients()
    private var fBuf = [Float](repeating: 0, count: dspBlockSize), qBuf = [Float](repeating: 0, count: dspBlockSize), gBuf = [Float](repeating: 0, count: dspBlockSize)

    init(_ type: BiquadType, sampleRate: Double, frequency: Double = 350, q: Double = 1, gain: Double = 0, linearPassQ: Bool = false) {
        self.type = type
        self.linearPassQ = linearPassQ
        nyquist = sampleRate / 2
        self.frequency = ParamTimeline(Float(frequency), sampleRate: sampleRate)
        self.q = ParamTimeline(Float(q), sampleRate: sampleRate)
        self.gain = ParamTimeline(Float(gain), sampleRate: sampleRate)
    }

    private func coefficients(_ f: Float, _ q: Float, _ g: Float) -> BiquadCoefficients {
        if f == cachedKey.0 && q == cachedKey.1 && g == cachedKey.2 { return cached }
        cachedKey = (f, q, g)
        cached = BiquadCoefficients.make(type, frequency: Double(f) / nyquist, q: Double(q), gain: Double(g), linearPassQ: linearPassQ)
        return cached
    }

    func process(_ input: [[Float]], frame: Int) -> [[Float]] {
        let n = input.first?.count ?? 0
        while state.count < input.count { state.append((0, 0, 0, 0)) }
        frequency.fill(frame: frame, count: n, into: &fBuf)
        q.fill(frame: frame, count: n, into: &qBuf)
        gain.fill(frame: frame, count: n, into: &gBuf)
        if let fi = frequencyInput {
            for k in 0..<n { fBuf[k] = min(Float(nyquist), max(0, fBuf[k] + fi[k])) }
        } else {
            for k in 0..<n { fBuf[k] = min(Float(nyquist), max(0, fBuf[k])) }
        }
        var out = input
        for ch in 0..<input.count {
            var (x1, x2, y1, y2) = state[ch]
            let src = input[ch]
            for k in 0..<n {
                let c = coefficients(fBuf[k], qBuf[k], gBuf[k])
                let x = Double(src[k])
                let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                out[ch][k] = Float(y)
                x2 = x1; x1 = x; y2 = y1; y1 = y
            }
            // Chromium flushes a decaying tail that has gone subnormal on silent input.
            if x1 == 0 && x2 == 0 && (y1 != 0 || y2 != 0) && abs(y1) < Double(Float.leastNormalMagnitude) && abs(y2) < Double(Float.leastNormalMagnitude) { y1 = 0; y2 = 0 }
            state[ch] = (x1, x2, y1, y2)
        }
        return out
    }
}

/// Fixed-coefficient IIR filter in Double, used for one-pole high/low-pass.
final class IIRFilter {
    let ff: [Double], fb: [Double]
    var xs: [[Double]] = [], ys: [[Double]] = []
    init(feedforward: [Double], feedback: [Double]) {
        let a0 = feedback[0]
        ff = feedforward.map { $0 / a0 }
        fb = feedback.map { $0 / a0 }
    }
    func process(_ input: [[Float]]) -> [[Float]] {
        while xs.count < input.count { xs.append([Double](repeating: 0, count: ff.count)); ys.append([Double](repeating: 0, count: fb.count)) }
        var out = input
        for ch in 0..<input.count {
            for k in 0..<input[ch].count {
                let x = Double(input[ch][k])
                var y = ff[0] * x
                for j in 1..<ff.count { y += ff[j] * xs[ch][j - 1] }
                for j in 1..<fb.count { y -= fb[j] * ys[ch][j - 1] }
                if ff.count > 1 { for j in stride(from: ff.count - 2, to: 0, by: -1) { xs[ch][j] = xs[ch][j - 1] }; xs[ch][0] = x }
                if fb.count > 1 { for j in stride(from: fb.count - 2, to: 0, by: -1) { ys[ch][j] = ys[ch][j - 1] }; ys[ch][0] = y }
                out[ch][k] = Float(y)
            }
        }
        return out
    }
}

// MARK: Gain

final class GainStage {
    let gain: ParamTimeline
    private var buf = [Float](repeating: 0, count: dspBlockSize)
    init(_ value: Double, sampleRate: Double) { gain = ParamTimeline(Float(value), sampleRate: sampleRate) }
    func process(_ input: [[Float]], frame: Int) -> [[Float]] {
        let n = input.first?.count ?? 0
        if gain.isConstant {
            gain.noteConstantRead()
            let g = gain.value
            if g == 1 { return input }
            return input.map { $0.map { $0 * g } }
        }
        gain.fill(frame: frame, count: n, into: &buf)
        var out = input
        for ch in 0..<input.count { for k in 0..<n { out[ch][k] = input[ch][k] * buf[k] } }
        return out
    }
}

/// `x` with every NaN or infinite sample replaced by 0 (the same planes when all are finite).
func finiteSamples(_ x: [[Float]]) -> [[Float]] {
    guard x.contains(where: { $0.contains { !$0.isFinite } }) else { return x }
    return x.map { $0.map { $0.isFinite ? $0 : 0 } }
}

@inline(__always) func sum(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
    var out = a
    for ch in 0..<min(a.count, b.count) { for k in 0..<a[ch].count { out[ch][k] = a[ch][k] + b[ch][k] } }
    return out
}

// MARK: Delay

/// Circular delay line using write-then-read and linear interpolation (Chromium AudioDelayDSPKernel).
final class DelayLine {
    var buffer: [Float]
    var writeIndex = 0
    let sampleRate: Double
    let maxDelay: Double
    init(maxDelay: Double, sampleRate: Double) {
        self.maxDelay = maxDelay
        self.sampleRate = sampleRate
        buffer = [Float](repeating: 0, count: Int((maxDelay * sampleRate).rounded(.up)) + 1 + dspBlockSize)
    }
    /// `delaySeconds[k]` is the computed delayTime for frame k.
    func process(_ input: [Float], _ delaySeconds: [Float]) -> [Float] {
        let len = buffer.count
        var out = input
        let start = writeIndex
        for k in 0..<input.count { buffer[(start + k) % len] = input[k] }
        for k in 0..<input.count {
            let d = Double(min(Float(maxDelay), max(0, delaySeconds[k]))) * sampleRate
            var readPosition = Double(start + k) - d
            if readPosition < 0 { readPosition += Double(len) }
            let i1 = Int(readPosition) % len
            let i2 = (i1 + 1) % len
            let frac = readPosition - readPosition.rounded(.down)
            out[k] = Float((1 - frac) * Double(buffer[i1]) + frac * Double(buffer[i2]))
        }
        writeIndex = (start + input.count) % len
        return out
    }
}

// MARK: Looping buffer source (LFO)

/// Looping one-second wavetable oscillator with block-rate playback speed.
final class LoopingBufferSource {
    let cycle: [Float]
    let playbackRate: ParamTimeline
    var virtualReadIndex: Double
    init(cycle: [Float], speed: Double, offsetFrames: Double, sampleRate: Double) {
        self.cycle = cycle
        playbackRate = ParamTimeline(Float(speed), sampleRate: sampleRate)
        virtualReadIndex = offsetFrames
    }
    func render(frame: Int, count: Int) -> [Float] {
        let rate = Double(playbackRate.valueAt(Double(frame) / playbackRate.sampleRate))
        let length = cycle.count
        var out = [Float](repeating: 0, count: count)
        for k in 0..<count {
            let readIndex = Int(virtualReadIndex)
            let factor = virtualReadIndex - Double(readIndex)
            var readIndex2 = readIndex + 1
            if readIndex2 >= length { readIndex2 -= length }
            let s1 = Double(cycle[min(readIndex, length - 1)]), s2 = Double(cycle[readIndex2])
            out[k] = Float((1 - factor) * s1 + factor * s2)
            virtualReadIndex += rate
            if virtualReadIndex >= Double(length) { virtualReadIndex -= Double(length) }
            if virtualReadIndex < 0 { virtualReadIndex += Double(length) }
        }
        return out
    }

    /// `lfoSource`.
    static func lfo(wave: String, speed: Double, elapsed: Double, sampleRate: Double) -> LoopingBufferSource {
        let length = max(1, Int(jsMathRound(sampleRate)))
        let cycle: [Float] = (0..<length).map { i in
            let phase = Double(i) / Double(length)
            if wave == "sine" { return Float(sin(2 * Double.pi * phase)) }
            return Float(4 * abs((phase + 0.75).truncatingRemainder(dividingBy: 1) - 0.5) - 1)
        }
        let offset = ((((elapsed * speed).truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)) * (Double(length) / sampleRate)
        return LoopingBufferSource(cycle: cycle, speed: speed, offsetFrames: offset * sampleRate, sampleRate: sampleRate)
    }
}

// MARK: WaveShaper

/// Chromium DirectConvolver: y[n] = Σ h[k]·x[n−k], Float accumulation.
struct DirectConvolver {
    let kernel: [Float]
    var history: [Float]
    init(_ kernel: [Float]) { self.kernel = kernel; history = [Float](repeating: 0, count: kernel.count) }
    mutating func process(_ x: [Float]) -> [Float] {
        let k = kernel.count
        let buf = history + x
        var out = [Float](repeating: 0, count: x.count)
        for n in 0..<x.count {
            var s: Float = 0
            let base = n + k
            for j in 0..<k { s += kernel[j] * buf[base - j] }
            out[n] = s
        }
        history = Array(buf.suffix(k))
        return out
    }
}

private func blackman(_ x: Double) -> Double {
    let alpha = 0.16, a0 = 0.5 * (1 - alpha), a1 = 0.5, a2 = 0.5 * alpha
    return a0 - a1 * cos(2 * Double.pi * x) + a2 * cos(2 * Double.pi * 2 * x)
}

/// Chromium UpSampler (2x, 128-tap half-sample-offset sinc).
struct UpSampler {
    static let kernelSize = 128
    var convolver: DirectConvolver
    var input: [Float]
    init() {
        let n = UpSampler.kernelSize, half = n / 2, offset = -0.5
        let kernel: [Float] = (0..<n).map { i in
            let s = Double.pi * (Double(i - half) - offset)
            let sinc = s == 0 ? 1 : sin(s) / s
            return Float(sinc * blackman((Double(i) - offset) / Double(n)))
        }
        convolver = DirectConvolver(kernel)
        input = [Float](repeating: 0, count: UpSampler.kernelSize / 2)
    }
    mutating func process(_ source: [Float]) -> [Float] {
        let half = UpSampler.kernelSize / 2
        let buf = input + source
        let odd = convolver.process(source)
        var dest = [Float](repeating: 0, count: source.count * 2)
        for i in 0..<source.count { dest[i * 2] = buf[i]; dest[i * 2 + 1] = odd[i] }
        input = Array(buf.suffix(half))
        return dest
    }
}

/// Chromium DownSampler (2x, 256-tap half-band, odd-tap reduced kernel).
struct DownSampler {
    static let kernelSize = 256
    var convolver: DirectConvolver
    var input: [Float]
    init() {
        let n = DownSampler.kernelSize, half = n / 2
        var reduced = [Float](repeating: 0, count: n / 2)
        var i = 1
        while i < n {
            let s = 0.5 * Double.pi * Double(i - half)
            var sinc = s == 0 ? 1 : sin(s) / s
            sinc *= 0.5
            reduced[(i - 1) / 2] = Float(sinc * blackman(Double(i) / Double(n)))
            i += 2
        }
        convolver = DirectConvolver(reduced)
        input = [Float](repeating: 0, count: DownSampler.kernelSize / 2)
    }
    mutating func process(_ source: [Float]) -> [Float] {
        let half = DownSampler.kernelSize / 2
        let destFrames = source.count / 2
        let buf = input + source // input_p == buf[half...]
        let odd: [Float] = (0..<destFrames).map { buf[half - 1 + $0 * 2] }
        var dest = convolver.process(odd)
        for i in 0..<destFrames { dest[i] += 0.5 * buf[i * 2] }
        input = Array(buf.suffix(half))
        return dest
    }
}

final class WaveShaper {
    var curve: [Float] = []
    var oversample = 1
    private var up1: [UpSampler] = [], up2: [UpSampler] = [], down1: [DownSampler] = [], down2: [DownSampler] = []

    func shape(_ x: [Float]) -> [Float] {
        let n = curve.count
        if n == 0 { return x }
        return x.map { input in
            let v = 0.5 * (Double(input) + 1) * Double(n - 1)
            if v < 0 { return curve[0] }
            if v >= Double(n - 1) { return curve[n - 1] }
            let i1 = Int(v), f = v - Double(i1)
            return Float((1 - f) * Double(curve[i1]) + f * Double(curve[i1 + 1]))
        }
    }

    func process(_ input: [[Float]]) -> [[Float]] {
        while up1.count < input.count { up1.append(UpSampler()); up2.append(UpSampler()); down1.append(DownSampler()); down2.append(DownSampler()) }
        return input.enumerated().map { ch, x in
            switch oversample {
            case 2: return down1[ch].process(shape(up1[ch].process(x)))
            case 4: return down1[ch].process(down2[ch].process(shape(up2[ch].process(up1[ch].process(x)))))
            default: return shape(x)
            }
        }
    }
}

// MARK: Convolver

/// FFTConvolver with `normalize = false`: exact linear convolution (uniformly
/// partitioned FFT, 128-frame partitions, Double precision), zero latency.
final class FFTConvolver {
    let partitions: [[(Double, Double)]] // spectrum per IR partition (FFT size 256)
    var inputSpectra: [[[(Double, Double)]]] = [] // per channel: ring of past input-block spectra
    var ringIndex = 0
    var overlap: [[Double]] = []
    static let block = dspBlockSize
    static let fftSize = 2 * dspBlockSize

    init(impulse: [Float]) {
        var parts: [[(Double, Double)]] = []
        var at = 0
        while at < impulse.count {
            var re = [Double](repeating: 0, count: FFTConvolver.fftSize), im = re
            for k in 0..<min(FFTConvolver.block, impulse.count - at) { re[k] = Double(impulse[at + k]) }
            AudioCarve.fft(&re, &im)
            parts.append((0..<FFTConvolver.fftSize).map { (re[$0], im[$0]) })
            at += FFTConvolver.block
        }
        partitions = parts
    }

    func process(_ input: [[Float]]) -> [[Float]] {
        let size = FFTConvolver.fftSize, blk = FFTConvolver.block
        let pcount = partitions.count
        while inputSpectra.count < input.count {
            inputSpectra.append([[(Double, Double)]](repeating: [(Double, Double)](repeating: (0, 0), count: size), count: max(1, pcount)))
            overlap.append([Double](repeating: 0, count: blk))
        }
        var out = input
        let slot = ringIndex
        for ch in 0..<input.count {
            var re = [Double](repeating: 0, count: size), im = re
            for k in 0..<input[ch].count { re[k] = Double(input[ch][k]) }
            AudioCarve.fft(&re, &im)
            inputSpectra[ch][slot] = (0..<size).map { (re[$0], im[$0]) }
            var accRe = [Double](repeating: 0, count: size), accIm = accRe
            for p in 0..<pcount {
                let x = inputSpectra[ch][(slot - p + pcount) % pcount]
                let h = partitions[p]
                for k in 0..<size {
                    accRe[k] += x[k].0 * h[k].0 - x[k].1 * h[k].1
                    accIm[k] += x[k].0 * h[k].1 + x[k].1 * h[k].0
                }
            }
            // Inverse FFT via conjugation.
            for k in 0..<size { accIm[k] = -accIm[k] }
            AudioCarve.fft(&accRe, &accIm)
            let scale = 1 / Double(size)
            for k in 0..<input[ch].count { out[ch][k] = Float(accRe[k] * scale + overlap[ch][k]) }
            for k in 0..<blk { overlap[ch][k] = accRe[blk + k] * scale }
        }
        ringIndex = pcount > 0 ? (ringIndex + 1) % pcount : 0
        return out
    }
}

/// `synthesizeReverbImpulse`, bit-exact with the recorded reference impulses.
public func synthesizeReverbImpulse(sampleRate: Double, size: Double, damping: Double) -> [Float] {
    let seconds = 0.6 + max(0, min(1, size)) * 2.6
    let length = max(1, Int((sampleRate * seconds).rounded(.down)))
    var out = [Float](repeating: 0, count: length)
    // (Math.round(size*1000) * 2654435761 + Math.round(damping*1000) * 40503) >>> 0
    let a = jsMathRound(size * 1000) * 2654435761 + jsMathRound(damping * 1000) * 40503
    var seed = toUint32(a)
    func rand() -> Double {
        seed = toUint32(Double(seed) * 1664525 + 1013904223)
        return (Double(seed) / 0xffffffff) * 2 - 1
    }
    let cutoff = max(0.001, 1 - max(0, min(1, damping)))
    var lp = 0.0, energy = 0.0
    for i in 0..<length {
        lp += cutoff * (rand() - lp)
        let sample = lp * pow(1 - Double(i) / Double(length), 2.5)
        out[i] = Float(sample)
        energy += sample * sample
    }
    let norm = energy.squareRoot()
    if norm > 0 { for i in 0..<length { out[i] = Float(Double(out[i]) / norm) } }
    return out
}

/// ECMAScript ToUint32 of a Number.
func toUint32(_ x: Double) -> UInt32 {
    guard x.isFinite else { return 0 }
    let t = x.rounded(.towardZero)
    let m = t.truncatingRemainder(dividingBy: 4294967296)
    return UInt32(m < 0 ? m + 4294967296 : m)
}
