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
@testable import MpvfxDesktopCore

final class VoicePreferencesTests: XCTestCase {
    func testInputAndCountInSurviveRelaunchAndInvalidCountFallsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-prefs-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertEqual(prefs.voiceCountIn, 3)
        prefs.audioInputDevice = "microphone:one"
        prefs.voiceCountIn = 0
        let next = DesktopPreferences(userData: dir)
        XCTAssertEqual(next.audioInputDevice, "microphone:one")
        XCTAssertEqual(next.voiceCountIn, 0)
        next.set("mpvfx-voice-count-in", .number(8))
        XCTAssertEqual(next.voiceCountIn, 3)
        XCTAssertNil(next.lastWriteError)
    }

    func testVoicePreRollDefaultsToTwoSurvivesRelaunchAndInvalidValueFallsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-pre-roll-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertEqual(prefs.voicePreRoll, 2)
        prefs.voicePreRoll = 4
        XCTAssertEqual(DesktopPreferences(userData: dir).voicePreRoll, 4)
        prefs.voicePreRoll = 0
        let next = DesktopPreferences(userData: dir)
        XCTAssertEqual(next.voicePreRoll, 0)
        next.set("mpvfx-voice-pre-roll", .number(8))
        XCTAssertEqual(next.voicePreRoll, 2)
        next.set("mpvfx-voice-pre-roll", .number(2.5))
        XCTAssertEqual(next.voicePreRoll, 2)
        next.set("mpvfx-voice-pre-roll", .string("3"))
        XCTAssertEqual(next.voicePreRoll, 2)
        next.voicePreRoll = 9
        XCTAssertNil(next.value("mpvfx-voice-pre-roll"), "an out-of-range value removes the key")
        XCTAssertEqual(next.voicePreRoll, 2)
        XCTAssertNil(next.lastWriteError)
    }
}
