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

/// A NaN or infinite sample (a corrupt float stem, a decoder fault) must not reach the device or the encoder, and must
/// not poison an effect's state for the rest of the render.
final class NonFiniteSampleTests: XCTestCase {
    static let sr = 48000.0

    static func sine(_ n: Int) -> [Float] {
        (0..<n).map { (i: Int) -> Float in Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / sr)) }
    }

    func testEveryEffectRecoversAfterANonFiniteInputSample() throws {
        for type in AudioFx.ids {
            let proc = FxChainProcessor(FxChain(nodes: [FxNode(type: type, id: "x", params: AudioFx.defaultParams(type))]), sampleRate: Self.sr)
            var bad = Self.sine(dspBlockSize)
            bad[5] = .nan; bad[9] = .infinity; bad[11] = -.infinity
            let first = proc.process([bad, bad], frame: 0)
            XCTAssertTrue(first.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(type): non-finite output in the bad block")
            var out: [Float] = []
            for q in 1..<40 { out += proc.process([Self.sine(dspBlockSize), Self.sine(dspBlockSize)], frame: q * dspBlockSize)[0] }
            XCTAssertTrue(out.allSatisfy(\.isFinite), "\(type): NaN held in the effect's state")
            XCTAssertGreaterThan(out.suffix(1024).map { abs($0) }.max() ?? 0, 0.01, "\(type): silent after the bad sample")
        }
    }

    /// A finite input can still overflow inside the chain: +12 dB of a near-maximal float is infinite. The next effect
    /// must not take it into its state.
    func testAnOverflowInsideTheChainDoesNotPoisonTheNextEffect() throws {
        let chain = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":12}},{"type":"peaking","id":"p","params":{"gain":6}}]}"#)
        let proc = FxChainProcessor(chain, sampleRate: Self.sr)
        var loud = Self.sine(dspBlockSize)
        loud[7] = .greatestFiniteMagnitude
        XCTAssertTrue(proc.process([loud, loud], frame: 0).allSatisfy { $0.allSatisfy(\.isFinite) })
        var out: [Float] = []
        for q in 1..<40 { out += proc.process([Self.sine(dspBlockSize), Self.sine(dspBlockSize)], frame: q * dspBlockSize)[0] }
        XCTAssertTrue(out.allSatisfy(\.isFinite), "the bell holds the overflow in its state")
        XCTAssertGreaterThan(out.suffix(1024).map { abs($0) }.max() ?? 0, 0.01)
    }

    func testTheMixNeverOutputsANonFiniteSample() {
        var stem = Self.sine(48000)
        stem[100] = .nan; stem[200] = .infinity
        let project = AudioGraphProject(duration: 1, sampleRate: Self.sr, tracks: [
            AudioGraphTrack(id: "a", stem: [stem, stem], start: 0, end: 1),
        ], quantizeIntermediates: false)
        let out = AudioGraphRenderer.renderOffline(project)
        XCTAssertEqual(out.count, 96000)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }
}
