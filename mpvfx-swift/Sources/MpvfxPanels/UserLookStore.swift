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
import MpvfxShared

/// A look contains ordinary clip effects, with an animated grade sampled at the saved playhead.
public struct UserLook: Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var effects: [NativeClipEffect]
    public init(id: String = UUID().uuidString.lowercased(), name: String, effects: [NativeClipEffect]) {
        self.id = id; self.name = name; self.effects = effects
    }
}

public enum UserLookError: Error, Equatable, LocalizedError {
    case invalidName, missingLook, invalidCatalog, invalidEffects, noVisualSelection, lockedClip(String)
    case missingLut(look: String, path: String), writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Name the look using 1 to 120 characters."
        case .missingLook: return "The saved look is no longer available. Choose another look."
        case .invalidCatalog: return "The saved looks file cannot be read. Restore it from a backup before saving another look."
        case .invalidEffects: return "This look contains invalid effects and cannot be applied."
        case .noVisualSelection: return "Select a video or image clip to apply a look."
        case .lockedClip(let id): return "The track containing clip \(id) is locked. Unlock it before applying the look."
        case .missingLut(let name, let path): return "Look ‘\(name)’ needs the missing LUT at \(path). Restore or replace the LUT before applying."
        case .writeFailed(let message): return "The look was not saved: \(message)"
        }
    }
}

/// User-data catalogue. The host supplies its crash-safe durable writer; memory changes only after a successful write.
public final class UserLookStore {
    private struct Catalog: Codable { var version = 1; var looks: [UserLook] }
    public private(set) var looks: [UserLook]
    public let path: String
    private let write: (Data, String) throws -> Void
    public init(path: String, write: @escaping (Data, String) throws -> Void) throws {
        self.path = path; self.write = write
        if FileManager.default.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.version == 1,
                  Set(catalog.looks.map(\.id)).count == catalog.looks.count,
                  catalog.looks.allSatisfy({ Self.valid($0) }) else { throw UserLookError.invalidCatalog }
            looks = catalog.looks
        } else { looks = [] }
    }
    static func cleanName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { throw UserLookError.invalidName }
        return value
    }
    static func valid(_ look: UserLook) -> Bool {
        !look.id.isEmpty && (try? cleanName(look.name)) == look.name && look.effects.count <= 128
            && Set(look.effects.map(\.id)).count == look.effects.count
            && look.effects.allSatisfy { !$0.id.isEmpty && !$0.effectId.isEmpty }
    }
    @discardableResult public func save(name: String, effects: [NativeClipEffect]) throws -> UserLook {
        let look = UserLook(name: try Self.cleanName(name), effects: effects)
        guard Self.valid(look) else { throw UserLookError.invalidEffects }
        try persist(looks + [look]); return look
    }
    public func rename(id: String, name: String) throws {
        guard let index = looks.firstIndex(where: { $0.id == id }) else { throw UserLookError.missingLook }
        var next = looks; next[index].name = try Self.cleanName(name); try persist(next)
    }
    public func delete(id: String) throws {
        guard looks.contains(where: { $0.id == id }) else { throw UserLookError.missingLook }
        try persist(looks.filter { $0.id != id })
    }
    private func persist(_ next: [UserLook]) throws {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Catalog(looks: next))
            try write(data, path)
            looks = next
        } catch let error as UserLookError { throw error }
        catch { throw UserLookError.writeFailed(error.localizedDescription) }
    }
}
