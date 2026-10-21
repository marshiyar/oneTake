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

/// Spectral noise reduction (issue #311): a learned profile, latency-compensated, identical live and in export.
final class DenoiseTests: XCTestCase {
    static let sr = 48_000.0
    static let seconds = 2.0

    /// Seeded uniform noise scaled to `rms` (linear).
    static func noise(_ count: Int, rms: Double, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<count).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(s >> 11) / Double(1 << 53) * 2 - 1
            return Float(u * rms * 3.0.squareRoot())
        }
    }

    /// 0 to 0.5 s noise only, 0.5 to 1.5 s a 1 kHz tone (−12 dBFS peak) over the noise, 1.5 to 2 s noise only.
    /// The noise is white at −30 dBFS RMS.
    static let fixture: [Float] = {
        let n = Int(seconds * sr)
        let nz = noise(n, rms: pow(10, -30.0 / 20), seed: 7)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let tone = t >= 0.5 && t < 1.5 ? pow(10, -12.0 / 20) * sin(2 * Double.pi * 1000 * t) : 0
            return nz[i] + Float(tone)
        }
    }()

    static func project(_ nodes: [FxNode], stem: [Float] = fixture) -> AudioGraphProject {
        let d = Double(stem.count) / sr
        return AudioGraphProject(duration: d, tracks: [AudioGraphTrack(id: "c", stem: [stem, stem], start: 0, end: d, fxChain: FxChain(nodes: nodes))])
    }
    static func denoise(_ amount: Double, learn: Double = 400) -> FxNode {
        FxNode(type: "denoise", id: "dn", params: AudioFx.normalize("denoise", FxParams([("amount", .number(amount)), ("learn", .number(learn))])))
    }
    static func left(_ mix: [Float]) -> [Float] { stride(from: 0, to: mix.count, by: 2).map { mix[$0] } }
    static func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot() }
    static func range(_ a: Double, _ b: Double) -> Range<Int> { Int(a * sr)..<Int(b * sr) }

    /// Amplitude of the 1 kHz component (single-bin DFT).
    static func toneLevel(_ x: ArraySlice<Float>, start: Int) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in x.enumerated() {
            let ph = 2 * Double.pi * 1000 * Double(start + k) / sr
            re += Double(v) * cos(ph); im += Double(v) * sin(ph)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    func testFullAmountDropsTheNoiseFloorByFifteenDbAndKeepsTheTone() {
        let dry = Self.left(AudioGraphRenderer.renderOffline(Self.project([])))
        let wet = Self.left(AudioGraphRenderer.renderOffline(Self.project([Self.denoise(1)])))
        let tail = Self.range(1.6, 1.95)
        let reduction = 20 * log10(Self.rms(dry[tail]) / Self.rms(wet[tail]))
        XCTAssertGreaterThanOrEqual(reduction, 15, "noise floor reduction \(reduction) dB")
        let mid = Self.range(0.7, 1.3)
        let change = 20 * log10(Self.toneLevel(wet[mid], start: mid.lowerBound) / Self.toneLevel(dry[mid], start: mid.lowerBound))
        XCTAssertLessThan(abs(change), 0.5, "tone level changed by \(change) dB")
    }

    func testAmountZeroIsBitIdenticalToBypass() {
        let bypass = AudioGraphRenderer.renderOffline(Self.project([]))
        let zero = AudioGraphRenderer.renderOffline(Self.project([Self.denoise(0)]))
        XCTAssertGreaterThanOrEqual(zero.count, bypass.count)
        XCTAssertTrue(zero.prefix(bypass.count) == bypass[...], "amount 0 matches the chain without the node")
    }

    func testOutputIsAlignedToTheInputAfterLatencyCompensation() {
        // An impulse in silence comes out at the same frame (amount 0 keeps it exact; amount 1 keeps its position).
        var stem = [Float](repeating: 0, count: 48_000)
        stem[20_000] = 0.5
        for amount in [0.0, 1.0] {
            let wet = Self.left(AudioGraphRenderer.renderOffline(Self.project([Self.denoise(amount, learn: 100)], stem: stem)))
            let peak = wet.indices.max { abs(wet[$0]) < abs(wet[$1]) }!
            XCTAssertEqual(peak, 20_000, accuracy: 1, "amount \(amount)")
        }
    }

    func testLiveBlocksAndExportChunksAgreeSampleForSample() {
        let p = Self.project([Self.denoise(0.8), FxNode(type: "gain", id: "g", params: AudioFx.normalize("gain", FxParams([("gain", .number(-3))])))])
        let live = ClipFadeTests.live(p), export = ClipFadeTests.export(p)
        XCTAssertEqual(live.count, p.totalFrames * 2)
        XCTAssertTrue(live == export)
        XCTAssertTrue(AudioGraphRenderer.renderOffline(p) == live)
    }

    func testSilenceAndHostileSettingsStaySilentAndFinite() {
        let silent = [Float](repeating: 0, count: 24_000)
        let out = AudioGraphRenderer.renderOffline(Self.project([Self.denoise(1, learn: 100)], stem: silent))
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
        let p = AudioFx.normalize("denoise", ["amount": .number(9), "learn": .number(-5), "learn_from": .string("x")])
        XCTAssertEqual(p.num("amount"), 1)
        XCTAssertEqual(p.num("learn"), 100)
        XCTAssertEqual(p.num("learn_from"), 0)
    }
}
