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

final class CaptionPreferencesTests: XCTestCase {
    private let key = "mpvfx-caption-reading-rate"

    func testReadingRateDefaultsAndTheRangeEndsSurviveRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caption-prefs-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertEqual(prefs.captionReadingRate, 17)
        prefs.captionReadingRate = 5
        XCTAssertEqual(DesktopPreferences(userData: dir).captionReadingRate, 5)
        prefs.captionReadingRate = 40
        let next = DesktopPreferences(userData: dir)
        XCTAssertEqual(next.captionReadingRate, 40)
        XCTAssertNil(next.lastWriteError)
    }

    func testOutOfRangeReadingRateIsNotStored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caption-prefs-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        for bad in [4, 41] {
            prefs.captionReadingRate = bad
            XCTAssertNil(DesktopPreferences(userData: dir).value(key), "\(bad) is not stored")
            XCTAssertEqual(prefs.captionReadingRate, 17, "\(bad) reads as the default")
        }
    }

    func testMalformedStoredReadingRateReadsAsTheDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caption-prefs-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let prefs = DesktopPreferences(userData: dir)
        prefs.set(key, .number(4))
        XCTAssertEqual(DesktopPreferences(userData: dir).captionReadingRate, 17, "4 is below the range")
        prefs.set(key, .number(41))
        XCTAssertEqual(DesktopPreferences(userData: dir).captionReadingRate, 17, "41 is above the range")
        prefs.set(key, .number(17.5))
        XCTAssertEqual(DesktopPreferences(userData: dir).captionReadingRate, 17, "17.5 is not a whole number")
        prefs.set(key, .number(.nan))
        XCTAssertEqual(DesktopPreferences(userData: dir).captionReadingRate, 17, "NaN reads as the default")
        prefs.set(key, .string("25"))
        XCTAssertEqual(DesktopPreferences(userData: dir).captionReadingRate, 17, "a string reads as the default")
        XCTAssertNil(prefs.lastWriteError)
    }
}
