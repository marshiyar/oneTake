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

final class LimiterV2Tests: XCTestCase {
    func chain(ceiling: Double = -1, lookahead: Double = 1.5, amount: Double? = nil, count: Int = 1) -> FxChain {
        FxChain(version: 2, nodes: (0..<count).map { _ in
            FxNode(type: "limiter", fromPreset: amount == nil ? nil : "test", presetAmount: amount,
                   params: FxParams([("limit", .number(ceiling)), ("lookahead", .number(lookahead))]))
        })
    }
    func render(_ chain: FxChain, _ input: [[Float]], block: Int = 128, sampleRate: Double = 48000) -> ([[Float]], Int) {
        let p = FxChainProcessor(chain, sampleRate: sampleRate)
        let length = input[0].count + p.latencyFrames
        var out = input.map { _ in [Float]() }
        for f in stride(from: 0, to: length, by: block) {
            let n = min(block, length - f)
            let x = input.map { plane in (0..<n).map { f + $0 < plane.count ? plane[f + $0] : 0 } }
            let y = p.process(x, frame: f)
            for ch in out.indices { out[ch] += y[ch] }
        }
        return (out, p.latencyFrames)
    }
    func testCeilingHolds() {
        for sr in [44100.0, 48000, 96000] {
            for ceiling in [-24.0, -1, 0] {
                for hz in [50.0, 1000, 10000] {
                    for db in [0.0, 6, 12] {
                        let x = (0..<Int(sr / 20)).map { Float(pow(10, db / 20) * sin(2 * .pi * hz * Double($0) / sr)) }
                        let (y, _) = render(chain(ceiling: ceiling), [x, x.map { $0 * 0.1 }], block: 97, sampleRate: sr)
                        XCTAssertLessThanOrEqual(y.flatMap { $0 }.map { abs(Double($0)) }.max() ?? 0, pow(10, ceiling / 20))
                    }
                }
                var burst = [Float](repeating: 0, count: 3000)
                for i in 1000..<1100 { burst[i] = i % 2 == 0 ? 1 : -1 }
                let (y, _) = render(chain(ceiling: ceiling), [burst], sampleRate: sr)
                XCTAssertLessThanOrEqual(y[0].map { abs(Double($0)) }.max() ?? 0, pow(10, ceiling / 20))
            }
        }
    }
    func testTransparentBelowCeiling() {
        let x = (0..<2000).map { Float(sin(Double($0) * 0.13) * 0.05) }
        let ceiling = pow(10, -1.0 / 20)
        let rounded = Float(ceiling)
        let justBelow = Double(rounded) < ceiling ? rounded : rounded.nextDown
        let (edge, latency) = render(chain(), [[Float](repeating: justBelow, count: 100)])
        XCTAssertTrue(edge[0].dropFirst(latency).allSatisfy { $0 == justBelow })
        for lookahead in [0.5, 1.5, 5] {
            for amount in [0.0, 0.35, 1] {
                let (y, latency) = render(chain(lookahead: lookahead, amount: amount, count: 2), [x])
                XCTAssertEqual(latency, 2 * Int((lookahead * 48).rounded()))
                XCTAssertTrue(y[0].prefix(latency).allSatisfy { $0 == 0 })
                for i in x.indices { XCTAssertEqual(y[0][latency + i], x[i], accuracy: 1e-8) }
            }
        }
    }
    func testLatencyIsCompensated() {
        var x = [Float](repeating: 0, count: 4800)
        x[0] = 0.1; x[127] = -0.1; x[4799] = 0.1
        for bus in [false, true] {
            func project(_ fx: FxChain?) -> AudioGraphProject {
                let track = AudioGraphTrack(id: "clip", stem: [x, x], start: 0.01, end: 0.11,
                                           fxChain: bus ? nil : fx, groupId: bus ? "bus" : nil)
                return AudioGraphProject(duration: 0.2, tracks: [track],
                    groups: bus ? [AudioGraphGroup(id: "bus", fxChain: fx)] : [], quantizeIntermediates: false)
            }
            let dry = AudioGraphRenderer.renderOffline(project(nil))
            let wet = AudioGraphRenderer.renderOffline(project(chain(amount: 0.35, count: 2)))
            XCTAssertEqual(wet.count, dry.count)
            for i in dry.indices { XCTAssertEqual(wet[i], dry[i], accuracy: 1e-8) }
        }
        XCTAssertEqual(FxTail.chainSeconds(chain(count: 2)), 0.003, accuracy: 1e-12)
        XCTAssertEqual(FxTail.chainSeconds(FxChain(version: 1, nodes: [FxNode(type: "limiter")])), 0)
    }
    func testLinkedGainAndBlockBoundaries() {
        var x = [Float](repeating: 0, count: 2000); x[137] = 4; x[155] = -2
        let right = x.map { $0 * 0.125 }
        let a = render(chain(), [x, right], block: 128).0
        let b = render(chain(), [x, right], block: 37).0
        XCTAssertEqual(a, b)
        for i in a[0].indices { XCTAssertEqual(a[1][i], a[0][i] * 0.125, accuracy: 1e-7) }
        let p = AudioFx.normalize("limiter", FxParams([("lookahead", .number(99)), ("release", .number(0))]), version: 2)
        XCTAssertEqual(p.num("lookahead"), 5); XCTAssertEqual(p.num("release"), 10)
        XCTAssertNil(AudioFx.defaultParams("limiter", version: 2)["level_out"])
        XCTAssertNotNil(AudioFx.defaultParams("limiter", version: 1)["level_out"])
    }
}
