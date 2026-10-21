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
// Libraries: events, projects, imported and linked media, export snapshots and output saves, on top of
// LibraryCatalog / LibraryLock.
// Notes (see docs/IMPLEMENTATION_NOTES.md):
// - initializeProject writes only the native project document (.studio/project.json), through ProjectDocuments.createStarter.
// - importLocalMedia / resolveMovePath need a DurableWrite and a binary finder: injected through init.
// - trackExport polls a status closure.
import Foundation
import MpvfxShared

public struct LibraryError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

struct CatalogAsset: Codable, Equatable { var id, eventId, name, kind: String; var mode: LibraryAssetMode; var source, fingerprint: String; var state: LibraryItemState }
struct CatalogPlacement: Codable, Equatable { var projectId, assetId, path: String }
struct CatalogJob: Codable, Equatable { var id, projectId, snapshot, status, output, error: String }
struct Catalog: Codable, Equatable {
    var id: String; var name: String
    var events: [LibraryEvent]; var projects: [LibraryProject]; var assets: [CatalogAsset]
    var placements: [CatalogPlacement]; var jobs: [CatalogJob]
}

private func newUUID() -> String { UUID().uuidString.lowercased() }

/// :57 id.
func checkLibraryId(_ value: String) throws -> String {
    let u = Array(value.utf8)
    guard u.count == 36, u.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || $0 == 0x2D }) else {
        throw LibraryError("Invalid library identity")
    }
    return value
}
/// :61 title (JS length = UTF-16 units, trim = JS whitespace).
func libraryTitle(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || value.utf16.count > 200 { throw LibraryError("Enter a name (1–200 characters)") }
    return trimmed
}
/// :66 within.
func libraryWithin(_ root: String, _ value: String) throws -> String {
    let path = PosixPath.resolve(root, value)
    let offset = PosixPath.relative(root, path)
    if offset.isEmpty || PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") {
        throw LibraryError("Path escapes library storage")
    }
    return path
}
/// :78 fingerprint: streamed SHA-256, refusing a file that changed while hashing.
func libraryFingerprint(_ path: String) throws -> String {
    let before = try ProjectFS.statInfo(path)
    if !before.isFile { throw LibraryError("Media is not a regular file") }
    guard let handle = FileHandle(forReadingAtPath: path) else { throw fsError("open", path) }
    defer { try? handle.close() }
    var hasher = SHA256Hasher()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
    let after = try ProjectFS.statInfo(path)
    if before.size != after.size || before.mtimeNs != after.mtimeNs || before.ino != after.ino {
        throw LibraryError("Source changed during import")
    }
    return hasher.finalizeHex()
}
/// :92 syncPath: fsync a file or directory, tolerating directories that refuse it (on Windows every directory: a
/// directory handle cannot be flushed).
func librarySyncPath(_ path: String) throws {
    let file = try NativeFile.openForSync(path)
    defer { file.close() }
    do { try file.sync(path: path) }
    catch let e as ProjectFSError {
        guard ["EINVAL", "ENOTSUP", "EISDIR", "EPERM", "EACCES"].contains(e.code) else { throw e }
        let info: FileInfo
        do { info = try file.info(path: path) } catch { throw e }
        if !info.isDirectory { throw e }
    }
}
private func writeExclusive(_ path: String, _ text: String) throws {
    let file = try NativeFile.create(path, .exclusive, mode: 0o666)
    defer { file.close() }
    try file.writeAll(Data(text.utf8), path: path)
}
private func rmForce(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
private func renamePath(_ from: String, _ to: String) throws { try ProjectFS.rename(from, to) }
/// :113 atomicJson (JSON.stringify(value, null, 2)).
func libraryAtomicJson(_ path: String, _ value: NativeJSONValue) throws {
    let temporary = "\(path).\(newUUID()).tmp"
    try writeExclusive(temporary, jsJSONStringify(value, indent: 2))
    try librarySyncPath(temporary)
    try renamePath(temporary, path)
    try librarySyncPath(PosixPath.dirname(path))
}
private func mkdirp(_ path: String) throws { try ProjectFS.mkdirRecursive(path) }

/// Where a library import lands: an event, and optionally a project the imported assets are added to.
public struct LibraryImportTarget: Equatable, Sendable {
    public var eventId: String
    public var projectId: String?
    public init(eventId: String, projectId: String? = nil) { self.eventId = eventId; self.projectId = projectId }
}

public struct LibraryProjectEntry: Equatable, Sendable { public var id: String; public var title: String; public var dir: String }
public struct LibrarySnapshot: Equatable, Sendable {
    public var id: String; public var dir: String; public var libraryId: String
    public init(id: String, dir: String, libraryId: String) { self.id = id; self.dir = dir; self.libraryId = libraryId }
}
public struct LibraryExportStatus: Sendable {
    public var status: String; public var outputPath: String?; public var error: String?
    public init(status: String, outputPath: String? = nil, error: String? = nil) { self.status = status; self.outputPath = outputPath; self.error = error }
}

final class OpenLibrary: @unchecked Sendable {
    let root: String; var catalog: Catalog; let lock: LibraryLock?
    init(root: String, catalog: Catalog, lock: LibraryLock?) { self.root = root; self.catalog = catalog; self.lock = lock }
}

/// :121 LibraryService. Native catalog owns identity. Project-relative views retain existing editor compatibility.
public final class LibraryService: @unchecked Sendable {
    private let state = NSLock()
    private var libraries: [(String, OpenLibrary)] = []   // JS Map: insertion order
    private var recent: [String] = []                     // JS Set: insertion order
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private let queue = ProjectAccessQueue()
    private let userData: String
    private let durableWrite: DurableWrite

    public init(userData: String, durableWrite: DurableWrite) {
        self.userData = userData; self.durableWrite = durableWrite
    }

    private func library(_ id: String) -> OpenLibrary? { state.withLock { libraries.first { $0.0 == id }?.1 } }
    private func allLibraries() -> [OpenLibrary] { state.withLock { libraries.map(\.1) } }
    private func setLibrary(_ id: String, _ l: OpenLibrary) { state.withLock { libraries.append((id, l)) } }
    private func removeLibrary(_ id: String) { state.withLock { libraries.removeAll { $0.0 == id } } }
    private func addRecent(_ path: String) { state.withLock { if !recent.contains(path) { recent.append(path) } } }

    private static func decode(_ text: String) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(text.utf8))
    }
    /// :133 command.
    @discardableResult
    private func command(_ l: OpenLibrary, _ action: String, _ args: [String] = []) throws -> Catalog {
        let next = try Self.decode(LibraryCatalog.command(PosixPath.join(l.root, "Catalog.sqlite"), action, args))
        state.withLock { l.catalog = next }
        return next
    }
    private func catalog(_ l: OpenLibrary) -> Catalog { state.withLock { l.catalog } }
    /// :147 get.
    private func get(_ libraryId: String) throws -> OpenLibrary {
        guard let l = library(libraryId) else { throw LibraryError("Library is not open") }
        return l
    }
    /// :152 remember.
    private func remember() throws {
        try mkdirp(userData)
        try libraryAtomicJson(PosixPath.join(userData, "libraries.json"), .array(state.withLock { recent }.map { .string($0) }))
    }
    /// :156 restore.
    public func restore() async {
        guard let text = try? ProjectFS.readUTF8(PosixPath.join(userData, "libraries.json")),
              let value = try? NativeJSONValue.parse(text), let paths = value.arrayValue else { return }
        for item in paths {
            guard let path = item.stringValue else { continue }
            addRecent(path)
            do { _ = try await open(path, remember: false) }
            catch { FileHandle.standardError.write(Data("[Library] Could not reopen \(path) \(error)\n".utf8)) }
        }
    }
    /// :176 create. Exclusive: never adopt or overwrite an existing directory.
    public func create(_ path: String) async throws -> String {
        try ProjectFS.mkdir(PosixPath.resolve(path))
        let root = try ProjectFS.realpath(path)
        let libraryId = newUUID()
        let name = try libraryTitle(replaceLibrarySuffix(PosixPath.basename(root)))
        let initial = try Self.decode(LibraryCatalog.command(PosixPath.join(root, "Catalog.sqlite"), "create", [libraryId, name]))
        let l = OpenLibrary(root: root, catalog: initial, lock: try LibraryLock(PosixPath.join(root, ".mpvfx-lock")))
        try libraryAtomicJson(PosixPath.join(root, "Library.json"),
                              .object(NativeJSONObject([("format", .string("mpvfx-library")), ("version", .number(1)), ("id", .string(libraryId))])))
        for directory in ["Projects", "Media/Originals", "Staging", "Snapshots", "renders"] {
            try mkdirp(PosixPath.join(root, directory))
        }
        setLibrary(libraryId, l)
        try command(l, "event", [newUUID(), "Media"])
        addRecent(root)
        try remember()
        return libraryId
    }
    /// `.replace(/\.mpvfxlibrary$/i, "")`.
    private func replaceLibrarySuffix(_ name: String) -> String {
        let suffix = ".mpvfxlibrary"
        if name.lowercased().hasSuffix(suffix) && name.utf16.count >= suffix.utf16.count {
            return String(decoding: Array(name.utf16).dropLast(suffix.utf16.count), as: UTF16.self)
        }
        return name
    }
    /// :210 open.
    @discardableResult
    public func open(_ path: String, remember shouldRemember: Bool = true) async throws -> String {
        let root = try ProjectFS.realpath(path)
        let manifest = try NativeJSONValue.parse(ProjectFS.readUTF8(PosixPath.join(root, "Library.json")))
        let object = manifest.objectValue
        guard object?["format"]?.stringValue == "mpvfx-library", object?["version"]?.numberValue == 1 else {
            throw LibraryError("Unsupported library format")
        }
        let libraryId = try Self.libraryIdentity(object?["id"])
        if let existing = library(libraryId) {
            if existing.root != root {
                throw LibraryError("A copy of this library is already open. Close the application before opening the other copy.")
            }
            return libraryId
        }
        for directory in ["Projects", "Media", "Media/Originals", "Staging", "Snapshots", "renders"] {
            if try ProjectFS.lstatInfo(PosixPath.join(root, directory)).isSymbolicLink {
                throw LibraryError("Library storage must not be a symbolic link")
            }
        }
        if try ProjectFS.lstatInfo(PosixPath.join(root, "Catalog.sqlite")).isSymbolicLink {
            throw LibraryError("Catalog must be inside the library")
        }
        let initial = try Self.decode(LibraryCatalog.command(PosixPath.join(root, "Catalog.sqlite"), "read", []))
        if initial.id != libraryId { throw LibraryError("Library manifest and catalog do not match") }
        for p in initial.projects {
            _ = try checkLibraryId(p.id)
            if p.state == .ready {
                let dir = PosixPath.join(root, "Projects", p.id)
                if try ProjectFS.lstatInfo(dir).isSymbolicLink { throw LibraryError("Project storage must not be a symbolic link") }
                _ = try libraryWithin(root, try ProjectFS.realpath(dir))
            }
        }
        for a in initial.assets {
            _ = try checkLibraryId(a.id)
            if a.mode == .managed { _ = try libraryWithin(root, a.source) }
        }
        let l = OpenLibrary(root: root, catalog: initial, lock: try LibraryLock(PosixPath.join(root, ".mpvfx-lock")))
        setLibrary(libraryId, l)
        do {
            try command(l, "recover")
            for project in catalog(l).projects where project.state == .pending {
                do { try initializeProject(l, project.id) }
                catch { FileHandle.standardError.write(Data("[Library] Project creation remains incomplete \(project.id) \(error)\n".utf8)) }
            }
            for asset in catalog(l).assets where asset.state == .pending {
                do {
                    if asset.mode == .managed {
                        let stage = PosixPath.join(root, "Staging", try checkLibraryId(asset.id))
                        let stagedFile = PosixPath.join(stage, PosixPath.basename(asset.source))
                        do {
                            if try libraryFingerprint(stagedFile) == asset.fingerprint {
                                try renamePath(stage, PosixPath.dirname(try libraryWithin(root, asset.source)))
                                try librarySyncPath(PosixPath.join(root, "Media/Originals"))
                            }
                        } catch { /* Already published, or staging incomplete. Verify final file below. */ }
                    }
                    if try libraryFingerprint(try assetSource(l, asset)) == asset.fingerprint {
                        try command(l, "assetReady", [asset.id])
                    }
                } catch { /* Keep incomplete imports visibly pending; never expose partial files. */ }
            }
            addRecent(root)
            if shouldRemember { try remember() }
        } catch {
            l.lock?.close()
            removeLibrary(libraryId)
            throw error
        }
        return libraryId
    }
    private static func libraryIdentity(_ value: NativeJSONValue?) throws -> String {
        guard let s = value?.stringValue else { throw LibraryError("Invalid library identity") }
        return try checkLibraryId(s)
    }
    /// :312 views.
    public func views() async -> [LibraryView] {
        allLibraries().map { l in
            let c = catalog(l)
            return LibraryView(id: c.id, name: c.name, path: l.root, events: c.events, projects: c.projects,
                assets: c.assets.map { a in
                    let available = (try? assetSource(OpenLibrary(root: l.root, catalog: c, lock: nil), a)).map { ProjectFS.exists($0) } ?? false
                    return LibraryAsset(id: a.id, eventId: a.eventId, name: a.name, kind: a.kind, mode: a.mode, state: a.state, available: available)
                },
                jobs: c.jobs.map { j in
                    LibraryJob(id: j.id, projectId: j.projectId, status: j.status,
                               output: j.output.isEmpty ? "" : ((try? libraryWithin(l.root, j.output)) ?? ""), error: j.error)
                })
        }
    }
    /// :350 listProjects.
    public func listProjects() -> [LibraryProjectEntry] {
        allLibraries().flatMap { l in catalog(l).projects.filter { $0.state == .ready }.map {
            LibraryProjectEntry(id: $0.id, title: $0.name, dir: PosixPath.join(l.root, "Projects", $0.id)) } }
    }
    /// :361 resolveProject.
    public func resolveProject(_ projectId: String) -> LibraryProjectEntry? { listProjects().first { $0.id == projectId } }
    /// :364 forProject.
    func forProject(_ projectId: String) -> OpenLibrary? {
        allLibraries().first { l in catalog(l).projects.contains { $0.id == projectId && $0.state == .ready } }
    }
    /// :369 outputDirectory.
    public func outputDirectory(_ projectId: String) throws -> String? {
        guard let l = forProject(projectId) else { return nil }
        return PosixPath.join(l.root, "renders", try checkLibraryId(projectId))
    }
    /// :373 root.
    public func root(_ libraryId: String) throws -> String { try get(libraryId).root }
    /// :376 createEvent.
    public func createEvent(_ libraryId: String, _ name: String) async throws {
        let l = try get(libraryId)
        _ = try await queue.run(l.root) { [self] in try command(l, "event", [newUUID(), try libraryTitle(name)]); return true }
    }
    /// :382 initializeProject: a new project is just its native document, the starter document every project starts from.
    private func initializeProject(_ l: OpenLibrary, _ projectId: String) throws {
        let root = PosixPath.join(l.root, "Projects", try checkLibraryId(projectId))
        try mkdirp(root)
        try mkdirp(PosixPath.join(root, ".studio"))
        let name = try Self.catalogProject(catalog(l), projectId).name
        // nil: a document is already there (written before a crash, or partial); its identity is checked below.
        _ = try ProjectDocuments.createStarter(projectRoot: root, id: projectId, name: name, durableWrite: durableWrite)
        let existing = try parseNativeProjectDocument(NativeJSONValue.parse(ProjectFS.readUTF8(PosixPath.join(root, ".studio/project.json"))))
        if existing.id != projectId { throw LibraryError("Incomplete project identity does not match its catalog entry") }
        for file in [".studio/project.json", ".studio", ""] { try librarySyncPath(PosixPath.join(root, file)) }
        try command(l, "projectReady", [projectId])
    }
    /// :442 createProject.
    public func createProject(_ libraryId: String, _ eventId: String, _ name: String) async throws -> String {
        let l = try get(libraryId), projectId = newUUID()
        _ = try await queue.run(l.root) { [self] in
            try command(l, "project", [projectId, try checkLibraryId(eventId), try libraryTitle(name)])
            try initializeProject(l, projectId)
            return true
        }
        return projectId
    }
    /// :451 assetSource.
    private func assetSource(_ l: OpenLibrary, _ asset: CatalogAsset) throws -> String {
        if asset.mode == .linked { return try ProjectFS.realpath(asset.source) }
        let path = try ProjectFS.realpath(try libraryWithin(l.root, asset.source))
        _ = try libraryWithin(try ProjectFS.realpath(PosixPath.join(l.root, "Media/Originals")), path)
        return path
    }
    /// The file behind a ready asset (managed copy or linked original), for thumbnails, durations and waveforms.
    public func assetPath(_ libraryId: String, _ assetId: String) throws -> String {
        let l = try get(libraryId)
        guard let asset = catalog(l).assets.first(where: { $0.id == assetId && $0.state == .ready }) else { throw LibraryError("Media is not ready") }
        return try assetSource(l, asset)
    }
    /// Which projects each asset was added to: (projectId, assetId, project-relative path).
    public func placements(_ libraryId: String) throws -> [(projectId: String, assetId: String, path: String)] {
        catalog(try get(libraryId)).placements.map { ($0.projectId, $0.assetId, $0.path) }
    }
    /// :457 import, into an event only.
    public func `import`(_ libraryId: String, _ eventId: String, _ paths: [String], _ mode: LibraryAssetMode) async throws -> LocalMediaImportResult {
        try await self.import(libraryId, LibraryImportTarget(eventId: eventId), paths, mode)
    }
    /// :457 import, into `target.eventId` and, when `target.projectId` is set, added to that project.
    public func `import`(_ libraryId: String, _ target: LibraryImportTarget, _ paths: [String], _ mode: LibraryAssetMode) async throws -> LocalMediaImportResult {
        let l = try get(libraryId), eventId = target.eventId, projectId = target.projectId
        return try await queue.run(l.root) { [self] in
            let c = catalog(l)
            if !c.events.contains(where: { $0.id == eventId }) { throw LibraryError("Event not found") }
            if let projectId, !c.projects.contains(where: { $0.id == projectId && $0.state == .ready }) {
                throw LibraryError("Project is not in this library")
            }
            var result = LocalMediaImportResult()
            for original in paths {
                let assetId = newUUID(), name = PosixPath.basename(original)
                do {
                    let source = try ProjectFS.realpath(original), info = try ProjectFS.statInfo(source)
                    if let refusal = ImportFormats.refusal(forName: name) { throw LibraryError(refusal) }
                    guard let kind = ImportFormats.kind(of: name), info.isFile, info.size > 0 else { throw LibraryError("Unsupported or empty media file") }
                    let targetDir = PosixPath.join(l.root, "Media/Originals", assetId)
                    let staging = PosixPath.join(l.root, "Staging", assetId)
                    try mkdirp(staging)
                    // Reuse codec validation and OS copying; validation never publishes into a project.
                    let imported = try importLocalMedia(projectRoot: staging, paths: [source], durableWrite: durableWrite)
                    guard imported.invalid.isEmpty, let file = imported.files.first else {
                        throw LibraryError(imported.invalid.first?.reason ?? "Import failed")
                    }
                    let staged = PosixPath.join(staging, file)
                    let hash = try libraryFingerprint(staged)
                    if mode == .linked, try libraryFingerprint(source) != hash { throw LibraryError("Linked source changed during import") }
                    let stored = mode == .managed ? PosixPath.relative(l.root, PosixPath.join(targetDir, file)) : source
                    try command(l, "asset", [assetId, eventId, name, kind.rawValue, mode.rawValue, stored, hash])
                    if mode == .managed {
                        try librarySyncPath(staged); try librarySyncPath(staging)
                        try renamePath(staging, targetDir)
                        try librarySyncPath(PosixPath.dirname(targetDir))
                    } else { rmForce(staging) }
                    try command(l, "assetReady", [assetId])
                    if let projectId { result.files.append(try attachUnlocked(l, projectId, assetId)) }
                    else { result.files.append(assetId) }
                } catch {
                    result.invalid.append(.init(name: name, reason: "\(error)"))
                }
            }
            return result
        }
    }
    /// The catalog entry for `projectId`. Callers read the catalog again after their own check, so a missing entry is a
    /// typed error, never a crash (#25).
    static func catalogProject(_ c: Catalog, _ projectId: String) throws -> LibraryProject {
        guard let project = c.projects.first(where: { $0.id == projectId }) else { throw LibraryError("Library project not found") }
        return project
    }
    /// :536 importForProject.
    public func importForProject(_ projectId: String, _ paths: [String]) async throws -> LocalMediaImportResult {
        guard let l = forProject(projectId) else { throw LibraryError("Library project not found") }
        let c = catalog(l)
        let project = try Self.catalogProject(c, projectId)
        return try await self.import(c.id, LibraryImportTarget(eventId: project.eventId, projectId: projectId), paths, .managed)
    }
    /// :548 attachUnlocked.
    private func attachUnlocked(_ l: OpenLibrary, _ projectId: String, _ assetId: String) throws -> String {
        let c = catalog(l)
        if !c.projects.contains(where: { $0.id == projectId && $0.state == .ready }) { throw LibraryError("Project not found in library") }
        guard let asset = c.assets.first(where: { $0.id == assetId && $0.state == .ready }) else { throw LibraryError("Media is not ready") }
        let source = try assetSource(l, asset)
        if try libraryFingerprint(source) != asset.fingerprint {
            throw LibraryError("Original media changed. Import it as a new asset to preserve existing edits.")
        }
        let path = "assets/\(try checkLibraryId(assetId))/\(PosixPath.basename(asset.name))"
        let destination = try resolveMovePath(l.root, "Projects/\(try checkLibraryId(projectId))/\(path)", createParents: true, durableWrite: durableWrite)
        let staging = PosixPath.join(PosixPath.dirname(destination), ".mpvfx-attach-\(newUUID())")
        defer { rmForce(staging) }
        try copyFileExclusiveStreaming(source, staging)
        if try libraryFingerprint(staging) != asset.fingerprint { throw LibraryError("Source changed while attaching media") }
        try librarySyncPath(staging)
        do { try publishFileExclusive(staging, destination) }
        catch let e as ProjectFSError where e.code == "EEXIST" {
            if try libraryFingerprint(destination) != asset.fingerprint {
                throw LibraryError("Project media has been modified; refusing to overwrite it")
            }
        }
        try librarySyncPath(PosixPath.dirname(destination))
        try command(l, "attach", [projectId, assetId, path])
        return path
    }
    /// :598 attach.
    public func attach(_ libraryId: String, _ projectId: String, _ assetId: String) async throws -> String {
        let l = try get(libraryId)
        return try await queue.run(l.root) { [self] in try attachUnlocked(l, projectId, assetId) }
    }
    /// :604 relink.
    public func relink(_ libraryId: String, _ assetId: String, _ path: String) async throws {
        let l = try get(libraryId)
        _ = try await queue.run(l.root) { [self] in
            guard let asset = catalog(l).assets.first(where: { $0.id == assetId && $0.mode == .linked }) else {
                throw LibraryError("Select linked media to relink")
            }
            let source = try ProjectFS.realpath(path)
            if try libraryFingerprint(source) != asset.fingerprint {
                throw LibraryError("This file is not the same media. Import replacement media separately.")
            }
            try command(l, "relink", [assetId, source])
            return true
        }
    }
    /// :620 snapshot. Called while the runtime owns the project's edit lock. Copies isolate every renderer path.
    public func snapshot(_ projectId: String, settings: NativeJSONValue = .object(NativeJSONObject())) async throws -> LibrarySnapshot? {
        guard let l = forProject(projectId) else { return nil }
        return try await queue.run(l.root) { [self] in
            let snapshotId = newUUID()
            let root = PosixPath.join(l.root, "Snapshots", snapshotId), source = PosixPath.join(l.root, "Projects", projectId)
            var baseline: [String: String] = [:]
            func skipped(_ name: String) -> Bool { ["renders", "node_modules", ".git", ".mpvfx-transactions"].contains(name) || name.hasPrefix(".mpvfx-attach-") }
            func copyTree(_ from: String, _ to: String) throws {
                try mkdirp(to)
                for name in try ProjectFS.readdir(from) where !skipped(name) {
                    let input = PosixPath.join(from, name), output = PosixPath.join(to, name)
                    let info = try ProjectFS.lstatInfo(input)
                    if info.isSymbolicLink { throw LibraryError("Cannot snapshot symbolic link: \(name)") }
                    if info.isDirectory { try copyTree(input, output) }
                    else if info.isFile {
                        baseline[input] = try ProjectFS.statInfo(input).fingerprint
                        try copyFileExclusiveStreaming(input, output)
                        try librarySyncPath(output)
                    }
                }
                try librarySyncPath(to)
            }
            func verifyTree(_ dir: String) throws {
                for name in try ProjectFS.readdir(dir) where !skipped(name) {
                    let path = PosixPath.join(dir, name)
                    let info = try ProjectFS.lstatInfo(path)
                    if info.isDirectory { try verifyTree(path); continue }
                    let stamp = info.isFile ? try ProjectFS.statInfo(path).fingerprint : nil
                    if !info.isFile || baseline[path] != stamp {
                        throw LibraryError("Project changed during export snapshot; retry export")
                    } else { baseline[path] = nil }
                }
            }
            do {
                try copyTree(source, root)
                try verifyTree(source)
                if !baseline.isEmpty { throw LibraryError("Project files disappeared during export snapshot; retry export") }
                try mkdirp(PosixPath.join(root, ".studio"))
                let document = try? ProjectFS.readUTF8(PosixPath.join(root, ".studio/project.json"))
                try libraryAtomicJson(PosixPath.join(root, ".studio/export-snapshot.json"), .object(NativeJSONObject([
                    ("schemaVersion", .number(1)), ("id", .string(snapshotId)), ("projectId", .string(projectId)),
                    ("createdAt", .string(Self.isoNow())), ("settings", settings),
                    ("projectDocumentHash", document.map { .string(sha256Hex($0)) } ?? .null)])))
                try command(l, "job", [snapshotId, projectId, PosixPath.relative(l.root, root)])
                return LibrarySnapshot(id: snapshotId, dir: root, libraryId: catalog(l).id)
            } catch {
                rmForce(root)
                throw error
            }
        }
    }
    /// `new Date().toISOString()`.
    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
    /// :716 failSnapshot.
    public func failSnapshot(_ snapshot: LibrarySnapshot, _ error: String) async throws {
        let l = try get(snapshot.libraryId)
        _ = try await queue.run(l.root) { [self] in try command(l, "jobFinish", [snapshot.id, "failed", "", error]); return true }
    }
    /// :725 trackExport: polls every 250 ms while "rendering", then persists the final status.
    public func trackExport(_ snapshot: LibrarySnapshot, _ job: @escaping @Sendable () -> LibraryExportStatus,
                            heartbeat: (@Sendable () -> Void)? = nil) {
        let key = UUID()
        let task = Task { [self] in
            do {
                var current = job()
                while current.status == "rendering" {
                    heartbeat?()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    current = job()
                }
                let final = current
                let l = try get(snapshot.libraryId)
                _ = try await queue.run(l.root) { [self] in
                    try command(l, "jobFinish", [snapshot.id, final.status,
                        final.outputPath.map { PosixPath.relative(l.root, $0) } ?? "", final.error ?? ""])
                    return true
                }
            } catch {
                FileHandle.standardError.write(Data("[Library] Export status persistence failed \(error)\n".utf8))
            }
            _ = state.withLock { jobs.removeValue(forKey: key) }
        }
        state.withLock { jobs[key] = task }
    }
    /// :752 saveOutput.
    public func saveOutput(_ libraryId: String, _ jobId: String, _ destination: String, replaceApproved: Bool = false) async throws {
        let l = try get(libraryId)
        guard let job = catalog(l).jobs.first(where: { $0.id == jobId && $0.status == "complete" }) else {
            throw LibraryError("Completed export not found")
        }
        let source = try ProjectFS.realpath(try libraryWithin(l.root, job.output))
        _ = try libraryWithin(try ProjectFS.realpath(PosixPath.join(l.root, "renders")), source)
        do { try publishSavedOutput(source, destination, replaceApproved: replaceApproved) }
        catch let e as ProjectFSError where e.code == "EEXIST" {
            let name = PosixPath.basename(destination)
            throw LibraryError("A file named \(name) already exists there. It was left unchanged; choose another name.")
        } catch let e as ProjectFSError {
            throw LibraryError("Could not save the export as \(PosixPath.basename(destination)): \(e.message)")
        }
    }
    /// Copies `source` beside `destination` (fsynced), then renames it into place when replacing was approved, else
    /// links it there without replacing anything (EEXIST when a file is there). The staged copy is always removed.
    private func publishSavedOutput(_ source: String, _ destination: String, replaceApproved: Bool) throws {
        let staged = PosixPath.join(PosixPath.dirname(destination), ".mpvfx-output-\(newUUID())")
        defer { rmForce(staged) }
        try copyFileExclusiveStreaming(source, staged)
        try librarySyncPath(staged)
        if replaceApproved { try renamePath(staged, destination) } else { try publishFileExclusive(staged, destination) }
        try librarySyncPath(PosixPath.dirname(destination))
    }
    /// :775 close.
    /// Returns once every export tracked so far has recorded its final status in the catalog.
    public func exportTrackingFinished() async {
        for task in state.withLock({ Array(jobs.values) }) { await task.value }
    }

    public func close() async {
        await exportTrackingFinished()
        await queue.drain()
        for l in allLibraries() { l.lock?.close() }
        state.withLock { libraries.removeAll() }
    }
}
