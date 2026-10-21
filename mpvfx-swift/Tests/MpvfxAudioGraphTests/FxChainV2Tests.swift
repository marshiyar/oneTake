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

final class FxChainV2Tests: XCTestCase {
    func render(_ chain: FxChain, _ input: [[Float]]) -> [[Float]] {
        let processor = FxChainProcessor(chain)
        var out = input.map { _ in [Float]() }
        for frame in stride(from: 0, to: input[0].count, by: dspBlockSize) {
            let end = min(input[0].count, frame + dspBlockSize)
            let y = processor.process(input.map { Array($0[frame..<end]) }, frame: frame)
            for ch in out.indices { out[ch] += y[ch] }
        }
        return out
    }

    func testPassFilterQIsLinear() {
        let frequency = 300.0
        let sine = (0..<48000).map { Float(sin(2 * Double.pi * frequency * Double($0) / 48000)) }
        for type in ["highpass", "lowpass"] {
            for q in [0.707, 2.0] {
                let chain = FxChain(nodes: [FxNode(type: type, params: FxParams([("frequency", .number(frequency)), ("q", .number(q))]))])
                let out = render(chain, [sine])[0]
                let energy = out.suffix(24000).reduce(0.0) { $0 + Double($1) * Double($1) }
                XCTAssertEqual(10 * log10(energy / 12000), 20 * log10(q), accuracy: 0.05, type)
                XCTAssertEqual(AudioFxResponse.gainDb(chain.nodes[0], at: frequency)!, 20 * log10(q), accuracy: 0.05)
            }
        }
    }

    func testDelayRepeatsAreExact() {
        var impulse = [Float](repeating: 0, count: 37000); impulse[0] = 1
        let chain = FxChain(nodes: [FxNode(type: "delay", params: FxParams([("time", .number(250)), ("feedback", .number(0.5)), ("mix", .number(1))]))])
        let out = render(chain, [impulse])[0]
        XCTAssertEqual(out.indices.filter { abs(out[$0]) > 1e-6 }, [12000, 24000, 36000])
        XCTAssertEqual(out[12000], 1); XCTAssertEqual(out[24000], 0.5); XCTAssertEqual(out[36000], 0.25)
        XCTAssertEqual(FxTail.chainSeconds(chain), 2.5)
    }

    func testShortDelayFeedbackStaysInsideTheLine() {
        var impulse = [Float](repeating: 0, count: 160); impulse[0] = 1
        let chain = FxChain(nodes: [FxNode(type: "delay", params: FxParams([("time", .number(1)), ("feedback", .number(0.5)), ("mix", .number(1))]))])
        let out = render(chain, [impulse])[0]
        XCTAssertEqual(out[48], 1, accuracy: 0.00001); XCTAssertEqual(out[96], 0.5, accuracy: 0.00001); XCTAssertEqual(out[144], 0.25, accuracy: 0.00001)
    }

    func testDetectionIsStereoLinked() {
        let right = Float(pow(10, -26.0 / 20))
        for type in ["compressor", "gate"] {
            let chain = FxChain(nodes: [FxNode(type: type, params: FxParams([("threshold", .number(-24)), ("ratio", .number(8)), ("knee", .number(0))]))])
            let out = render(chain, [[Float](repeating: 1, count: 48000), [Float](repeating: right, count: 48000)])
            for n in out[0].indices { XCTAssertEqual(out[0][n], out[1][n] / right, accuracy: 0.000001, type) }
        }
    }

    func testKneeInDbIsContinuousAndMatchesResponse() {
        let width = 12.0, threshold = -24.0, ratio = 4.0
        XCTAssertEqual(currentKneeGain(threshold - width / 2, threshold, ratio, width), 0)
        XCTAssertEqual(currentKneeGain(threshold + width / 2, threshold, ratio, width), -4.5)
        XCTAssertEqual(currentKneeGain(threshold, threshold, ratio, width), -1.125)
        let node = FxNode(type: "compressor", version: 2, params: FxParams([("threshold", .number(threshold)), ("ratio", .number(ratio)), ("knee", .number(width))]))
        XCTAssertEqual(AudioFxResponse.outputDb(node, inputDb: threshold)!, threshold - 1.125)
    }

    func testVersionRoundTripAndMixedChainsKeepOldSound() throws {
        let legacy = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"highpass","id":"n1"},{"type":"compressor","id":"n2","params":{"knee":4}}]}"#)
        XCTAssertEqual(legacy.version, 1)
        XCTAssertTrue(legacy.needsSoundUpdate)
        XCTAssertEqual(try AudioFx.parseChain(AudioFx.serializeChain(legacy)), legacy)
        let added = AudioFxJobs.effectNode("lowpass", joining: legacy)
        let mixed = FxChain(nodes: legacy.nodes + [added])
        XCTAssertEqual(mixed.nodes.map(\.version), [1, 1, 2])
        XCTAssertEqual(try AudioFx.parseChain(AudioFx.serializeChain(mixed)), mixed)
        let updated = mixed.updatedSound()
        XCTAssertFalse(updated.needsSoundUpdate)
        XCTAssertEqual(updated.nodes.map(\.version), [2, 2, 2])
        XCTAssertEqual(updated.nodes[1].params!.num("knee"), 20 * log10(4), accuracy: 1e-9)
        XCTAssertThrowsError(try AudioFx.parseChain(#"{"version":3,"nodes":[]}"#))
    }

    func testPresetsAndToneUseCurrentSound() throws {
        let old = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"highpass"}]}"#)
        let preset = AudioFxPresets.apply(old, AudioFxPresets.all[0])
        XCTAssertEqual(preset.nodes.first?.version, 1)
        XCTAssertTrue(preset.nodes.dropFirst().allSatisfy { $0.version == 2 })
        let tone = AudioEq.add(old).0
        XCTAssertEqual(tone.nodes.first?.version, 1)
        XCTAssertTrue(tone.nodes.dropFirst().allSatisfy { $0.version == 2 })
    }
}
