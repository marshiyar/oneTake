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

/// A problem with `<userData>/text-styles.json`. The file is never rewritten while it is unreadable.
public struct TextStyleLibraryError: Error, Equatable, LocalizedError {
    public let path: String
    public let reason: String
    public var errorDescription: String? { "Text styles at \(path): \(reason)" }
}

/// The user's text styles, shared by every project. The host supplies its crash-safe durable writer; memory
/// changes only after a successful write. A corrupt file is reported with its path and left untouched, and the
/// library then lists no styles, so the Style menu still opens with the project's own styles.
public final class TextStyleLibrary {
    private struct Catalog: Codable { var version = 1; var styles: [NativeTextStyle] }

    public let path: String
    /// Every style in the file, including records written by a newer version (kept as they are, never drawn).
    public private(set) var styles: [NativeTextStyle] = []
    /// Why the file could not be read; nil when it loaded or does not exist yet.
    public private(set) var loadError: TextStyleLibraryError?
    private let write: (Data, String) throws -> Void

    public init(path: String, write: @escaping (Data, String) throws -> Void) {
        self.path = path
        self.write = write
        reload()
    }

    /// The styles the menu offers, in file order.
    public var menuStyles: [NativeTextStyle] { styles.filter(\.isSupported) }

    /// Reads the file again, so a file the user repaired is picked up the next time the menu opens.
    public func reload() {
        guard FileManager.default.fileExists(atPath: path) else { styles = []; loadError = nil; return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.version == 1,
              Set(catalog.styles.map(\.id)).count == catalog.styles.count,
              catalog.styles.allSatisfy({ !$0.id.isEmpty && (!$0.isSupported || Self.validName($0.name)) }) else {
            styles = []
            loadError = TextStyleLibraryError(path: path, reason: "could not be read; the file was left untouched")
            return
        }
        styles = catalog.styles
        loadError = nil
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
    }

    /// Adds the style, or replaces the one with the same id.
    public func save(_ style: NativeTextStyle) throws {
        guard style.isSupported, Self.validName(style.name), !style.id.isEmpty else {
            throw TextStyleLibraryError(path: path, reason: "name the style using 1 to 120 characters")
        }
        reload()
        try requireReadable()
        var next = styles
        if let index = next.firstIndex(where: { $0.id == style.id }) { next[index] = style } else { next.append(style) }
        try persist(next)
    }

    public func delete(id: String) throws {
        reload()
        try requireReadable()
        try persist(styles.filter { $0.id != id })
    }

    private func requireReadable() throws {
        if let loadError { throw loadError }
    }

    private func persist(_ next: [NativeTextStyle]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try write(try encoder.encode(Catalog(styles: next)), path)
            styles = next
        } catch {
            throw TextStyleLibraryError(path: path, reason: "could not save the styles (\(error.localizedDescription))")
        }
    }
}
