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

/// Clean up noise, learning (issue #312): the quietest parts, the I/O range, and what the unit does with the profile.
final class NoiseProfileTests: XCTestCase {
    static let sr = 48_000.0
    static let noiseRms = pow(10, -30.0 / 20)
    /// Power per bin of white noise of `noiseRms` through the sqrt-Hann window: variance times the window energy (size / 2).
    static let expectedDb = 10 * log10(noiseRms * noiseRms * Double(NoiseProfile.size) / 2)

    /// `seconds` of white noise with a loud 1 kHz tone over every span in `tones`.
    static func signal(seconds: Double, tones: [Range<Double>], seed: UInt64 = 11) -> [Float] {
        let n = Int(seconds * sr)
        let noise = DenoiseTests.noise(n, rms: noiseRms, seed: seed)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let on = tones.contains { $0.contains(t) }
            return noise[i] + (on ? Float(0.25 * sin(2 * Double.pi * 1000 * t)) : 0)
        }
    }
    static let toneBin = Int((1000 / (sr / Double(NoiseProfile.size))).rounded())

    static func meanError(_ profile: [Double]) -> Double {
        let used = profile[8..<(NoiseProfile.bins - 8)]
        return used.reduce(0, +) / Double(used.count) - expectedDb
    }

    func testA1QuietestPartsLearnTheNoiseFloorNotTheVoice() throws {
        // Noise alone for a quarter of the clip; the quietest 10% of the frames all fall inside it.
        let x = Self.signal(seconds: 4, tones: [1..<3])
        let profile = try NoiseProfile.learnQuietest([x, x], sampleRate: Self.sr)
        XCTAssertEqual(profile.count, NoiseProfile.bins)
        XCTAssertEqual(Self.meanError(profile), 0, accuracy: 0.6, "mean profile level against the known noise")
        XCTAssertLessThan(profile[Self.toneBin] - Self.expectedDb, 4, "the tone must not be in the profile")
        XCTAssertTrue(profile.allSatisfy { abs($0 * 10 - ($0 * 10).rounded()) < 1e-6 }, "values are in 0.1 dB steps")
    }

    func testA1StereoNoiseThatDiffersBetweenChannelsIsLearnedAtTheSameLevel() throws {
        let left = Self.signal(seconds: 4, tones: [1..<3], seed: 11), right = Self.signal(seconds: 4, tones: [1..<3], seed: 23)
        let profile = try NoiseProfile.learnQuietest([left, right], sampleRate: Self.sr)
        XCTAssertEqual(Self.meanError(profile), 0, accuracy: 0.6)
    }

    func testA1TheMedianIsOfTheQuietestTenthOnly() throws {
        // 10 s: noise at −30 dBFS everywhere, but the first 0.5 s is quieter (−50 dBFS). The quietest 10% of the frames
        // (1 s) therefore holds the quiet half second and the quietest of the rest, so the level lands between the two.
        var x = Self.signal(seconds: 10, tones: [])
        for i in 0..<Int(0.5 * Self.sr) { x[i] *= 0.1 }
        let profile = try NoiseProfile.learnQuietest([x], sampleRate: Self.sr)
        let level = Self.meanError(profile)
        XCTAssertLessThan(level, -1, "the quietest frames pull the profile below the plain noise level")
        XCTAssertGreaterThan(level, -20)
    }

    func testA2SelectedRangeLearnsExactlyThatRange() throws {
        let x = Self.signal(seconds: 4, tones: [0..<1, 2..<4])      // noise alone only between 1 s and 2 s
        let exact = try NoiseProfile.learnRange([x], sampleRate: Self.sr, span: .init(start: 1, end: 2))
        XCTAssertEqual(Self.meanError(exact), 0, accuracy: 0.6)
        XCTAssertLessThan(exact[Self.toneBin] - Self.expectedDb, 4)
        // Half a second later the range holds the tone, and the profile carries it: the range decides the profile.
        let shifted = try NoiseProfile.learnRange([x], sampleRate: Self.sr, span: .init(start: 1.5, end: 2.5))
        XCTAssertGreaterThan(shifted[Self.toneBin] - Self.expectedDb, 20)
    }

    func testA2ClipRangeIsTheIORangeInTheClipsOwnTime() {
        XCTAssertEqual(NoiseProfile.clipRange(inPoint: 12, outPoint: 14, clipStart: 10, clipDuration: 5), .init(start: 2, end: 4))
        XCTAssertEqual(NoiseProfile.clipRange(inPoint: 8, outPoint: 12, clipStart: 10, clipDuration: 5), .init(start: 0, end: 2))
        XCTAssertEqual(NoiseProfile.clipRange(inPoint: 13, outPoint: 30, clipStart: 10, clipDuration: 5), .init(start: 3, end: 5))
        XCTAssertNil(NoiseProfile.clipRange(inPoint: 20, outPoint: 22, clipStart: 10, clipDuration: 5))
        XCTAssertNil(NoiseProfile.clipRange(inPoint: nil, outPoint: 14, clipStart: 10, clipDuration: 5))
        XCTAssertNil(NoiseProfile.clipRange(inPoint: 14, outPoint: 12, clipStart: 10, clipDuration: 5))
        XCTAssertNil(NoiseProfile.clipRange(inPoint: .nan, outPoint: 12, clipStart: 10, clipDuration: 5))
    }

    func testHostileInputIsATypedError() {
        let x = Self.signal(seconds: 1, tones: [])
        XCTAssertThrowsError(try NoiseProfile.learnRange([x], sampleRate: Self.sr, span: .init(start: 0.2, end: 0.21))) {
            XCTAssertEqual($0 as? NoiseProfile.Failure, .tooShort)
        }
        XCTAssertThrowsError(try NoiseProfile.learnRange([x], sampleRate: Self.sr, span: .init(start: 0.5, end: 0.4))) {
            XCTAssertEqual($0 as? NoiseProfile.Failure, .invalidRange)
        }
        XCTAssertThrowsError(try NoiseProfile.learnQuietest([], sampleRate: Self.sr)) { XCTAssertEqual($0 as? NoiseProfile.Failure, .noChannels) }
        XCTAssertThrowsError(try NoiseProfile.learnQuietest([[1, 2, 3]], sampleRate: Self.sr)) { XCTAssertEqual($0 as? NoiseProfile.Failure, .tooShort) }
        XCTAssertThrowsError(try NoiseProfile.learnQuietest([x, [1]], sampleRate: Self.sr)) { XCTAssertEqual($0 as? NoiseProfile.Failure, .noChannels) }
        XCTAssertThrowsError(try NoiseProfile.learnQuietest([[Float](repeating: 0, count: 8_000)], sampleRate: Self.sr)) {
            XCTAssertEqual($0 as? NoiseProfile.Failure, .silent)
        }
        // A gap cut out to digital silence is not the noise floor: the quietest tenth is taken from what still sounds.
        var gapped = Self.signal(seconds: 4, tones: [])
        for i in 0..<Int(1.0 * Self.sr) { gapped[i] = 0 }
        let withGap = try? NoiseProfile.learnQuietest([gapped], sampleRate: Self.sr)
        XCTAssertEqual(withGap.map(Self.meanError) ?? 99, 0, accuracy: 1)
        XCTAssertNotNil(try? NoiseProfile.learnRange([gapped], sampleRate: Self.sr, span: .init(start: 0, end: 1e300)), "a huge span is cut to the audio")
    }

    // MARK: the unit and the chain document

    static func node(_ profile: [Double]?, amount: Double = 1, listen: Bool = false) -> FxNode {
        var params = AudioFx.normalize("denoise", FxParams([("amount", .number(amount)), ("learn", .number(100))]))
        if listen { params["listen"] = .string("on") }
        return FxNode(type: "denoise", id: "dn", params: params, noiseProfile: profile)
    }
    static func render(_ node: FxNode?, forExport: Bool = false) -> [Float] {
        var project = DenoiseTests.project(node.map { [$0] } ?? [])
        if forExport { project = project.forExport() }
        return DenoiseTests.left(AudioGraphRenderer.renderOffline(project))
    }

    func testAStoredProfileDenoisesFromTheFirstFrame() throws {
        // The fixture is noise 0 to 0.5 s, tone to 1.5 s, noise to 2 s. Learning while playing cannot touch the first half second
        // when the noise is learned from its end; a stored profile does.
        let profile = try NoiseProfile.learnRange([DenoiseTests.fixture], sampleRate: Self.sr, span: .init(start: 1.6, end: 2.0))
        var streaming = Self.node(nil)
        streaming.paramsA?["learn_from"] = .number(1.6)
        let dry = Self.render(nil), early = DenoiseTests.range(0.1, 0.4)
        let streamed = Self.render(streaming), stored = Self.render(Self.node(profile))
        XCTAssertLessThan(20 * log10(DenoiseTests.rms(dry[early]) / DenoiseTests.rms(streamed[early])), 1, "nothing is learned yet")
        XCTAssertGreaterThanOrEqual(20 * log10(DenoiseTests.rms(dry[early]) / DenoiseTests.rms(stored[early])), 15)
        let mid = DenoiseTests.range(0.7, 1.3)
        let change = 20 * log10(DenoiseTests.toneLevel(stored[mid], start: mid.lowerBound) / DenoiseTests.toneLevel(dry[mid], start: mid.lowerBound))
        XCTAssertLessThan(abs(change), 0.5, "the tone must come through (\(change) dB)")
    }

    func testA3ListenGivesInputMinusOutputAndKeepsTheVoiceOut() throws {
        let profile = try NoiseProfile.learnQuietest([DenoiseTests.fixture], sampleRate: Self.sr)
        let dry = Self.render(nil), wet = Self.render(Self.node(profile)), removed = Self.render(Self.node(profile, listen: true))
        XCTAssertEqual(removed.count, wet.count)
        var worst: Float = 0
        for i in 0..<min(dry.count, removed.count) { worst = max(worst, abs(removed[i] - (dry[i] - wet[i]))) }
        XCTAssertLessThan(worst, 3e-4, "removed = input - output to within the 16-bit rounding of the three renders")
        let mid = DenoiseTests.range(0.7, 1.3)
        XCTAssertLessThan(DenoiseTests.toneLevel(removed[mid], start: mid.lowerBound), 0.1 * DenoiseTests.toneLevel(dry[mid], start: mid.lowerBound))
        let tail = DenoiseTests.range(1.6, 1.95)
        XCTAssertGreaterThan(DenoiseTests.rms(removed[tail]), 0.5 * DenoiseTests.rms(dry[tail]), "the noise is what is heard")
    }

    func testA3ExportNeverUsesListen() throws {
        let profile = try NoiseProfile.learnQuietest([DenoiseTests.fixture], sampleRate: Self.sr)
        let listening = Self.node(profile, listen: true)
        XCTAssertNotEqual(Self.render(listening), Self.render(Self.node(profile)), "playback does hear it")
        XCTAssertEqual(Self.render(listening, forExport: true), Self.render(Self.node(profile)), "export is the plain effect, bit for bit")
    }

    func testTheProfileTravelsInTheChainAndDefaultsLeaveOldDocumentsAlone() throws {
        let plain = FxChain(nodes: [Self.node(nil)])
        let json = AudioFx.serializeChain(plain)
        for word in ["learn_source", "listen", "profile"] { XCTAssertFalse(json.contains(word), word) }
        XCTAssertEqual(AudioFx.serializeChain(try AudioFx.parseChain(json)), json, "an older chain is written back unchanged")
        let profile = (0..<NoiseProfile.bins).map { Double($0 % 50) / 10 - 60 }
        var node = Self.node(profile, listen: true)
        node.paramsA?["learn_source"] = .string("range")
        let saved = AudioFx.serializeChain(FxChain(nodes: [node]))
        XCTAssertTrue(saved.contains("\"learn_source\":\"range\"") && saved.contains("\"listen\":\"on\"") && saved.contains("\"profile\":["))
        XCTAssertEqual(try AudioFx.parseChain(saved).nodes.first?.noiseProfile, profile)
        var parsedBack = node
        parsedBack.enabled = true     // a chain read from disk says so for every module
        XCTAssertEqual(try AudioFx.parseChain(saved), FxChain(nodes: [parsedBack]))
        let bad = saved.replacingOccurrences(of: "\"profile\":[", with: "\"profile\":[1,")
        XCTAssertThrowsError(try AudioFx.parseChain(bad)) { XCTAssertTrue("\($0)".contains("noise profile")) }
    }
}
