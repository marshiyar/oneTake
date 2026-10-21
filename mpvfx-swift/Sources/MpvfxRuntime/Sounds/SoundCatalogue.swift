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
// The sound catalogue: one in-memory index over the bundled packs folder (read-only) and `<userData>/sound-packs/`.
// It is built off the main thread at launch and after an install; searches read the last finished index and never
// touch the disk. Indexing checks structure and files' presence; each sound's bytes are verified the first time it is
// used (`verify`), and a verified file is not hashed again while its size and modification time stay the same.
import Foundation

/// A sound in the catalogue, with the pack facts a browser shows.
public struct SoundEntry: Equatable, Sendable {
    public var packId: String, packName: String
    public var licence: SoundLicence
    public var item: SoundItem
    /// Lower-cased title, tags, moods, kind and pack name the text search looks through.
    let searchText: String
}

public struct SoundQuery: Equatable, Sendable {
    public var text: String
    public var kind: SoundKind?
    public var mood: SoundMood?
    public var lengthBand: SoundLengthBand?
    public init(text: String = "", kind: SoundKind? = nil, mood: SoundMood? = nil, lengthBand: SoundLengthBand? = nil) {
        self.text = text; self.kind = kind; self.mood = mood; self.lengthBand = lengthBand
    }
}

/// What one indexing pass found.
public struct SoundIndex: Equatable, Sendable {
    public var packs: [SoundPackReport] = []
    public var entries: [SoundEntry] = []
}

public final class SoundCatalogue: @unchecked Sendable {
    public let bundledFolder: String?
    public let userFolder: String
    private let cache = SoundVerificationCache()
    private let lock = NSLock()
    private var index = SoundIndex()
    private let queue = DispatchQueue(label: "mpvfx.sound-catalogue", qos: .utility)

    /// `bundledFolder` is the app's read-only packs folder (nil when the build ships none); `userFolder` is
    /// `<userData>/sound-packs`.
    public init(bundledFolder: String?, userFolder: String) {
        self.bundledFolder = bundledFolder
        self.userFolder = userFolder
    }

    public var snapshot: SoundIndex { lock.lock(); defer { lock.unlock() }; return index }

    /// Indexes both folders on a background queue and publishes the result; the caller's thread is not blocked.
    @discardableResult
    public func reload() async -> SoundIndex {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.reloadNow()) }
        }
    }

    /// The same pass on the calling thread (tests, tools).
    @discardableResult
    public func reloadNow() -> SoundIndex {
        var next = SoundIndex()
        var seen = Set<String>()
        for folder in [bundledFolder, userFolder].compactMap({ $0 }) {
            for packFolder in Self.packFolders(in: folder) {
                var report = SoundPackReader.read(folder: packFolder, checks: .deferred, cache: cache)
                if !seen.insert(report.id).inserted { report = Self.hidingDuplicate(report) }
                next.packs.append(report)
                next.entries.append(contentsOf: Self.entries(of: report))
            }
        }
        lock.lock(); index = next; lock.unlock()
        return next
    }

    /// Installs the pack at `source` (see SoundPackInstaller), then re-indexes.
    @discardableResult
    public func install(from source: String, durableWrite: DurableWrite) async throws -> SoundPackReport {
        let report = try SoundPackInstaller.install(from: source, into: userFolder, durableWrite: durableWrite)
        await reload()
        return report
    }

    /// Entries matching every part of the query: each word of `text` must occur in the title, a tag, a mood, the kind or
    /// the pack name; title matches that start with the text come first, then title order.
    public func search(_ query: SoundQuery) -> [SoundEntry] {
        let words = query.text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matches = snapshot.entries.filter { entry in
            if let kind = query.kind, entry.item.kind != kind { return false }
            if let mood = query.mood, !entry.item.moods.contains(mood) { return false }
            if let band = query.lengthBand, SoundLengthBand(durationMs: entry.item.durationMs) != band { return false }
            return words.allSatisfy { entry.searchText.contains($0) }
        }
        guard let first = words.first else { return matches }
        func rank(_ entry: SoundEntry) -> Int { entry.item.title.lowercased().hasPrefix(first) ? 0 : 1 }
        return matches.sorted { (rank($0), $0.item.title.lowercased()) < (rank($1), $1.item.title.lowercased()) }
    }

    /// Full content checks of one sound, at its first use; empty when the file is as declared.
    public func verify(_ entry: SoundEntry) -> [SoundPackIssue] {
        SoundPackReader.verify(entry.item, inPack: entry.packId, cache: cache)
    }

    private static func packFolders(in directory: String) -> [String] {
        let names: [String]
        do { names = try ProjectFS.readdir(directory) } catch { return [] }
        return names.sorted().filter { $0.hasSuffix("." + soundPackFolderExtension) && !$0.hasPrefix(".") }
            .map { PosixPath.join(directory, $0) }
            .filter { path in
                do { return try ProjectFS.entry(path)?.isDirectory == true } catch { return false }
            }
    }

    private static func hidingDuplicate(_ report: SoundPackReport) -> SoundPackReport {
        var copy = report
        copy.items = []
        copy.state = .invalid
        copy.issues.append(SoundPackIssue(packId: report.id, itemId: nil, code: .duplicatePack,
                                          message: "another installed pack already has the id \"\(report.id)\"; this one is hidden"))
        return copy
    }

    private static func entries(of report: SoundPackReport) -> [SoundEntry] {
        guard report.state == .ready, let licence = report.licence else { return [] }
        return report.items.map { item in
            let text = ([item.title, item.kind.rawValue, report.name] + item.tags + item.moods.map(\.rawValue)).joined(separator: " ").lowercased()
            return SoundEntry(packId: report.id, packName: report.name, licence: licence, item: item, searchText: text)
        }
    }
}
