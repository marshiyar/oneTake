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
import MpvfxAudioGraph

/// Additive catalog table: older libraries acquire it without rewriting their catalog or media.
public enum AudioFxPresetLibrary {
    private static func database(_ path: String) throws -> CatalogDatabase {
        guard !path.utf8.contains(0) else { throw LibraryCatalogError("Embedded NUL is not permitted") }
        try SQLiteRequirements.verifyOnce()
        let db = try CatalogDatabase(path, create: false)
        guard try db.query("PRAGMA user_version") == "1" else { throw LibraryCatalogError("Unsupported library catalog version") }
        try db.exec("CREATE TABLE IF NOT EXISTS audioFxPresets(id TEXT PRIMARY KEY, name TEXT NOT NULL, chain TEXT NOT NULL)")
        return db
    }
    public static func save(_ path: String, name: String, node: FxNode) throws {
        guard !path.utf8.contains(0), !name.utf8.contains(0) else { throw LibraryCatalogError("Embedded NUL is not permitted") }
        let title = try libraryTitle(name)
        guard AudioFx.definition(node.type) != nil else { throw LibraryCatalogError("Unknown audio effect") }
        let captured = FxNode(type: node.type, version: node.version ?? 1, params: node.params)
        let chain = AudioFx.serializeChain(FxChain(version: node.version ?? 1, nodes: [captured]))
        try database(path).query("INSERT INTO audioFxPresets VALUES(?1,?2,?3)", [UUID().uuidString.lowercased(), title, chain])
    }
    public static func presets(_ path: String) throws -> [AudioFxModulePreset] {
        let text = try database(path).query("SELECT json_group_array(json_object('id',id,'name',name,'chain',chain)) FROM (SELECT * FROM audioFxPresets ORDER BY name,id)")
        guard let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: String]] else {
            throw LibraryCatalogError("Invalid audio preset catalog")
        }
        return try rows.map { row in
            guard let id = row["id"], let name = row["name"], let json = row["chain"],
                  let node = try AudioFx.parseChain(json).nodes.first else { throw LibraryCatalogError("Invalid audio preset") }
            return AudioFxModulePreset(id: id, label: name, type: node.type, version: node.version ?? 1,
                                       params: node.params ?? AudioFx.defaultParams(node.type, version: node.version ?? 1))
        }
    }
}
