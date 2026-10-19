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

final class DesktopPreferencesTests: XCTestCase {
    private var dir = ""
    override func setUp() { dir = NSTemporaryDirectory() + "mpvfx-prefs-" + UUID().uuidString }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func testRenderSettingsAndHiddenRendersSurviveRelaunch() {
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertNil(prefs.renderSettings)
        XCTAssertEqual(prefs.hiddenRenders(projectId: "p1"), [])
        prefs.renderSettings = .object(["format": .string("webm"), "fps": .number(60)])
        prefs.setHiddenRenders(projectId: "p1", ["a", "b", "a"])
        let again = DesktopPreferences(userData: dir)
        XCTAssertEqual(again.renderSettings, .object(["format": .string("webm"), "fps": .number(60)]))
        XCTAssertEqual(again.hiddenRenders(projectId: "p1"), ["a", "b"])
        XCTAssertEqual(again.hiddenRenders(projectId: "p2"), [])
        XCTAssertNotNil(again.value("hf-studio-hidden-renders:p1"))
        again.renderSettings = nil
        XCTAssertNil(DesktopPreferences(userData: dir).renderSettings)
    }

    func testKeepsTheNewestTwoHundredHiddenRenders() {
        let prefs = DesktopPreferences(userData: dir)
        prefs.setHiddenRenders(projectId: "p", (0..<250).map { "r\($0)" })
        let ids = DesktopPreferences(userData: dir).hiddenRenders(projectId: "p")
        XCTAssertEqual(ids.count, 200)
        XCTAssertEqual(ids.first, "r50"); XCTAssertEqual(ids.last, "r249")
    }

    func testAMalformedFileFallsBackToNothingStored() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{not json".write(toFile: dir + "/preferences.json", atomically: true, encoding: .utf8)
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertNil(prefs.renderSettings)
        prefs.renderSettings = .object(["format": .string("mp4")])
        XCTAssertEqual(DesktopPreferences(userData: dir).renderSettings, .object(["format": .string("mp4")]))
    }
}
