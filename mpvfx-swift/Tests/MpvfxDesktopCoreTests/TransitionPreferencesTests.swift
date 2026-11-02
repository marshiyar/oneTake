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

/// The default cut transition length in Settings (issue #266): 15 frames until changed, 1...120 kept, saved through the
/// durable write path and read back on the next launch; a stored value outside the range reads as the default.
final class TransitionPreferencesTests: XCTestCase {
    func testDefaultLengthSurvivesRelaunchAndAnOutOfRangeValueFallsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transition-prefs-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertEqual(prefs.defaultTransitionFrames, 15)
        prefs.defaultTransitionFrames = 30
        XCTAssertEqual(DesktopPreferences(userData: dir).defaultTransitionFrames, 30, "saved")
        prefs.defaultTransitionFrames = 120
        XCTAssertEqual(DesktopPreferences(userData: dir).defaultTransitionFrames, 120, "the top of the range")
        prefs.defaultTransitionFrames = 1
        XCTAssertEqual(DesktopPreferences(userData: dir).defaultTransitionFrames, 1, "the bottom of the range")
        let next = DesktopPreferences(userData: dir)
        next.set(DesktopPreferences.defaultTransitionFramesKey, .number(121))
        XCTAssertEqual(next.defaultTransitionFrames, 15, "above the range")
        next.set(DesktopPreferences.defaultTransitionFramesKey, .number(0))
        XCTAssertEqual(next.defaultTransitionFrames, 15, "below the range")
        next.set(DesktopPreferences.defaultTransitionFramesKey, .number(12.5))
        XCTAssertEqual(next.defaultTransitionFrames, 15, "not a whole number of frames")
        next.set(DesktopPreferences.defaultTransitionFramesKey, .string("lots"))
        XCTAssertEqual(next.defaultTransitionFrames, 15, "not a number")
        XCTAssertNil(next.lastWriteError)
    }

    func testAnOutOfRangeSetterIsNotWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transition-prefs-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        prefs.defaultTransitionFrames = 40
        prefs.defaultTransitionFrames = 500
        XCTAssertEqual(DesktopPreferences(userData: dir).defaultTransitionFrames, 15, "an invalid write clears the setting")
    }
}
