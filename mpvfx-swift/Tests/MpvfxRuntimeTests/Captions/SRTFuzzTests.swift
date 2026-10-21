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
import MpvfxShared
@testable import MpvfxRuntime

/// SplitMix64: a seeded generator, so a failing input can be reproduced from its iteration number.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Acceptance 5: 10,000 random or garbled SRT inputs never crash the reader and never take it beyond 100 ms each.
final class SRTFuzzTests: XCTestCase {
    private static let seedText = """
    1\r\n00:00:01,000 --> 00:00:02,500\r\nHello <i>there</i>\r\n\r\n2\r\n00:00:02,500 --> 00:00:04,000 X1:1 X2:2\r\nα β γ\r\nsecond line\r\n\r\n\
    3\n00:10:00.000-->00:10:01.000\n字幕\n
    """
    private static let tokens: [[UInt8]] = ["-->", "\r\n", "\n", "\r", ":", ",", ".", "00", "99", "1", " ", "\t", "\u{FEFF}", "<i>"].map { Array($0.utf8) }
        + [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF], [0x00], [0xE9], [0xC3], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]

    private func garble(_ seed: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var bytes = seed
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            let at = bytes.isEmpty ? 0 : Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: if !bytes.isEmpty { bytes[at] = UInt8.random(in: 0...255, using: &rng) }
            case 1: bytes.insert(contentsOf: Self.tokens.randomElement(using: &rng) ?? [], at: at)
            case 2: if !bytes.isEmpty { bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...16, using: &rng))) }
            case 3: bytes = Array(bytes.prefix(at))
            case 4: let chunk = Array(bytes[at..<min(bytes.count, at + 40)]); bytes.insert(contentsOf: chunk, at: at)
            default: bytes.insert(contentsOf: (0..<Int.random(in: 1...32, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }, at: at)
            }
        }
        return bytes
    }

    private func randomBytes(_ rng: inout SplitMix64) -> [UInt8] {
        (0..<Int.random(in: 0...2048, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    /// Long lines and many cues of one shape, the inputs most likely to expose quadratic work.
    private func large(_ rng: inout SplitMix64) -> [UInt8] {
        let cue = Array(Self.seedText.utf8.prefix(60))
        let line = [UInt8](repeating: UInt8(ascii: "a"), count: Int.random(in: 1...20_000, using: &rng))
        return Array((0..<Int.random(in: 1...200, using: &rng)).map { _ in cue }.joined()) + line
    }

    /// What reading `count` generated inputs found: the slowest read and its iteration, how many read, and every
    /// error that was not an `SRTReadError`.
    private struct FuzzRun { var slowestNanoseconds: UInt64 = 0, slowestIteration = -1, accepted = 0, untyped: [String] = [] }

    private func input(_ iteration: Int, _ rng: inout SplitMix64) -> [UInt8] {
        switch iteration % 10 {
        case 0: return randomBytes(&rng)
        case 1: return large(&rng)
        default: return garble(Array(Self.seedText.utf8), &rng)
        }
    }

    private func fuzz(_ count: Int) -> FuzzRun {
        var rng = SplitMix64(state: 81), run = FuzzRun()
        for iteration in 0..<count {
            let data = Data(input(iteration, &rng))
            let started = DispatchTime.now().uptimeNanoseconds
            do { _ = try SRTReader.read(data); run.accepted += 1 }
            catch is SRTReadError {}
            catch { run.untyped.append("iteration \(iteration): \(error)") }
            let took = DispatchTime.now().uptimeNanoseconds - started
            if took > run.slowestNanoseconds { (run.slowestNanoseconds, run.slowestIteration) = (took, iteration) }
        }
        return run
    }

    func testTenThousandGarbledInputsNeverCrashOrHang() {
        let run = fuzz(10_000)
        XCTAssertEqual(run.untyped, [], "every refusal is an SRTReadError")
        XCTAssertLessThan(run.slowestNanoseconds, 100_000_000,
                          "iteration \(run.slowestIteration) took \(run.slowestNanoseconds / 1_000_000) ms")
        XCTAssertGreaterThan(run.accepted, 0, "some garbled inputs still read, so the mutations reach the cue parser")
    }

    private static let words = ["a", "Ünï", "字幕", "🎬", "<i>x</i>", "  lead", "tab\there", "{\\an8}", "--", "1", "00:00:01,000"]

    /// Random cues that pass the caption rules: in order, apart or touching, one to three lines of text each.
    private func randomCues(_ rng: inout SplitMix64) -> [NativeCaptionCue] {
        var cues: [NativeCaptionCue] = [], at = Int.random(in: 0...5000, using: &rng)
        for n in 1...Int.random(in: 1...20, using: &rng) {
            let end = at + Int.random(in: 1...10_000, using: &rng)
            let lines = (0..<Int.random(in: 1...3, using: &rng)).map { _ in Self.words.randomElement(using: &rng) ?? "a" }
            cues.append(NativeCaptionCue(id: "cue-\(n)", startMs: at, endMs: end, text: lines.joined(separator: "\n")))
            at = end + Int.random(in: 0...2000, using: &rng)
        }
        return cues
    }

    /// The indexes of the `count` random tracks whose export did not read back into the same cues.
    private func roundTripMismatches(_ count: Int) -> [Int] {
        var rng = SplitMix64(state: 1081)
        return (0..<count).filter { _ in
            let cues = randomCues(&rng)
            return (try? SRTReader.read(Data(SRTWriter.text(cues).utf8))) != cues
        }
    }

    func testRandomValidCuesRoundTripThroughExportAndImport() {
        XCTAssertEqual(roundTripMismatches(500), [])
    }
}
