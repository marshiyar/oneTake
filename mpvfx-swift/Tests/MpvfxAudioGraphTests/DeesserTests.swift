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

internal final class DeesserTests: XCTestCase {
    private func tone(_ frequency: Double, level: Double = -6, count: Int = 48_000) -> [Float] {
        let amplitude = pow(10, level / 20)
        return (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }
    private func render(_ input: [[Float]], _ params: FxParams = AudioFx.defaultParams("deesser", version: 2))
        -> [[Float]]
    {
        let chain = FxChain(nodes: [FxNode(type: "deesser", params: params)])
        let processor = FxChainProcessor(chain)
        var output = input.map { _ in [Float]() }
        for frame in stride(from: 0, to: input[0].count, by: dspBlockSize) {
            let end = min(input[0].count, frame + dspBlockSize)
            let block = processor.process(input.map { Array($0[frame..<end]) }, frame: frame)
            for channel in output.indices { output[channel] += block[channel] }
        }
        return output
    }
    private func energy(_ samples: [Float]) -> Double { samples.reduce(0) { $0 + Double($1) * Double($1) } }
    private func gain(_ output: [Float], _ input: [Float], from: Int = 12_000, to endFrame: Int = 48_000) -> Double {
        10 * log10(energy(Array(output[from..<endFrame])) / energy(Array(input[from..<endFrame])))
    }
    internal func testSibilantBurstReducedWithoutDullingVoice() {
        // A half-second burst after silence, with a settled measurement window inside the burst.
        var burst = tone(7_000)
        for frameIndex in 0..<12_000 { burst[frameIndex] = 0 }
        for frameIndex in 36_000..<48_000 { burst[frameIndex] = 0 }
        let high = gain(render([burst])[0], burst, from: 18_000, to: 35_000)
        let voice = tone(1_000)
        let low = gain(render([voice])[0], voice)
        print("DEESSER 7kHz burst gain=\(high) dB; 1kHz gain=\(low) dB")
        XCTAssertLessThanOrEqual(high, -9)
        XCTAssertLessThan(abs(low), 0.1)
    }
    internal func testDetectorIsStereoLinkedAndChannelOrderIndependent() {
        let loud = tone(7_000)
        let quiet = loud.map { $0 * 0.01 }
        let linked = render([loud, quiet])
        let swapped = render([quiet, loud])
        XCTAssertEqual(linked[0], swapped[1])
        XCTAssertEqual(linked[1], swapped[0])
        XCTAssertEqual(gain(linked[0], loud), gain(linked[1], quiet), accuracy: 0.001)
        XCTAssertLessThan(gain(linked[1], quiet), -9)
    }
    internal func testListenAndZeroRange() {
        let input = tone(7_000)
        var params = AudioFx.defaultParams("deesser", version: 2)
        params["range"] = .number(0)
        XCTAssertEqual(render([input], params)[0], input)
        params["listen"] = .string("on")
        let high = render([input], params)[0]
        let lowInput = tone(1_000)
        let low = render([lowInput], params)[0]
        XCTAssertGreaterThan(gain(high, input), -3)
        XCTAssertLessThan(gain(low, lowInput), -40)
    }
    internal func testLiveParameterPostMatchesFreshProcessor() {
        let input = tone(7_000, count: dspBlockSize)
        var params = AudioFx.defaultParams("deesser", version: 2)
        let processor = DeesserProcessor(params, sampleRate: 48_000)
        params["frequency"] = .number(4_500)
        params["attack"] = .number(20)
        params["release"] = .number(500)
        params["threshold"] = .number(-40)
        params["listen"] = .string("on")
        processor.post(params)
        let fresh = DeesserProcessor(params, sampleRate: 48_000)
        var edited = [input]
        var expected = [input]
        processor.process([input], &edited)
        fresh.process([input], &expected)
        XCTAssertEqual(edited, expected)
    }

    internal func testShelfJobControlsAndDetectorCurve() throws {
        let job = try XCTUnwrap(AudioFxJobs.all.first { $0.id == "de-ess" })
        let node = AudioFxJobs.node(job, joining: FxChain(version: 1))
        XCTAssertEqual(node.version, 2)
        XCTAssertEqual(node.type, "deesser")
        let def = try XCTUnwrap(AudioFx.definition(node.type, version: 2))
        XCTAssertEqual(def.group, "dynamics")
        for param in def.params {
            if case .number(_, _, let unit, _, _, _, _, _, _) = param { XCTAssertFalse(unit.isEmpty) }
        }
        XCTAssertEqual(def.params.map(\.key), ["frequency", "threshold", "range", "attack", "release", "listen"])
        XCTAssertTrue(AudioFxResponse.dynamicsTypes.contains(node.type))
        XCTAssertEqual(AudioFxResponse.outputDb(node, inputDb: -40), -40)
        XCTAssertEqual(AudioFxResponse.outputDb(node, inputDb: -6), -24)
        XCTAssertTrue(AudioFxCopy.summary(node.type, node.params ?? FxParams())?.contains("6500") == true)
    }
}
