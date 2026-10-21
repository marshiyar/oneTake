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
// Rename and delete project media as one journaled edit with the document's references: a rename
// repoints every asset whose source is the file; a delete moves the file into the recovery folder
// (<journal>/deleted-media/<id>/) and, when asked, removes the assets and every clip placed from them.
import Foundation
import MpvfxShared

public struct ProjectMediaOperationError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable { case invalidPath, notFound, exists, extensionChanged, inUse, protected }
    public var kind: Kind
    public var message: String
    /// For `.inUse`: names of the clips placed from the media.
    public var dependents: [String]
    public init(_ kind: Kind, _ message: String, dependents: [String] = []) { self.kind = kind; self.message = message; self.dependents = dependents }
    public var description: String { message }
}

public struct ProjectMediaOperationResult: Equatable, Sendable {
    /// New path (rename) or recovery path (delete).
    public var path: String
    /// Document text after the edit (also what is now on disk).
    public var content: String
    /// Assets repointed (rename) or removed (delete).
    public var updatedAssets: Int
    /// Clips removed (delete with removeUsages).
    public var removedClips: Int
}

private let PROTECTED_MEDIA_ROOTS: Set<String> = [".studio", ".git", ".build"]

private func checkPublicPath(_ path: String) throws -> String {
    do { try validateMovePath(path) } catch { throw ProjectMediaOperationError(.invalidPath, "File path is outside the project") }
    let head = path.split(separator: "/").first.map { String($0).lowercased() } ?? ""
    if PROTECTED_MEDIA_ROOTS.contains(head) || head == JOURNAL_PARENT {
        throw ProjectMediaOperationError(.protected, "Project metadata cannot be renamed or deleted")
    }
    guard ProjectMediaCatalog.category(of: PosixPath.basename(path)) != nil else {
        throw ProjectMediaOperationError(.invalidPath, "Only media files can be renamed or deleted here")
    }
    return path
}

extension ProjectDocumentStore {
    /// Renames `from` to `to` (same extension), updating asset sources in `content` (the editor's current
    /// document, saved by the same commit).
    public func renameMedia(_ from: String, to: String, content: String) throws -> ProjectMediaOperationResult {
        let source = try checkPublicPath(from), destination = try checkPublicPath(to)
        var doc = try ProjectDocuments.validate(content)
        if source == destination { return .init(path: source, content: content, updatedAssets: 0, removedClips: 0) }
        if PosixPath.extname(source).lowercased() != PosixPath.extname(destination).lowercased() {
            throw ProjectMediaOperationError(.extensionChanged, "Keep the media file extension when renaming; changing its name does not convert its format")
        }
        guard let version = try binaryFileVersion(directory, source) else { throw ProjectMediaOperationError(.notFound, "Media file not found") }
        if try binaryFileVersion(directory, destination) != nil {
            throw ProjectMediaOperationError(.exists, "A file already exists at the requested destination")
        }
        _ = try resolveMovePath(directory, destination, createParents: true, durableWrite: durableWriter)
        var updated = 0
        for i in doc.assets.indices where doc.assets[i].source.map(PosixPath.normalize) == source {
            doc.assets[i].source = destination
            if doc.assets[i].name == PosixPath.basename(source) { doc.assets[i].name = PosixPath.basename(destination) }
            updated += 1
        }
        let next = updated == 0 ? content : try serializeNativeProjectDocument(doc)
        try commit(next, moves: [ProjectFileMove(from: source, to: destination, expectedVersion: version)],
                   label: "Rename media \(PosixPath.basename(source))")
        return .init(path: destination, content: next, updatedAssets: updated, removedClips: 0)
    }

    /// Deletes `path` into the recovery folder. Media placed on the timeline is refused unless
    /// `removeUsages`, which removes those clips and the assets in the same commit.
    public func deleteMedia(_ path: String, removeUsages: Bool, content: String) throws -> ProjectMediaOperationResult {
        let source = try checkPublicPath(path)
        var doc = try ProjectDocuments.validate(content)
        guard let version = try binaryFileVersion(directory, source) else { throw ProjectMediaOperationError(.notFound, "Media file not found") }
        let assetIds = Set(doc.assets.filter { $0.source.map(PosixPath.normalize) == source }.map(\.id))
        let placed = doc.sequence.tracks.flatMap(\.clips).filter { assetIds.contains($0.assetId) }
        if !placed.isEmpty && !removeUsages {
            throw ProjectMediaOperationError(.inUse, "This media is in use. Remove its timeline placements too, or remove them first.",
                                             dependents: placed.map(\.id))
        }
        for t in doc.sequence.tracks.indices { doc.sequence.tracks[t].clips.removeAll { assetIds.contains($0.assetId) } }
        doc.assets.removeAll { assetIds.contains($0.id) }
        let txn = UUID().uuidString.lowercased()
        let backup = "\(JOURNAL_PARENT)/deleted-media/\(txn)/\(PosixPath.basename(source))"
        _ = try resolveMovePath(directory, backup, createParents: true, durableWrite: durableWriter)
        let next = assetIds.isEmpty ? content : try serializeNativeProjectDocument(doc)
        try commit(next, moves: [ProjectFileMove(from: source, to: backup, expectedVersion: version)],
                   label: "Delete media \(PosixPath.basename(source))")
        return .init(path: backup, content: next, updatedAssets: assetIds.count, removedClips: placed.count)
    }
}

/// "name (copy).ext", then "name (copy 2).ext", ... next to `path` (a copy of a copy counts up), as the
/// file browser names duplicates.
func duplicateCopyPath(_ projectDir: String, _ path: String) -> String {
    let base0 = PosixPath.basename(path)
    let ext = base0.contains(".") ? "." + (base0.split(separator: ".").last.map(String.init) ?? "") : ""
    let base = ext.isEmpty ? path : String(path.dropLast(ext.count))
    var clean = base, num = 1
    if let r = base.range(of: #" \(copy(?: (\d+))?\)$"#, options: .regularExpression) {
        let suffix = String(base[r])
        clean = String(base[..<r.lowerBound])
        let digits = suffix.filter(\.isNumber)
        num = digits.isEmpty ? 2 : (Int(digits) ?? 1) + 1
    }
    var candidate = num == 1 ? "\(clean) (copy)\(ext)" : "\(clean) (copy \(num))\(ext)"
    while FileManager.default.fileExists(atPath: PosixPath.join(projectDir, candidate)) {
        num += 1
        candidate = "\(clean) (copy \(num))\(ext)"
    }
    return candidate
}

/// Copies project media to its duplicate name. Returns the new project-relative path.
public func duplicateProjectMedia(_ projectDir: String, _ path: String, durableWrite: DurableWrite) throws -> String {
    let source = try checkPublicPath(path)
    let root = try ProjectFS.realpath(projectDir)
    let from = try resolveMovePath(root, source)
    guard (try? ProjectFS.statInfo(from))?.isFile == true else { throw ProjectMediaOperationError(.notFound, "Media file not found") }
    let copy = duplicateCopyPath(root, source)
    let to = try resolveMovePath(root, copy, createParents: true, durableWrite: durableWrite)
    let staging = PosixPath.join(PosixPath.dirname(to), ".mpvfx-duplicate-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(atPath: staging) }
    try copyFileExclusiveStreaming(from, staging)
    try publishFileExclusive(staging, to)
    return copy
}
