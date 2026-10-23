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

final class ReverbV2Tests: XCTestCase {
    private let sampleRate = 8000.0

    private func params(width: Double = 1, delay: Double = 0, lowCut: Double = 0) -> FxParams {
        var p = AudioFx.defaultParams("reverb-v2")
        p["size"] = .number(0.05); p["wet"] = .number(1); p["dry"] = .number(0)
        p["width"] = .number(width); p["preDelay"] = .number(delay); p["lowCut"] = .number(lowCut)
        return p
    }

    private func impulse(_ p: FxParams) -> [[Float]] {
        let unit = buildFxUnit("reverb-v2", p, sampleRate: sampleRate)
        var result = [[Float](), [Float]()]
        for start in stride(from: 0, to: 8192, by: 128) {
            var input = [Float](repeating: 0, count: 128)
            if start == 0 { input[0] = 1 }
            let out = unit.process([input, input], frame: start)
            for ch in 0..<2 { result[ch] += out[ch] }
        }
        return result
    }

    func testStereoTail() {
        let y = impulse(params())
        let product = zip(y[0], y[1]).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let energies = y.map { $0.reduce(0.0) { $0 + Double($1) * Double($1) } }
        XCTAssertLessThan(abs(product / sqrt(energies[0] * energies[1])), 0.3)
        XCTAssertEqual(energies[0], 1, accuracy: 1e-5)
        XCTAssertEqual(energies[1], 1, accuracy: 1e-5)
    }

    func testZeroWidthGivesIdenticalChannels() {
        let y = impulse(params(width: 0))
        XCTAssertEqual(y[0], y[1])
    }

    func testPreDelayMovesOnlyTheWetSignal() {
        let plain = impulse(params())
        let delayed = impulse(params(delay: 200))
        let frames = 1600
        for ch in 0..<2 {
            XCTAssertTrue(delayed[ch].prefix(frames).allSatisfy { abs($0) < 1e-7 })
            for i in frames..<delayed[ch].count {
                XCTAssertEqual(delayed[ch][i], plain[ch][i - frames], accuracy: 1e-6)
            }
        }
        var dry = params(delay: 200)
        dry["wet"] = .number(0); dry["dry"] = .number(1)
        let y = impulse(dry)
        XCTAssertEqual(y[0][0], 1)
        XCTAssertEqual(y[0].dropFirst().reduce(0, +), 0)
    }

    func testLowCutReducesLowFrequencyEnergy() {
        func lowEnergy(_ y: [Float]) -> Double {
            var state = 0.0, energy = 0.0
            let coefficient = 1 - exp(-2 * Double.pi * 100 / sampleRate)
            for value in y { state += coefficient * (Double(value) - state); energy += state * state }
            return energy
        }
        let plain = impulse(params())[0]
        let filtered = impulse(params(lowCut: 1000))[0]
        XCTAssertLessThan(lowEnergy(filtered), lowEnergy(plain) * 0.2)
    }

    func testNonUniformConvolverIsExactLinearConvolutionAcrossPartitionBoundaries() {
        // Includes an empty IR, partial final partitions, multiple ring wraps and
        // calls shorter than a quantum; no latency or dropped final tail allowed.
        for length in [0, 1, 127, 128, 129, 255, 256, 257, 511, 2049] {
            var seed: UInt32 = 7
            func random() -> Float {
                seed = seed &* 1664525 &+ 1013904223
                return Float(Double(seed) / Double(UInt32.max) - 0.5) * 0.1
            }
            let ir = (0..<length).map { _ in random() }
            let input = (0..<3100).map { _ in random() }
            let signal = input + [Float](repeating: 0, count: max(1, length))
            let convolver = NonUniformConvolver(impulse: ir)
            var actual: [Float] = []
            var at = 0, block = 0
            while at < signal.count {
                let count = min([1, 37, 128, 63][block % 4], signal.count - at)
                var output = [Float](repeating: 0, count: count)
                convolver.process(Array(signal[at..<(at + count)]), into: &output)
                actual += output
                at += count
                block += 1
            }
            var worst = 0.0
            for n in signal.indices {
                var expected = 0.0
                if length > 0 {
                    let first = max(0, n - length + 1), last = min(n, input.count - 1)
                    if first <= last {
                        for k in first...last { expected += Double(input[k]) * Double(ir[n - k]) }
                    }
                }
                worst = max(worst, abs(expected - Double(actual[n])))
            }
            XCTAssertLessThan(worst, 1e-5, "IR length \(length); must be below -100 dB")
        }
    }

    func testVersionTwoRoundTripsWithoutChangingVersionOne() throws {
        let old = #"{"version":1,"nodes":[{"type":"reverb","params":{"size":0.05,"damping":0.5,"wet":1,"dry":0}}]}"#
        let v1 = try AudioFx.parseChain(old)
        XCTAssertEqual(AudioFx.serializeChain(v1), old)
        let node = FxNode(type: "reverb-v2", params: params(width: 0.6, delay: 125, lowCut: 200))
        let encoded = AudioFx.serializeChain(FxChain(nodes: [node]))
        let restored = try AudioFx.parseChain(encoded)
        XCTAssertEqual(restored.nodes.first?.type, "reverb-v2")
        XCTAssertEqual(restored.nodes.first?.params, node.params)
        XCTAssertEqual(AudioFx.serializeChain(restored), encoded)
        XCTAssertEqual(FxTail.chainSeconds(restored), 0.6 + 0.05 * 2.6 + 0.125, accuracy: 1e-9)
        XCTAssertTrue(buildFxUnit("reverb", v1.nodes[0].params, sampleRate: sampleRate) is ReverbUnit)
        XCTAssertTrue(buildFxUnit("reverb-v2", node.params, sampleRate: sampleRate) is ReverbV2Unit)
    }

    func testPlaybackBlocksEqualOfflineExportIncludingTheTail() {
        var source = [Float](repeating: 0, count: 800); source[0] = 1
        let chain = FxChain(nodes: [FxNode(type: "reverb-v2", params: params(delay: 125, lowCut: 200))])
        let project = AudioGraphProject(duration: 1, sampleRate: sampleRate, tracks: [
            AudioGraphTrack(id: "room", stem: [source, source], start: 0, end: 0.1, fxChain: chain),
        ], quantizeIntermediates: false)
        let exported = AudioGraphRenderer.renderOffline(project)
        let playback = AudioGraphRenderer(project)
        var played: [Float] = []
        var block = 0
        while playback.position < playback.totalFrames {
            played += playback.render([1, 37, 128, 333][block % 4])
            block += 1
        }
        XCTAssertEqual(played, exported)
        XCTAssertGreaterThan(exported.dropFirst(2000).map { abs($0) }.max() ?? 0, 0.001)
    }

    func testMonoSourceOpensIntoStereoRoom() {
        let unit = buildFxUnit("reverb-v2", params(), sampleRate: sampleRate)
        var mono = [Float](repeating: 0, count: 128); mono[0] = 1
        let output = unit.process([mono], frame: 0)
        XCTAssertEqual(output.count, 2)
        XCTAssertNotEqual(output[0], output[1])
    }
}
