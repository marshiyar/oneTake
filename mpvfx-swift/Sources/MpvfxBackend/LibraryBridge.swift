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
// The shell's library protocol (MpvfxDesktopCore.LibraryService) on the runtime's SQLite-backed library.
import Foundation
import MpvfxDesktopCore
import MpvfxRuntime
import MpvfxShared
import struct MpvfxAudioGraph.FxNode
import struct MpvfxAudioGraph.AudioFxModulePreset

final class LibraryBridge: MpvfxDesktopCore.LibraryService, @unchecked Sendable {
    let service: MpvfxRuntime.LibraryService
    init(_ service: MpvfxRuntime.LibraryService) { self.service = service }

    func audioFxPresets(projectId: String) throws -> [AudioFxModulePreset] {
        do { return try service.audioFxPresets(projectId: projectId) } catch { throw RuntimeDesktopBackend.desktopError(error) }
    }
    func saveAudioFxPreset(projectId: String, name: String, node: FxNode) throws {
        do { try service.saveAudioFxPreset(projectId: projectId, name: name, node: node) } catch { throw RuntimeDesktopBackend.desktopError(error) }
    }
    func views() async throws -> JSONValue {
        let views = await service.views()
        let data = try JSONEncoder().encode(views)
        return try JSONValue.parse(String(decoding: data, as: UTF8.self))
    }
    func create(root: String) async throws -> String { try await map { try await service.create(root) } }
    func open(root: String) async throws -> String { try await map { try await service.open(root) } }
    func createEvent(libraryId: String, name: String) async throws { try await map { try await service.createEvent(libraryId, name) } }
    func createProject(libraryId: String, eventId: String, name: String) async throws -> String {
        try await map { try await service.createProject(libraryId, eventId, name) }
    }
    func importMedia(libraryId: String, eventId: String, paths: [String], mode: String, projectId: String?) async throws -> [(String, String)] {
        guard let m = LibraryAssetMode(rawValue: mode) else { throw DesktopError("Invalid import mode") }
        let r = try await map { try await service.import(libraryId, LibraryImportTarget(eventId: eventId, projectId: projectId), paths, m) }
        return r.invalid.map { ($0.name, $0.reason) }
    }
    func attach(libraryId: String, projectId: String, assetId: String) async throws -> String {
        try await map { try await service.attach(libraryId, projectId, assetId) }
    }
    func relink(libraryId: String, assetId: String, path: String) async throws { try await map { try await service.relink(libraryId, assetId, path) } }
    func root(libraryId: String) throws -> String {
        do { return try service.root(libraryId) } catch { throw RuntimeDesktopBackend.desktopError(error) }
    }
    func saveOutput(libraryId: String, jobId: String, destination: String, overwrite: Bool) async throws {
        try await map { try await service.saveOutput(libraryId, jobId, destination, replaceApproved: overwrite) }
    }

    func renameEvent(libraryId: String, eventId: String, name: String) async throws {
        try await map { try await service.renameEvent(libraryId, eventId, name) }
    }
    func renameProject(libraryId: String, projectId: String, name: String) async throws {
        try await map { try await service.renameProject(libraryId, projectId, name) }
    }

    private func map<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw RuntimeDesktopBackend.desktopError(error) }
    }
}
