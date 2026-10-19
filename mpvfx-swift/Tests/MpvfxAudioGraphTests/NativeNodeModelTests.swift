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
import XCTest
@testable import MpvfxAudioGraph

/// The Web Audio native nodes cannot be referenced without Chrome, so these
/// check each model against its analytic definition (documented tolerances).
final class NativeNodeModelTests: XCTestCase {
    let sr = 48000.0

    func run(_ unit: FxUnit, _ x: [Float]) -> [Float] {
        var out: [Float] = []
        var q = 0
        while q < x.count {
            let b = (0..<renderQuantum).map { q + $0 < x.count ? x[q + $0] : 0 }
            out += unit.process([b, b], frame: q)[0]
            q += renderQuantum
        }
        return Array(out.prefix(x.count))
    }

    /// Steady-state gain of a sine through `unit`, in dB.
    func gainDb(_ unit: FxUnit, _ f: Double) -> Double {
        let n = 48000
        let x = (0..<n).map { (i: Int) -> Float in Float(0.25 * sin(2 * Double.pi * f * Double(i) / sr)) }
        let y = run(unit, x)
        func r(_ a: [Float]) -> Double { (a[24000...].reduce(0) { $0 + Double($1) * Double($1) } / 24000).squareRoot() }
        return 20 * log10(r(y) / r(x))
    }

    func testBiquadMagnitudeMatchesRBJ() {
        // |H| from the same coefficients evaluated analytically; tolerance 0.01 dB.
        for (type, fx, params, probes) in [
            (BiquadType.peaking, "peaking", ["frequency": 1000.0, "gain": 6, "q": 1.4], [1000.0, 300, 4000]),
            (.lowshelf, "lowshelf", ["frequency": 200, "gain": -9], [50, 200, 2000]),
            (.highshelf, "highshelf", ["frequency": 4000, "gain": 5], [500, 4000, 15000]),
            (.highpass, "highpass", ["frequency": 300, "q": 3], [100, 300, 3000]),
            (.lowpass, "lowpass", ["frequency": 2000, "q": 0], [500, 2000, 8000]),
        ] {
            var p = FxParams(); for (k, v) in params { p[k] = .number(v) }
            let np = AudioFx.normalize(fx, p)
            let c = BiquadCoefficients.make(type, frequency: np.num("frequency") / (sr / 2), q: np["q"]?.number ?? 1, gain: np["gain"]?.number ?? 0)
            for f in probes {
                let w = 2 * Double.pi * f / sr
                func mag(_ a: Double, _ b: Double, _ c2: Double) -> Double {
                    let re = a + b * cos(-w) + c2 * cos(-2 * w), im = b * sin(-w) + c2 * sin(-2 * w)
                    return (re * re + im * im).squareRoot()
                }
                let expected = 20 * log10(mag(c.b0, c.b1, c.b2) / mag(1, c.a1, c.a2))
                let unit = buildFxUnit(fx, AudioFx.normalize(fx, p), sampleRate: sr)
                XCTAssertEqual(gainDb(unit, f), expected, accuracy: 0.05, "\(fx) @\(f)")
            }
        }
        // Spot values: peaking +6 dB at its centre, shelf -9 dB well below its corner.
        var p = FxParams(); p["frequency"] = .number(1000); p["gain"] = .number(6); p["q"] = .number(1.4)
        XCTAssertEqual(gainDb(buildFxUnit("peaking", p, sampleRate: sr), 1000), 6, accuracy: 0.05)
    }

    func testOnePoleIsMinus3dBAtCutoff() {
        var p = FxParams(); p["frequency"] = .number(1000); p["poles"] = .string("1")
        XCTAssertEqual(gainDb(buildFxUnit("lowpass", p, sampleRate: sr), 1000), -3.01, accuracy: 0.05)
        XCTAssertEqual(gainDb(buildFxUnit("highpass", p, sampleRate: sr), 1000), -3.01, accuracy: 0.05)
    }

