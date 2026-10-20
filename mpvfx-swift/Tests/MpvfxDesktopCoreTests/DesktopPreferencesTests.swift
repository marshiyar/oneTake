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

    /// Issue #32: the Settings window's values persist in `<userData>/preferences.json` beside the other keys.
    func testSettingsWindowValuesSurviveRelaunch() throws {
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertNil(prefs.audioOutputDevice); XCTAssertNil(prefs.previewCacheMB); XCTAssertNil(prefs.defaultExportFolder)
        prefs.renderSettings = .object(["format": .string("mp4")])
        prefs.audioOutputDevice = "alsa_output.usb-Headset.analog-stereo"
        prefs.previewCacheMB = 2048
        prefs.defaultExportFolder = "/home/me/Exports"
        let again = DesktopPreferences(userData: dir)
        XCTAssertEqual(again.audioOutputDevice, "alsa_output.usb-Headset.analog-stereo")
        XCTAssertEqual(again.previewCacheMB, 2048)
        XCTAssertEqual(again.defaultExportFolder, "/home/me/Exports")
        XCTAssertEqual(again.renderSettings, .object(["format": .string("mp4")]), "other keys are kept")
        let text = try String(contentsOfFile: dir + "/preferences.json", encoding: .utf8)
        XCTAssertTrue(text.contains("\"mpvfx-preview-cache-mb\":2048"), text)

        // Back to the defaults: the keys are removed.
        again.audioOutputDevice = nil; again.previewCacheMB = nil; again.defaultExportFolder = nil
        let cleared = DesktopPreferences(userData: dir)
        XCTAssertNil(cleared.audioOutputDevice); XCTAssertNil(cleared.previewCacheMB); XCTAssertNil(cleared.defaultExportFolder)
        XCTAssertNil(cleared.value(DesktopPreferences.previewCacheKey))
    }

    /// Values a hand-edited file may hold that the window would never write read as the default.
    func testInvalidSettingsReadAsDefaults() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"mpvfx-audio-output-device":"","mpvfx-preview-cache-mb":12,"mpvfx-default-export-folder":"relative/dir"}"#
            .write(toFile: dir + "/preferences.json", atomically: true, encoding: .utf8)
        let prefs = DesktopPreferences(userData: dir)
        XCTAssertNil(prefs.audioOutputDevice)
        XCTAssertNil(prefs.previewCacheMB, "below the accepted range")
        XCTAssertNil(prefs.defaultExportFolder, "not absolute")
        prefs.previewCacheMB = 1_000_000
        XCTAssertNil(DesktopPreferences(userData: dir).value(DesktopPreferences.previewCacheKey), "out of range is not stored")
        prefs.previewCacheMB = 512
        XCTAssertEqual(DesktopPreferences(userData: dir).previewCacheMB, 512)
    }

    /// Issue #32: every change goes through the durable write (temp file in the same folder, then rename): the file
    /// always holds a whole snapshot and no temp file is left behind.
    func testWritesAreDurableAndLeaveNoTempFile() throws {
        let prefs = DesktopPreferences(userData: dir)
        prefs.previewCacheMB = 512
        prefs.previewCacheMB = 1024
        prefs.previewCacheMB = 531
        XCTAssertNil(prefs.lastWriteError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["preferences.json"])
        XCTAssertEqual(DesktopPreferences(userData: dir).previewCacheMB, 531)
    }

    /// A write that fails is reported, not ignored; the value still holds for this run, and the next good write clears it.
    func testAFailedWriteIsReported() throws {
        // A folder where the file should be: the rename onto it fails.
        try FileManager.default.createDirectory(atPath: dir + "/preferences.json", withIntermediateDirectories: true)
        let prefs = DesktopPreferences(userData: dir)
        prefs.previewCacheMB = 1024
        let error = try XCTUnwrap(prefs.lastWriteError)
        XCTAssertTrue(error.path.hasSuffix("preferences.json"), "\(error)")
        XCTAssertEqual(prefs.previewCacheMB, 1024, "kept in memory")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["preferences.json"], "no temp file left")

        try FileManager.default.removeItem(atPath: dir + "/preferences.json")
        prefs.previewCacheMB = 2048
        XCTAssertNil(prefs.lastWriteError)
        XCTAssertEqual(DesktopPreferences(userData: dir).previewCacheMB, 2048)
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
