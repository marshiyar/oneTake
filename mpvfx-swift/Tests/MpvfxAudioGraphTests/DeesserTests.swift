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

final class DeesserTests: XCTestCase {
    func tone(_ frequency: Double, level: Double = -6, count: Int = 48000) -> [Float] {
        let amplitude = pow(10, level / 20)
        return (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 48000)) }
    }
    func render(_ input: [[Float]], _ p: FxParams = AudioFx.defaultParams("deesser", version: 2)) -> [[Float]] {
        let chain = FxChain(nodes: [FxNode(type: "deesser", params: p)])
        return FxChainV2Tests().render(chain, input)
    }
    func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }
    func gain(_ output: [Float], _ input: [Float], from: Int = 12000, to: Int = 48000) -> Double {
        10 * log10(energy(Array(output[from..<to])) / energy(Array(input[from..<to])))
    }
    func testSibilantBurstReducedWithoutDullingVoice() {
        // A half-second burst after silence, with a settled measurement window inside the burst.
        var burst = tone(7000)
        for n in 0..<12000 { burst[n] = 0 }
        for n in 36000..<48000 { burst[n] = 0 }
        let high = gain(render([burst])[0], burst, from: 18000, to: 35000)
        let voice = tone(1000)
        let low = gain(render([voice])[0], voice)
        print("DEESSER 7kHz burst gain=\(high) dB; 1kHz gain=\(low) dB")
        XCTAssertLessThanOrEqual(high, -9)
        XCTAssertLessThan(abs(low), 0.1)
    }
    func testDetectorIsStereoLinkedAndChannelOrderIndependent() {
        let loud = tone(7000), quiet = loud.map { $0 * 0.01 }
        let linked = render([loud, quiet]), swapped = render([quiet, loud])
        XCTAssertEqual(linked[0], swapped[1]); XCTAssertEqual(linked[1], swapped[0])
        XCTAssertEqual(gain(linked[0], loud), gain(linked[1], quiet), accuracy: 0.001)
        XCTAssertLessThan(gain(linked[1], quiet), -9)
    }
    func testListenAndZeroRange() {
        let input = tone(7000)
        var p = AudioFx.defaultParams("deesser", version: 2); p["range"] = .number(0)
        XCTAssertEqual(render([input], p)[0], input)
        p["listen"] = .string("on")
        let high = render([input], p)[0], lowInput = tone(1000)
        let low = render([lowInput], p)[0]
        XCTAssertGreaterThan(gain(high, input), -3)
        XCTAssertLessThan(gain(low, lowInput), -40)
    }
    func testLiveParameterPostMatchesFreshProcessor() {
        let input = tone(7000, count: dspBlockSize)
        var p = AudioFx.defaultParams("deesser", version: 2)
        let processor = DeesserProcessor(p, sampleRate: 48000)
        p["frequency"] = .number(4500); p["attack"] = .number(20)
        p["release"] = .number(500); p["threshold"] = .number(-40); p["listen"] = .string("on")
        processor.post(p)
        let fresh = DeesserProcessor(p, sampleRate: 48000)
        var edited = [input], expected = [input]
        processor.process([input], &edited); fresh.process([input], &expected)
        XCTAssertEqual(edited, expected)
    }

    func testShelfJobControlsAndDetectorCurve() throws {
        let job = try XCTUnwrap(AudioFxJobs.all.first { $0.id == "de-ess" })
        let node = AudioFxJobs.node(job, joining: FxChain(version: 1))
        XCTAssertEqual(node.version, 2); XCTAssertEqual(node.type, "deesser")
        let def = try XCTUnwrap(AudioFx.definition(node.type, version: 2))
        XCTAssertEqual(def.group, "dynamics")
        for param in def.params {
            if case let .number(_, _, unit, _, _, _, _, _, _) = param { XCTAssertFalse(unit.isEmpty) }
        }
        XCTAssertEqual(def.params.map(\.key), ["frequency", "threshold", "range", "attack", "release", "listen"])
        XCTAssertTrue(AudioFxResponse.dynamicsTypes.contains(node.type))
        XCTAssertEqual(AudioFxResponse.outputDb(node, inputDb: -40), -40)
        XCTAssertEqual(AudioFxResponse.outputDb(node, inputDb: -6), -24)
        XCTAssertTrue(AudioFxCopy.summary(node.type, node.params ?? FxParams())?.contains("6500") == true)
    }
}
