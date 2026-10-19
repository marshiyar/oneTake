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

// The five AudioWorklet-style processors
// (compressor, limiter, gate, bitcrush, pitch shift). Numbers are Double; the I/O and the pitch
// shifter's ring are Float32Array, so those stay Float.

@inline(__always) func dbToLin(_ db: Double) -> Double { pow(10, db / 20) }
// ln 10 as the double M_LN10 holds (spelled out: the Windows C runtime declares M_LN10 only under _USE_MATH_DEFINES).
private let ln10Over20 = 2.302585092994046 / 20
@inline(__always) func dbToLinFast(_ db: Double) -> Double { exp(db * ln10Over20) }

/// Per-channel one-pole envelope followers.
struct EnvBank {
    var a = 0.0, r = 0.0
    var values: [Double] = []
    let sampleRate: Double
    init(_ attackMs: Double, _ releaseMs: Double, sampleRate: Double) { self.sampleRate = sampleRate; set(attackMs, releaseMs) }
    mutating func set(_ attackMs: Double, _ releaseMs: Double) {
        a = exp(-1 / (sampleRate * jsMax(1e-5, attackMs / 1000)))
        r = exp(-1 / (sampleRate * jsMax(1e-5, releaseMs / 1000)))
    }
    @inline(__always) mutating func push(_ ch: Int, _ x: Double) -> Double {
        while values.count <= ch { values.append(0) }
        let prev = values[ch]
        let m = abs(x)
        let c = m > prev ? a : r
        let next = m + c * (prev - m)
        values[ch] = next
        return next
    }
}

func kneeGain(_ envDb: Double, _ thresholdDb: Double, _ ratio: Double, _ kneeDb: Double) -> Double {
    let over = envDb - thresholdDb
    if kneeDb > 0 && over > -kneeDb && over < kneeDb {
        let t = (over + kneeDb) / (2 * kneeDb)
        return -((1 - 1 / ratio) * kneeDb * t * t)
    }
    return over > 0 ? -(over * (1 - 1 / ratio)) : 0
}

/// A processor's `process(inputs, outputs)` for one render quantum.
/// `input` is nil when the worklet input has no channels (nothing connected).
protocol WorkletProcessor: AnyObject {
    func process(_ input: [[Float]], _ output: inout [[Float]])
    func post(_ params: FxParams)
}

final class HfCompressor: WorkletProcessor {
    var p: FxParams
    var env: EnvBank
    init(_ p: FxParams, sampleRate: Double) {
        self.p = p
        env = EnvBank(p["attack"]?.number ?? 20, p["release"]?.number ?? 250, sampleRate: sampleRate)
    }
    func post(_ params: FxParams) { for (k, v) in params.entries { p[k] = v }; env.set(p["attack"]?.number ?? 20, p["release"]?.number ?? 250) }
    func process(_ i: [[Float]], _ o: inout [[Float]]) {
        if i.isEmpty { return }
        let makeup = dbToLin(p["makeup"]?.number ?? 0)
        let mix = p["mix"]?.number ?? 1
        let kneeDb = 20 * log10(jsMax(1.0001, p["knee"]?.number ?? 2.83))
        let thresholdDb = p["threshold"]?.number ?? -24
        let ratio = p["ratio"]?.number ?? 4
        let kneeStartLin = dbToLin(thresholdDb - kneeDb)
        let dry = 1 - mix
        for ch in 0..<i.count {
            let inp = i[ch]
            for n in 0..<inp.count {
                let x = Double(inp[n])
                let e = env.push(ch, x)
                if e <= kneeStartLin { o[ch][n] = Float(x * makeup * mix + x * dry); continue }
                let envDb = 20 * log10(e)
                let g = dbToLinFast(kneeGain(envDb, thresholdDb, ratio, kneeDb))
                o[ch][n] = Float(x * g * makeup * mix + x * dry)
            }
        }
    }
}

final class HfLimiter: WorkletProcessor {
    var p: FxParams
    var env: EnvBank
    init(_ p: FxParams, sampleRate: Double) {
        self.p = p
        env = EnvBank(p["attack"]?.number ?? 5, p["release"]?.number ?? 50, sampleRate: sampleRate)
    }
    func post(_ params: FxParams) { for (k, v) in params.entries { p[k] = v }; env.set(p["attack"]?.number ?? 5, p["release"]?.number ?? 50) }
    func process(_ i: [[Float]], _ o: inout [[Float]]) {
        if i.isEmpty { return }
        let ceiling = dbToLin(p["limit"]?.number ?? -1)
        let outGain = dbToLin(p["level_out"]?.number ?? 0)
        for ch in 0..<i.count {
            let inp = i[ch]
            for n in 0..<inp.count {
                let x = Double(inp[n])
                let e = env.push(ch, x)
                let g = e > ceiling ? ceiling / e : 1
                o[ch][n] = Float(x * g * outGain)
            }
        }
    }
}

