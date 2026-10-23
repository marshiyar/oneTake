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
import MpvfxPanels
@testable import MpvfxDesktop

final class RenderPresetStoreTests: XCTestCase {
    func directory() throws -> String {
        let path = NSTemporaryDirectory() + "mpvfx-render-presets-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testA1SaveUpdateAndDeletePersistEverySettingAndLeaveNoTemporaryFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RenderPresetStore(userData: dir)
        XCTAssertEqual(try store.load(), [])
        var settings = RenderSettingsModel()
        settings.format = "mov"; settings.quality = "high"; settings.fps = 60
        settings.resolution = "custom"; settings.customWidth = 1280; settings.customHeight = 720
        try store.save(name: "Social", settings: settings)
        XCTAssertEqual(try RenderPresetStore(userData: dir).load(), [.init(name: "Social", settings: settings)])
        settings.fps = 24
        try store.save(name: "Social", settings: settings)
        XCTAssertEqual(try store.load(), [.init(name: "Social", settings: settings)])
        try store.save(name: "Archive", settings: RenderSettingsModel())
        try store.delete(name: "Social")
        XCTAssertEqual(try store.load().map(\.name), ["Archive"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["render-presets.json"])
    }

    func testA1CorruptFileIsReportedWithItsPathAndNeitherSaveNorDeleteOverwritesIt() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RenderPresetStore(userData: dir)
        for contents in ["{broken", "{}", "[{}]"] {
            let bytes = Data(contents.utf8)
            try bytes.write(to: URL(fileURLWithPath: store.path))
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertTrue(String(describing: error).contains(store.path))
            }
            XCTAssertThrowsError(try store.save(name: "New", settings: RenderSettingsModel()))
            XCTAssertThrowsError(try store.delete(name: "New"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), bytes)
        }
    }

    func testA1MalformedNumericSettingsAndDuplicateNamesAreCorruptAndPreserved() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RenderPresetStore(userData: dir)
        var settings = RenderSettingsModel(); settings.fps = 1e100
        let invalid = RenderPreset(name: "Bad", settings: settings)
        let duplicate = RenderPreset(name: "Same", settings: RenderSettingsModel())
        for presets in [[invalid], [duplicate, duplicate]] {
            let bytes = try JSONEncoder().encode(presets)
            try bytes.write(to: URL(fileURLWithPath: store.path))
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(name: "New", settings: RenderSettingsModel()))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), bytes)
        }
    }

    func testA2UnsupportedFormatIsPreservedForThePanelToExplain() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RenderPresetStore(userData: dir)
        var settings = RenderSettingsModel(); settings.format = "webm"
        try store.save(name: "Old WebM", settings: settings)
        let preset = try XCTUnwrap(store.load().first)
        XCTAssertEqual(preset.settings, settings)
        XCTAssertEqual(preset.unavailableReason, "Format webm is not supported yet")
    }
}
