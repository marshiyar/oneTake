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
import MpvfxTheme
import MpvfxAudioGraph

/// `ThemeTokens.fxPresetHues` (MpvfxTheme) is keyed by the ids of `AudioFxPresets.all` (MpvfxAudioGraph). Neither
/// module may import the other, so the match is checked here, in a test target that sees both.
final class FxPresetIdParityTests: XCTestCase {
    /// The ids each side lacks, sorted, so a failure names them.
    static func mismatch(presets: [String], keys: [String]) -> (missingHue: [String], hueWithoutPreset: [String]) {
        let p = Set(presets), k = Set(keys)
        return (p.subtracting(k).sorted(), k.subtracting(p).sorted())
    }

    func testEveryPresetHasAHueAndEveryHueHasAPreset() {
        let presets = AudioFxPresets.all.map(\.id)
        XCTAssertEqual(Set(presets).count, presets.count, "preset ids are unique")
        let m = Self.mismatch(presets: presets, keys: Array(ThemeTokens.fxPresetHues.keys))
        XCTAssertEqual(m.missingHue, [], "presets with no entry in ThemeTokens.fxPresetHues: \(m.missingHue)")
        XCTAssertEqual(m.hueWithoutPreset, [], "ThemeTokens.fxPresetHues keys with no preset in AudioFxPresets.all: \(m.hueWithoutPreset)")
    }

    func testMismatchNamesTheIdsMissingFromEachSide() {
        let m = Self.mismatch(presets: ["hall", "giant", "voice-clean"], keys: ["voice-clean", "old-preset", "hall"])
        XCTAssertEqual(m.missingHue, ["giant"])
        XCTAssertEqual(m.hueWithoutPreset, ["old-preset"])
    }
}
