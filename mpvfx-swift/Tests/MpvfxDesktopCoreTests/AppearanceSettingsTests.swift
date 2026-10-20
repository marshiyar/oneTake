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
import MpvfxDesktopCore
import MpvfxTheme

final class AppearanceSettingsTests: XCTestCase {
    var dir: String!
    override func setUp() {
        dir = NSTemporaryDirectory() + "mpvfx-appearance-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir); Theme.setMode(.dark) }

    func testDefaultIsDarkUntilTheUserPicks() {
        var osDark = false
        let s = AppearanceSettings(preferences: DesktopPreferences(userData: dir), systemPrefersDark: { osDark })
        XCTAssertEqual(s.appearance, .dark)
        s.apply(); XCTAssertEqual(Theme.mode, .dark, "dark even when the OS is light")
        osDark = true; s.systemAppearanceChanged(); XCTAssertEqual(Theme.mode, .dark)
        osDark = false; s.systemAppearanceChanged(); XCTAssertEqual(Theme.mode, .dark)
        s.set(.system); XCTAssertEqual(Theme.mode, .light, "System follows the OS once picked")
    }

    func testNothingIsWrittenUntilTheUserPicks() {
        AppearanceSettings(preferences: DesktopPreferences(userData: dir), systemPrefersDark: { false }).apply()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/preferences.json"))
    }

    func testChoicePersistsAndSwitchesLive() throws {
        var osDark = true
        var modes: [ThemeMode] = []
        let id = Theme.addObserver { modes.append($0) }
        defer { Theme.removeObserver(id) }
        let s = AppearanceSettings(preferences: DesktopPreferences(userData: dir), systemPrefersDark: { osDark })
        s.apply(); XCTAssertEqual(Theme.mode, .dark)
        s.set(.light); XCTAssertEqual(Theme.mode, .light)
        osDark = false; s.systemAppearanceChanged(); osDark = true; s.systemAppearanceChanged()
        XCTAssertEqual(Theme.mode, .light, "a forced appearance ignores the OS")
        XCTAssertEqual(modes, [.light])
        let json = try String(contentsOfFile: dir + "/preferences.json", encoding: .utf8)
        XCTAssertTrue(json.contains("\"mpvfx-appearance\""), json); XCTAssertTrue(json.contains("\"light\""), json)
        // A new session (restart) reads it back.
        let again = AppearanceSettings(preferences: DesktopPreferences(userData: dir), systemPrefersDark: { true })
        XCTAssertEqual(again.appearance, .light); XCTAssertEqual(again.mode, .light)
        again.set(.system); XCTAssertEqual(Theme.mode, .dark)
        XCTAssertEqual(AppearanceSettings(preferences: DesktopPreferences(userData: dir), systemPrefersDark: { true }).appearance, .system)
    }

    func testOverrideDoesNotPersistAndBadValuesFallBack() throws {
        let prefs = DesktopPreferences(userData: dir)
        prefs.set(ThemeAppearance.preferenceKey, .string("dark"))
        let o = AppearanceSettings(preferences: prefs, override: "LIGHT", systemPrefersDark: { true })
        XCTAssertTrue(o.isOverridden); XCTAssertEqual(o.appearance, .light)
        o.set(.system)
        XCTAssertEqual(DesktopPreferences(userData: dir).value(ThemeAppearance.preferenceKey)?.string, "dark")
        let bad = AppearanceSettings(preferences: prefs, override: "sepia", systemPrefersDark: { true })
        XCTAssertFalse(bad.isOverridden); XCTAssertEqual(bad.appearance, .dark)
        prefs.set(ThemeAppearance.preferenceKey, .string("sepia"))
        XCTAssertEqual(AppearanceSettings(preferences: prefs, systemPrefersDark: { true }).appearance, .dark)
        XCTAssertEqual(AppearanceSettings(preferences: nil, systemPrefersDark: { false }).mode, .dark)
    }
}