final class HfGate: WorkletProcessor {
    var p: FxParams
    var env: EnvBank
    var gains: [Double] = []
    init(_ p: FxParams, sampleRate: Double) {
        self.p = p
        env = EnvBank(p["attack"]?.number ?? 1, p["release"]?.number ?? 100, sampleRate: sampleRate)
    }
    func post(_ params: FxParams) { for (k, v) in params.entries { p[k] = v }; env.set(p["attack"]?.number ?? 1, p["release"]?.number ?? 100) }
    func process(_ i: [[Float]], _ o: inout [[Float]]) {
        if i.isEmpty { return }
        let threshold = dbToLin(p["threshold"]?.number ?? -35)
        let floor = dbToLin(p["range"]?.number ?? -24)
        let ratio = p["ratio"]?.number ?? 10
        let kneeDb = 20 * log10(jsMax(1.0001, p["knee"]?.number ?? 2.83))
        _ = dbToLin((p["threshold"]?.number ?? -35) + kneeDb) // computed and unused, kept so the processor matches its reference output
        while gains.count < i.count { gains.append(1) }
        for ch in 0..<i.count {
            let inp = i[ch]
            for n in 0..<inp.count {
                let x = Double(inp[n])
                let e = env.push(ch, x)
                var target = 1.0
                if e < threshold {
                    let under = e > 1e-9 ? threshold / e : 1e9
                    target = jsMax(floor, 1 / pow(under, ratio - 1))
                    if !target.isFinite { target = floor }
                }
                let held = gains[ch]
                let c = target < held ? env.r : env.a
                let smoothed = target + c * (held - target)
                gains[ch] = smoothed
                o[ch][n] = Float(x * smoothed)
            }
        }
    }
}

final class HfBitcrush: WorkletProcessor {
    var p: FxParams
    var holds: [Int] = []
    var held: [Double] = []
    init(_ p: FxParams) { self.p = p }
    func post(_ params: FxParams) { for (k, v) in params.entries { p[k] = v } }
    func process(_ i: [[Float]], _ o: inout [[Float]]) {
        if i.isEmpty { return }
        let levels = pow(2, (p["bits"]?.number ?? 8) - 1)
        let step = max(1, Int(jsMathRound(p["samples"]?.number ?? 1)))
        let mix = p["mix"]?.number ?? 1
        while held.count < i.count { held.append(0); holds.append(0) }
        for ch in 0..<i.count {
            let inp = i[ch]
            for n in 0..<inp.count {
                let x = Double(inp[n])
                if holds[ch] == 0 { held[ch] = jsMathRound(x * levels) / levels }
                o[ch][n] = Float(held[ch] * mix + x * (1 - mix))
                holds[ch] = (holds[ch] + 1) % step
            }
        }
    }
}

final class HfPitchshift: WorkletProcessor {
    var p: FxParams
    let grain: Int
    var buf: [[Float]] = []
    var write = 0
    var phase = 0.0
    var filled = 0
    var wet = 0.0
    var wetTarget = 0.0
    let wetCoef: Double
    init(_ p: FxParams, sampleRate: Double) {
        self.p = p
        grain = Int(jsMathRound(sampleRate * 0.1))
        wetCoef = exp(-1 / (sampleRate * 0.015))
    }
    func post(_ params: FxParams) { for (k, v) in params.entries { p[k] = v } }

    @inline(__always) static func readTap(_ ring: [Float], _ write: Int, _ delaySamples: Double) -> Double {
        let len = ring.count
        // JS `%` keeps the dividend's sign; the operand here is always > 0.
        let pos = (Double(write) - 1 - delaySamples + Double(len)).truncatingRemainder(dividingBy: Double(len))
        let i0 = Int(pos.rounded(.down))
        let frac = pos - Double(i0)
        let i1 = (i0 + 1) % len
        return Double(ring[i0]) * (1 - frac) + Double(ring[i1]) * frac
    }

    func process(_ i: [[Float]], _ o: inout [[Float]]) {
        if i.isEmpty { return }
        let semitones = max(-12, min(12, p["semitones"]?.number ?? 0))
        let mix = max(0, min(1, p["mix"]?.number ?? 1))
        let ringLen = grain * 2
        let n = i[0].count
        while buf.count < i.count { buf.append([Float](repeating: 0, count: ringLen)) }
        wetTarget = semitones == 0 ? 0 : mix
        if wetTarget == 0 && wet < 1e-4 {
            wet = 0
            var w = write
            for s in 0..<n {
                for ch in 0..<i.count { let x = i[ch][s]; buf[ch][w] = x; o[ch][s] = x }
                w = (w + 1) % ringLen
            }
            write = w
            filled = min(grain, filled + n)
            return
        }
        let ratio = pow(2, semitones / 12)
        let inc = (1 - ratio) / Double(grain)
        var write = self.write, phase = self.phase, filled = self.filled, wetNow = self.wet
        let target = wetTarget, coef = wetCoef
        for s in 0..<n {
            phase += inc
            phase -= phase.rounded(.down)
            let phaseB = (phase + 0.5).truncatingRemainder(dividingBy: 1)
            let gA = sin(Double.pi * phase), gB = sin(Double.pi * phaseB)
            let warm = filled >= grain ? 1 : Double(filled) / Double(grain)
            wetNow = target + coef * (wetNow - target)
            let wetMix = wetNow * warm
            for ch in 0..<i.count {
                let x = i[ch][s]
                buf[ch][write] = x
                let ring = buf[ch]
                let w = HfPitchshift.readTap(ring, write, phase * Double(grain)) * gA + HfPitchshift.readTap(ring, write, phaseB * Double(grain)) * gB
                o[ch][s] = Float(Double(x) * (1 - wetMix) + w * wetMix)
            }
            write = (write + 1) % ringLen
            if filled < grain { filled += 1 }
        }
        self.write = write; self.phase = phase; self.filled = filled; self.wet = wetNow
    }
}
