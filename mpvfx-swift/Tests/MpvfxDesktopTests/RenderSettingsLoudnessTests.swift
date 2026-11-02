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
import MpvfxAudioGraph
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxRuntime
import MpvfxShared
@testable import MpvfxDesktop

/// The Renders tab's loudness choice (#315): Off writes nothing and exports the mix untouched; a target is stored as
/// version 1 with its true-peak ceiling and reaches the export as a MasterLoudnessTarget.
final class RenderSettingsLoudnessTests: XCTestCase {
    private let canvas = NativeCanvas(width: 1920, height: 1080, background: "#000000")

    private func parsed(_ text: String) throws -> MpvfxDesktopCore.JSONValue { try MpvfxDesktopCore.JSONValue.parse(text) }

    func testDefaultLoudnessIsOffAndWritesNoLoudnessKey() {
        let model = RenderSettingsModel()
        XCTAssertNil(model.loudness)
        XCTAssertNil(RenderSettingsBridge.json(model)["loudness"], "Off writes nothing, so settings saved without loudness are unchanged")
        XCTAssertNil(RenderSettingsBridge.model(RenderSettingsBridge.json(model)).loudness)
        XCTAssertNil(RenderSettingsBridge.exportSettings(model, canvas: canvas).loudness)
    }

    func testOffKeepsAChosenCeilingOutOfTheSavedSettings() {
        var model = RenderSettingsModel()
        model.truePeak = -2
        XCTAssertNil(RenderSettingsBridge.json(model)["loudness"], "a ceiling alone is not saved: Loudness is still Off")
        XCTAssertNil(RenderSettingsBridge.exportSettings(model, canvas: canvas).loudness)
    }

    func testTargetRoundTripsAndExportsWithTheDefaultCeiling() {
        var model = RenderSettingsModel()
        model.loudness = -23
        let stored = RenderSettingsBridge.json(model)["loudness"]
        XCTAssertEqual(stored?["v"]?.number, 1)
        XCTAssertEqual(stored?["target"]?.number, -23)
        XCTAssertEqual(stored?["truePeak"]?.number, -1)
        XCTAssertEqual(RenderSettingsBridge.model(RenderSettingsBridge.json(model)), model)
        XCTAssertEqual(RenderSettingsBridge.exportSettings(model, canvas: canvas).loudness,
                       MasterLoudnessTarget(target: -23, truePeak: -1))
    }

    func testCeilingOtherThanTheDefaultRoundTripsAndExports() {
        var model = RenderSettingsModel()
        model.loudness = -23; model.truePeak = -2
        XCTAssertEqual(RenderSettingsBridge.json(model)["loudness"]?["truePeak"]?.number, -2)
        let reread = RenderSettingsBridge.model(RenderSettingsBridge.json(model))
        XCTAssertEqual(reread, model)
        XCTAssertEqual(reread.truePeak, -2)
        XCTAssertEqual(RenderSettingsBridge.exportSettings(model, canvas: canvas).loudness,
                       MasterLoudnessTarget(target: -23, truePeak: -2))
    }

    func testStoredDefaultCeilingReadsBackAsNil() throws {
        let model = RenderSettingsBridge.model(try parsed(#"{"loudness":{"v":1,"target":-16,"truePeak":-1}}"#))
        XCTAssertEqual(model.loudness, -16)
        XCTAssertNil(model.truePeak, "the default ceiling is stored as nil, so the Renders tab shows the default")
    }

    func testStoredLoudnessThatIsNotValidVersionOneReadsAsOff() throws {
        // A later version, a target outside -50...-5 LUFS, a ceiling outside -9...0 dBTP, and a missing ceiling
        // are not read: the render stays Off, and the other settings still load.
        let stored = [
            try parsed(#"{"format":"mov","loudness":{"v":2,"target":-23,"truePeak":-2}}"#),
            try parsed(#"{"format":"mov","loudness":{"v":1,"target":4,"truePeak":-1}}"#),
            try parsed(#"{"format":"mov","loudness":{"v":1,"target":-23,"truePeak":-12}}"#),
            try parsed(#"{"format":"mov","loudness":{"v":1,"target":-23}}"#),
        ]
        for value in stored {
            let model = RenderSettingsBridge.model(value)
            XCTAssertNil(model.loudness)
            XCTAssertNil(model.truePeak)
            XCTAssertEqual(model.format, "mov")
            XCTAssertNil(RenderSettingsBridge.exportSettings(model, canvas: canvas).loudness)
        }
    }
}
