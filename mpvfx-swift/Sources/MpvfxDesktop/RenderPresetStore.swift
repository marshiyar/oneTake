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
import MpvfxDesktopCore
import MpvfxPanels

struct RenderPresetStoreError: Error, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "Render presets at \(path): \(reason)" }
}

/// Re-read before each edit so an unreadable file is never replaced with an empty library.
/// Used on the UI thread, like the Renders settings themselves.
struct RenderPresetStore {
    let path: String
    init(userData: String) { path = (userData as NSString).appendingPathComponent("render-presets.json") }

    func load() throws -> [RenderPreset] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            let presets = try JSONDecoder().decode([RenderPreset].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard Set(presets.map(\.name)).count == presets.count,
                  presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.hasValidSettings }) else {
                throw RenderPresetStoreError(path: path, reason: "invalid settings, duplicate or empty names; file left untouched")
            }
            return presets
        } catch {
            throw RenderPresetStoreError(path: path, reason: "could not read the file; file left untouched")
        }
    }

    @discardableResult
    func save(name: String, settings: RenderSettingsModel) throws -> [RenderPreset] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenderPresetStoreError(path: path, reason: "enter a preset name") }
        guard RenderPreset(name: name, settings: settings).hasValidSettings else {
            throw RenderPresetStoreError(path: path, reason: "invalid render settings")
        }
        var presets = try load()
        if let index = presets.firstIndex(where: { $0.name == name }) {
            presets[index].settings = settings
        } else { presets.append(RenderPreset(name: name, settings: settings)) }
        try write(presets)
        return presets
    }

    @discardableResult
    func delete(name: String) throws -> [RenderPreset] {
        let presets = try load().filter { $0.name != name }
        try write(presets)
        return presets
    }

    private func write(_ presets: [RenderPreset]) throws {
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try NativeDurableWrite().write(try JSONEncoder().encode(presets), to: path)
        } catch { throw RenderPresetStoreError(path: path, reason: "could not save the presets") }
    }
}
