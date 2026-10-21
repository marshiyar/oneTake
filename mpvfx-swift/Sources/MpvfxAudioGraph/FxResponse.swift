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

/// What the rack draws: the frequency response of a chain's filter nodes and the static input/output curve of its
/// dynamics nodes, computed from the same coefficients and gain law the DSP runs (`BiquadCoefficients.make`, the
/// one-pole `OnePoleUnit` coefficients, `kneeGain`), so the curve is the sound and not an illustration of it.
public enum AudioFxResponse {
    /// Node types with a frequency response.
    public static let filterTypes: Set<String> = ["peaking", "lowshelf", "highshelf", "highpass", "lowpass"]
    /// Node types with a static input/output level curve.
    public static let dynamicsTypes: Set<String> = ["compressor", "limiter", "gate"]

    /// Gain in dB of one filter node at `frequency` Hz (nil: not a filter type).
    public static func gainDb(_ node: FxNode, at frequency: Double, sampleRate: Double = 48_000) -> Double? {
        guard filterTypes.contains(node.type) else { return nil }
        let p = AudioFx.normalize(node.type, node.params)
        let w = 2 * Double.pi * frequency / sampleRate
        let (b, a) = coefficients(node.type, p, sampleRate: sampleRate)
        return 20 * log10(max(1e-12, magnitude(b, w) / max(1e-300, magnitude(a, w))))
    }

    /// Gain in dB at `frequency` of every enabled filter node in `nodes`, in series.
    public static func gainDb(_ nodes: [FxNode], at frequency: Double, sampleRate: Double = 48_000) -> Double {
        nodes.filter { $0.enabled != false }.reduce(0) { $0 + (gainDb($1, at: frequency, sampleRate: sampleRate) ?? 0) }
    }

    /// Feedforward and feedback coefficients (a0 = 1) as the filter units build them.
    static func coefficients(_ type: String, _ p: FxParams, sampleRate sr: Double) -> (b: [Double], a: [Double]) {
        let f = p.num("frequency")
        if (type == "highpass" || type == "lowpass") && p["poles"]?.string == "1" {
            let k = tan(Double.pi * f / sr), g = type == "highpass" ? 1 / (1 + k) : k / (1 + k)
            return (type == "highpass" ? [g, -g] : [g, g], [1, (k - 1) / (k + 1)])
        }
        let kind: BiquadType = ["peaking": .peaking, "lowshelf": .lowshelf, "highshelf": .highshelf, "highpass": .highpass][type] ?? .lowpass
        // BiquadUnit leaves Q at the filter's own default (1) for the shelves, which have no Q knob.
        // The filter's parameters are Float, so the coefficients are made from the Float-rounded values.
        let c = BiquadCoefficients.make(kind, frequency: Double(Float(f)) / (sr / 2), q: Double(Float(p["q"]?.number ?? 1)),
                                        gain: Double(Float(p["gain"]?.number ?? 0)))
        return ([c.b0, c.b1, c.b2], [1, c.a1, c.a2])
    }

    /// |Σ c_k e^{-jkw}|.
    static func magnitude(_ c: [Double], _ w: Double) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in c.enumerated() { re += v * cos(Double(k) * w); im -= v * sin(Double(k) * w) }
        return (re * re + im * im).squareRoot()
    }

    /// Steady-state output level in dB of a dynamics node for a steady input level `inputDb` (the level its envelope
    /// follower settles on), before any mix with the dry signal; nil when `node` is not a dynamics type.
    public static func outputDb(_ node: FxNode, inputDb x: Double) -> Double? {
        let p = AudioFx.normalize(node.type, node.params)
        switch node.type {
        case "compressor":
            let knee = 20 * log10(jsMax(1.0001, p.num("knee")))
            return x + kneeGain(x, p.num("threshold"), p.num("ratio"), knee) + p.num("makeup")
        case "limiter":
            return min(x, p.num("limit")) + p.num("level_out")
        case "gate":
            let threshold = p.num("threshold")
            guard x < threshold else { return x }
            return x + max(p.num("range"), -(threshold - x) * (p.num("ratio") - 1))
        default:
            return nil
        }
    }
}
