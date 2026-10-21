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
@testable import MpvfxRuntime

final class AudioFxPresetLibraryTests: XCTestCase {
    func testSavedActiveSettingsSurviveReopenAndLoadOnAnotherClip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Catalog.sqlite").path
        let original = try LibraryCatalog.command(path, "create", [UUID().uuidString, "Library"])
        XCTAssertEqual(try AudioFxPresetLibrary.presets(path), [])
        XCTAssertEqual(try LibraryCatalog.command(path, "read", []), original)
        var source = FxNode(type: "compressor", version: 2, id: "source", params: AudioFx.defaultParams("compressor", version: 2))
        source.selectSlotB(true)
        source.params?["threshold"] = .number(-29)
        source.params?["knee"] = .number(8)
        try AudioFxPresetLibrary.save(path, name: "Voice's settings", node: source)
        let saved = try XCTUnwrap(AudioFxPresetLibrary.presets(path).first)
        let target = FxNode(type: "compressor", version: 2, id: "other-clip", params: AudioFx.defaultParams("compressor", version: 2))
        let loaded = saved.applying(to: target)
        XCTAssertEqual(loaded.params, source.params)
        XCTAssertEqual(loaded.id, "other-clip")
        XCTAssertEqual(loaded.paramsB, nil)
        XCTAssertEqual(saved.label, "Voice's settings")
        XCTAssertEqual(try LibraryCatalog.command(path, "read", []).contains("Library"), true)
    }
}
