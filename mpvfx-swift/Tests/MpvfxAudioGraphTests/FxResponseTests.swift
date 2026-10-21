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

/// The curves the rack draws are the sound: a filter node's response equals the gain a sine measures through the
/// unit the DSP builds, and a dynamics node's static curve equals the processor's settled output for a steady level.
final class FxResponseTests: XCTestCase {
    let sr = 48000.0

    func node(_ type: String, _ values: [String: Double], poles: String? = nil) -> FxNode {
        var p = FxParams()
        for (k, v) in values { p[k] = .number(v) }
        if let poles { p["poles"] = .string(poles) }
        return FxNode(type: type, id: "x", params: AudioFx.normalize(type, p))
    }

    /// Steady-state gain in dB of a 0.25 sine at `f` through the unit built for `n`.
    func measuredDb(_ n: FxNode, _ f: Double) -> Double {
        let unit = buildFxUnit(n.type, n.params, sampleRate: sr)
        let count = 24000
        var y: [Float] = [], x: [Float] = []
        var q = 0
        while q < count {
            let b = (0..<dspBlockSize).map { (i: Int) -> Float in Float(0.25 * sin(2 * Double.pi * f * Double(q + i) / sr)) }
            x += b; y += unit.process([b, b], frame: q)[0]; q += dspBlockSize
        }
        func rms(_ a: [Float]) -> Double { (a[12000...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count - 12000)).squareRoot() }
        return 20 * log10(rms(y) / rms(x))
    }

    func testFilterResponseIsWhatTheUnitDoes() {
        let nodes = [
            node("peaking", ["frequency": 1000, "gain": 6, "q": 1.4]), node("peaking", ["frequency": 250, "gain": -9, "q": 0.5]),
            node("lowshelf", ["frequency": 200, "gain": -9]), node("highshelf", ["frequency": 4000, "gain": 5]),
            node("highpass", ["frequency": 300, "q": 0.707]), node("lowpass", ["frequency": 2000, "q": 3]),
            node("highpass", ["frequency": 1000], poles: "1"), node("lowpass", ["frequency": 1000], poles: "1"),
        ]
        for n in nodes {
            for f in [60.0, 300, 1000, 3000, 9000] {
                let drawn = AudioFxResponse.gainDb(n, at: f, sampleRate: sr) ?? .nan
                XCTAssertEqual(drawn, measuredDb(n, f), accuracy: 0.05, "\(n.type) \(n.params?.json.json ?? "") at \(f) Hz")
            }
        }
    }

    func testChainResponseSumsTheEnabledFilters() {
        let a = node("peaking", ["frequency": 1000, "gain": 6, "q": 1]), b = node("lowshelf", ["frequency": 200, "gain": -6])
        var off = b; off.enabled = false
        let gain = FxNode(type: "gain", id: "g", params: AudioFx.defaultParams("gain"))
        for f in [100.0, 1000, 5000] {
            let sum = (AudioFxResponse.gainDb(a, at: f) ?? 0) + (AudioFxResponse.gainDb(b, at: f) ?? 0)
            XCTAssertEqual(AudioFxResponse.gainDb([a, b, gain], at: f), sum, accuracy: 1e-12)
            XCTAssertEqual(AudioFxResponse.gainDb([a, off], at: f), AudioFxResponse.gainDb(a, at: f) ?? .nan, accuracy: 1e-12, "bypassed")
        }
        XCTAssertNil(AudioFxResponse.gainDb(gain, at: 1000), "not a filter")
    }

    /// Output level in dB after two seconds of a steady (DC) input at `inputDb` through the processor built for `n`.
    func settledDb(_ n: FxNode, _ inputDb: Double) -> Double {
        let unit = buildFxUnit(n.type, n.params, sampleRate: sr)
        let x = [Float](repeating: Float(pow(10, inputDb / 20)), count: dspBlockSize)
        var last: Float = 0
        for q in stride(from: 0, to: 96000, by: dspBlockSize) { last = unit.process([x, x], frame: q)[0][dspBlockSize - 1] }
        return 20 * log10(Double(last))
    }

    func testDynamicsCurveIsTheProcessorsSettledOutput() {
        let nodes = [
            node("compressor", ["threshold": -24, "ratio": 4, "knee": 2.83, "makeup": 3]),
            node("compressor", ["threshold": -12, "ratio": 20, "knee": 8]),
            node("limiter", ["limit": -6, "level_out": 2]),
            node("gate", ["threshold": -35, "range": -24, "ratio": 10]),
        ]
        for n in nodes {
            for level in [-50.0, -30, -25, -24, -23, -12, -6, -1] {
                let drawn = AudioFxResponse.outputDb(n, inputDb: level) ?? .nan
                XCTAssertEqual(drawn, settledDb(n, level), accuracy: 0.01, "\(n.type) \(n.params?.json.json ?? "") at \(level) dB")
            }
        }
        XCTAssertNil(AudioFxResponse.outputDb(node("delay", [:]), inputDb: -6))
    }
}
