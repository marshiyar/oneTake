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

final class VoiceCleanupTests: XCTestCase {
    func testOneSettingAddsNoiseReductionAndLevellingWithoutReplacingOtherEffects() {
        let original = FxChain(nodes: [FxNode(type: "gain", id: "n1", params: AudioFx.defaultParams("gain"))])
        let cleaned = VoiceCleanup.apply(original)
        XCTAssertEqual(cleaned.nodes.first, original.nodes.first)
        XCTAssertEqual(cleaned.nodes.dropFirst().map(\.type), ["denoise", "compressor"])
        XCTAssertEqual(Set(cleaned.nodes.compactMap(\.id)).count, 3)
        XCTAssertEqual(VoiceCleanup.apply(cleaned), cleaned, "applying twice must not stack clean-up")
        XCTAssertEqual(VoiceCleanup.remove(cleaned), original)
    }

    func testStrengthAndBeforeAfterRoundTripInTheExistingValidatedChain() throws {
        let cleaned = VoiceCleanup.settingStrength(VoiceCleanup.apply(FxChain()), 0.37)
        let before = VoiceCleanup.settingEnabled(cleaned, false)
        let restored = try AudioFx.parseChain(AudioFx.serializeChain(before))
        XCTAssertFalse(VoiceCleanup.isEnabled(restored))
        XCTAssertEqual(VoiceCleanup.strength(restored), 0.37)
        XCTAssertEqual(AudioFx.serializeChain(VoiceCleanup.settingEnabled(restored, true)), AudioFx.serializeChain(cleaned))
        XCTAssertEqual(VoiceCleanup.strength(VoiceCleanup.settingStrength(cleaned, 10)), 1)
        XCTAssertEqual(VoiceCleanup.strength(VoiceCleanup.settingStrength(cleaned, -10)), 0)
        XCTAssertEqual(VoiceCleanup.strength(VoiceCleanup.settingStrength(cleaned, .nan)), VoiceCleanup.defaultStrength)
    }

    func testFullStrengthRoundTripsWithFullWetCleanupStages() throws {
        let full = VoiceCleanup.settingStrength(VoiceCleanup.apply(FxChain()), 1)
        let restored = try AudioFx.parseChain(AudioFx.serializeChain(full))
        XCTAssertTrue(restored.nodes.allSatisfy { $0.presetAmount == nil })
        XCTAssertEqual(VoiceCleanup.strength(restored), 1)
        let bypassed = VoiceCleanup.settingEnabled(restored, false)
        let reopened = try AudioFx.parseChain(AudioFx.serializeChain(bypassed))
        XCTAssertEqual(VoiceCleanup.strength(reopened), 1)
        XCTAssertEqual(VoiceCleanup.strength(VoiceCleanup.settingEnabled(reopened, true)), 1)
    }

    func testZeroStrengthPreservesEveryOriginalSampleIncludingTheBeginningAndEnd() throws {
        let rate = 8000.0
        let signal = (0..<8000).map { Float(($0 * 97 % 997) - 498) / 1000 }
        func render(_ chain: FxChain) -> [Float] {
            AudioGraphRenderer.renderOffline(AudioGraphProject(duration: 1, sampleRate: rate, tracks: [
                AudioGraphTrack(id: "voice", stem: [signal, signal], start: 0, end: 1, fxChain: chain),
            ]))
        }
        let zero = VoiceCleanup.settingStrength(VoiceCleanup.apply(FxChain()), 0)
        let reopened = try AudioFx.parseChain(AudioFx.serializeChain(zero))
        XCTAssertEqual(VoiceCleanup.strength(reopened), 0)
        XCTAssertEqual(render(reopened), render(FxChain()), "zero strength must not advance or truncate the dry input")
    }

    func testPlaybackChunksEqualExportAndBeforeRestoresTheOriginalSamples() {
        let rate = 8000.0, duration = 1.0
        let signal = (0..<Int(rate * duration)).map { i -> Float in
            let level = i < 4000 ? 0.01 : 0.35
            return Float(level * sin(2 * Double.pi * 220 * Double(i) / rate))
        }
        func project(_ chain: FxChain) -> AudioGraphProject {
            AudioGraphProject(duration: duration, sampleRate: rate, tracks: [
                AudioGraphTrack(id: "voice", stem: [signal, signal], start: 0, end: duration, fxChain: chain),
            ])
        }
        let chain = VoiceCleanup.apply(FxChain())
        let export = AudioGraphRenderer.renderOffline(project(chain))
        let playback = AudioGraphRenderer(project(chain))
        var heard: [Float] = []
        while playback.position < playback.totalFrames { heard += playback.render(237) }
        XCTAssertEqual(heard, export, "the same clean-up graph must process playback and export")
        let dry = AudioGraphRenderer.renderOffline(project(FxChain()))
        XCTAssertNotEqual(export, dry, "noise reduction and levelling must process the signal")
        XCTAssertEqual(AudioGraphRenderer.renderOffline(project(VoiceCleanup.settingEnabled(chain, false))), dry)
        XCTAssertTrue(export.allSatisfy(\.isFinite))
    }
}
