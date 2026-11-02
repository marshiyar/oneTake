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
import XCTest
@testable import MpvfxAudioGraph

/// "Even Out": the leveller as a live effect with one Amount (#314).
final class LevellerUnitTests: XCTestCase {
    private let rate = 48_000.0

    private func tone(_ dBFS: Double, seconds: Double) -> [Float] {
        let a = pow(10, dBFS / 20)
        return (0..<Int(rate * seconds)).map { Float(a * sin(2 * .pi * 220 * Double($0) / rate)) }
    }

    /// Two loud phrases (-12 dBFS) with two quiet ones (-30 dBFS) between and after, three seconds each.
    private var phrases: [Float] { tone(-12, seconds: 3) + tone(-30, seconds: 3) + tone(-12, seconds: 3) + tone(-30, seconds: 3) }

    private func run(_ samples: [Float], amount: Double, block: Int = dspBlockSize) -> [Float] {
        let node = FxNode(type: "leveller", id: "x", params: AudioFx.normalize("leveller", ["amount": .number(amount)]))
        let chain = FxChainProcessor(FxChain(nodes: [node]), sampleRate: rate)
        var out: [Float] = []
        var at = 0
        while at < samples.count {
            let n = min(block, samples.count - at)
            let part = Array(samples[at..<(at + n)])
            out += chain.process([part, part], frame: at)[0]
            at += n
        }
        return out
    }

    /// The unit on its own, in blocks of any size.
    private func runUnit(_ samples: [Float], amount: Double, block: Int) -> [Float] {
        let unit = LevellerUnit(AudioFx.normalize("leveller", ["amount": .number(amount)]), rate)
        var out: [Float] = []
        var at = 0
        while at < samples.count {
            let n = min(block, samples.count - at)
            let part = Array(samples[at..<(at + n)])
            out += unit.process([part, part], frame: at)[0]
            at += n
        }
        return out
    }

    private func rmsDb(_ x: [Float], from seconds: Double, length: Double = 1) -> Double {
        let a = Int(seconds * rate), b = min(x.count, a + Int(length * rate))
        let ms = x[a..<b].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b - a)
        return 10 * log10(max(ms, 1e-20))
    }

    /// The gap between the last second of the second loud phrase and the last second of the second quiet one.
    private func gap(_ x: [Float]) -> Double { rmsDb(x, from: 7.9) - rmsDb(x, from: 11) }

    func testA1AmountOneNarrowsTheGapBetweenAQuietAndALoudPhraseByAtLeastSixDB() {
        let source = phrases
        let before = gap(source)
        XCTAssertEqual(before, 18, accuracy: 0.1)
        let after = gap(run(source, amount: 1))
        XCTAssertLessThanOrEqual(after, before - 6, "the gap went from \(before) dB to \(after) dB")
        XCTAssertGreaterThan(after, 0, "the quiet phrase is still the quieter one")
    }

    func testTheGapNarrowsMoreAsTheAmountGoesUp() {
        let source = phrases
        let gaps = [0.0, 0.3, 0.65, 1].map { gap(run(source, amount: $0)) }
        XCTAssertEqual(gaps[0], 18, accuracy: 0.1, "Amount 0 leaves the level alone")
        for (a, b) in zip(gaps, gaps.dropFirst()) { XCTAssertLessThan(b, a) }
    }

    func testAmountZeroIsBitIdenticalToTheInput() {
        let source = phrases
        XCTAssertEqual(run(source, amount: 0), source)
    }

    func testASteadyToneIsLeftAlone() {
        let steady = tone(-20, seconds: 6)
        XCTAssertEqual(rmsDb(run(steady, amount: 1), from: 4), rmsDb(steady, from: 4), accuracy: 0.3)
    }

    func testTheSamplesDoNotDependOnTheBlockSize() {
        let source = Array(phrases.prefix(Int(rate * 7)))
        let small = runUnit(source, amount: 0.8, block: 128)
        XCTAssertEqual(runUnit(source, amount: 0.8, block: 4_096), small)
        XCTAssertEqual(runUnit(source, amount: 0.8, block: 1_000), small)
        XCTAssertEqual(run(source, amount: 0.8), small, "the chain runs the same unit")
    }

    func testSilenceAndNonFiniteSamplesStayFinite() {
        XCTAssertTrue(run([Float](repeating: 0, count: 48_000), amount: 1).allSatisfy { $0 == 0 })
        var bad = tone(-20, seconds: 2)
        bad[100] = .nan; bad[5_000] = .infinity
        let out = run(bad, amount: 1)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rmsDb(out, from: 1), -40, "the effect is not stuck silent after the bad samples")
    }

    func testGainIsHeldWithinTwelveDB() {
        // A -50 dBFS tone after a long loud phrase can be lifted by at most the leveller's 12 dB.
        let source = tone(-10, seconds: 4) + tone(-50, seconds: 4)
        let after = run(source, amount: 1)
        let lift = rmsDb(after, from: 7) - rmsDb(source, from: 7)
        XCTAssertLessThanOrEqual(lift, 12.01)
        XCTAssertGreaterThan(lift, 6)
    }

    func testEvenOutIsInTheRegistryWithOneAmountAndPlainCopy() throws {
        let def = try XCTUnwrap(AudioFx.definition("leveller"))
        XCTAssertEqual(def.params.count, 1)
        XCTAssertEqual(AudioFxCopy.title("leveller"), "Even Out")
        XCTAssertEqual(AudioFx.defaultParams("leveller").num("amount"), 0.65)
        XCTAssertFalse(AudioFxPresets.modulePresets("leveller").isEmpty)
    }
}