    func testFeedbackDelayEchoPositions() {
        // time 10 ms = 480 frames; each recirculation adds one 128-frame quantum (cycle break).
        // delayTime is a Float AudioParam (0.01 -> 0.0099999998), so like Chromium the
        // read lands a hair before frame 480 and interpolates: ~1e-5 leaks into 479.
        var p = FxParams(); p["time"] = .number(10); p["feedback"] = .number(0.5); p["mix"] = .number(1)
        var x = [Float](repeating: 0, count: 4000); x[0] = 1
        let y = run(buildFxUnit("delay", p, sampleRate: sr), x)
        XCTAssertEqual(y[480], 1, accuracy: 1e-4)
        XCTAssertEqual(y[480 + 480 + 128], 0.5, accuracy: 1e-4)
        XCTAssertEqual(y[3 * 480 + 2 * 128], 0.25, accuracy: 1e-4)
        XCTAssertEqual(y.enumerated().filter { abs($0.element) > 1e-3 }.map(\.offset), [480, 1088, 1696, 2304, 2912, 3520])
    }

    func testConvolverIsExactLinearConvolution() {
        let ir = synthesizeReverbImpulse(sampleRate: sr, size: 0.05, damping: 0.5)
        var p = FxParams(); p["size"] = .number(0.05); p["damping"] = .number(0.5); p["wet"] = .number(1); p["dry"] = .number(0)
        var s: UInt32 = 5
        let x: [Float] = (0..<3000).map { _ in s = s &* 1664525 &+ 1013904223; return Float(Double(s) / 4294967296 - 0.5) }
        let y = run(buildFxUnit("reverb", p, sampleRate: sr), x + [Float](repeating: 0, count: 500))
        var worst = 0.0
        for nIdx in stride(from: 0, to: y.count, by: 37) {
            var acc = 0.0
            for k in max(0, nIdx - ir.count + 1)...min(nIdx, x.count - 1) { acc += Double(x[k]) * Double(ir[nIdx - k]) }
            worst = max(worst, abs(acc - Double(y[nIdx])))
        }
        parityLog("convolver vs direct convolution: peak diff \(fmtDb(20 * log10(max(worst, 1e-300))))")
        XCTAssertLessThan(20 * log10(worst), -100)
    }

    func testWaveshaperOversamplingIsTransparentForTinySignals() {
        // In the linear part of the curve, the 2x/4x resamplers must pass the band (< 0.1 dB at 1 kHz).
        for os in [1.0, 2, 4] {
            var p = FxParams(); p["type"] = .string("hard"); p["threshold"] = .number(0); p["oversample"] = .number(os); p["output"] = .number(0)
            XCTAssertEqual(gainDb(buildFxUnit("saturate", p, sampleRate: sr), 1000), 0, accuracy: 0.1, "oversample \(os)")
        }
    }

    func testLfoBufferSourceHasRequestedRateAndPhase() {
        let lfo = LoopingBufferSource.lfo(wave: "sine", speed: 2, elapsed: 0, sampleRate: sr)
        let y = lfo.render(frame: 0, count: 48000)
        XCTAssertEqual(y[6000], 1, accuracy: 1e-4) // quarter cycle of 2 Hz at 0.125 s
        XCTAssertEqual(y[12000], 0, accuracy: 1e-4)
        let shifted = LoopingBufferSource.lfo(wave: "sine", speed: 2, elapsed: 0.125, sampleRate: sr).render(frame: 0, count: 1)
        XCTAssertEqual(shifted[0], 1, accuracy: 1e-4)
    }

    func testParamTimelineMatchesSchedulerOps() {
        let p = ParamTimeline(5, sampleRate: sr)
        p.setValueAtTime(1, 0)
        p.linearRampToValueAtTime(3, 1)
        try! p.setValueCurveAtTime([3, 0, 2], 1, 1)
        XCTAssertEqual(p.valueAt(0.5), 2, accuracy: 1e-6)
        XCTAssertEqual(p.valueAt(1.25), 1.5, accuracy: 1e-6)
        XCTAssertEqual(p.valueAt(1.75), 1, accuracy: 1e-6)
        XCTAssertEqual(p.valueAt(3), 2)
    }
}
