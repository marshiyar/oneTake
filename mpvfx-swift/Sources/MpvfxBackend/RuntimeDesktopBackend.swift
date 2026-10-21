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
// The desktop backend on the native runtime: projects (create/open/save the native document through the
// journaled transaction store), media import (copy into the project + the media engine's probe), and the media library.
// Publishing is not part of the native app and fails with a clear error.
import Foundation
import MpvfxDesktopCore
import MpvfxRuntime
import MpvfxShared

extension NativeDurableWrite: DurableWrite {}

public final class RuntimeDesktopBackend: DesktopBackend, @unchecked Sendable {
    /// `<userData>/projects`: where new projects and the default project live.
    public let projectsDir: String
    public let userData: String
    public let library: MpvfxRuntime.LibraryService
    private let durableWrite: DurableWrite
    private let access = ProjectAccessQueue()
    var projectAccess: ProjectAccessQueue { access }
    private let lock = NSLock()
    private var stores: [String: ProjectDocumentStore] = [:]
    private var watchers: [String: ProjectDocumentWatcher] = [:]
    private let recents: RecentProjects
    private var closed = false
    private let bridge: LibraryBridge
    public let preferences: DesktopPreferences?
    /// The folder each render of this run was written to (job id → folder), so deleting it later finds it even after
    /// Settings changed the default export folder. Guarded by `lock`.
    private var renderDirs: [String: String] = [:]

    public init(userData: String, durableWrite: DurableWrite = NativeDurableWrite()) {
        projectsDir = PosixPath.join(userData, "projects")
        self.userData = userData
        self.durableWrite = durableWrite
        library = MpvfxRuntime.LibraryService(userData: userData, durableWrite: durableWrite)
        bridge = LibraryBridge(library)
        recents = RecentProjects(userData: userData)
        preferences = DesktopPreferences(userData: userData)
    }

    /// Reopens the libraries the user had open last time.
    public func restoreLibraries() async { await library.restore() }

    // MARK: Projects

    private func checkOpen() throws { if lock.withLock({ closed }) { throw DesktopError("The app is shutting down") } }

    /// Registers a store under its document id (suffixed when another open project already uses that id).
    private func register(_ store: ProjectDocumentStore) -> DesktopProject {
        do { try recents.add(store.directory) }
        catch { FileHandle.standardError.write(Data("[MpVFX] could not update recent projects: \(error)\n".utf8)) }
        return lock.withLock {
            if let existing = stores.first(where: { $0.value.directory == store.directory }) {
                return DesktopProject(id: existing.key, directory: existing.value.directory, content: existing.value.savedContent)
            }
            var key = store.id, n = 2
            while stores[key] != nil { key = "\(store.id)-\(n)"; n += 1 }
            stores[key] = store
            return DesktopProject(id: key, directory: store.directory, content: store.savedContent)
        }
    }

    private func store(_ id: String) throws -> ProjectDocumentStore {
        guard let s = lock.withLock({ stores[id] }) else { throw DesktopError("Project not found") }
        return s
    }

    /// A free directory name in the projects folder derived from `name`.
    private func newProjectDirectory(_ name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: projectsDir, withIntermediateDirectories: true)
        let base = name.unicodeScalars.map { CharacterSet(charactersIn: "/\\:\0").contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let stem = base.isEmpty ? "Untitled Project" : String(base.prefix(120))
        var candidate = PosixPath.join(projectsDir, stem), n = 2
        while FileManager.default.fileExists(atPath: candidate) { candidate = PosixPath.join(projectsDir, "\(stem) \(n)"); n += 1 }
        return candidate
    }

    public func createProject(name: String, directory: String?) throws -> DesktopProject {
        try checkOpen()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Project" : name
        let dir = try directory ?? newProjectDirectory(title)
        return register(try mapErrors { try ProjectDocumentStore.create(at: dir, name: title, durableWrite: durableWrite) })
    }

    public func openProject(path: String) throws -> DesktopProject {
        try checkOpen()
        let dir = realPath(try mapErrors { try ProjectDocuments.projectDirectory(for: path) })   // as the store records it
        if let existing = lock.withLock({ stores.first { $0.value.directory == dir } }) {
            return DesktopProject(id: existing.key, directory: dir, content: existing.value.savedContent)
        }
        return register(try mapErrors { try ProjectDocumentStore.open(dir, durableWrite: durableWrite) })
    }

    /// The standalone project (`<projects>/MpVFX`), created on first launch.
    public func openDefaultProject() throws -> DesktopProject {
        try checkOpen()
        let ensured = try mapErrors { try ensureStandaloneProject(projectsDir, durableWrite: durableWrite) }
        return try openProject(path: PosixPath.join(projectsDir, ensured.id))
    }

    public func saveProject(id: String, content: String) throws {
        try checkOpen()
        let s = try store(id)
        try exclusive(s) { try s.save(content) }
    }

    /// Runs a synchronous write to `s` on the project's access queue, after the operations already queued on it
    /// (an import, a media move, another save). The shells call these from the UI thread or the autosave queue.
    private func exclusive<T>(_ s: ProjectDocumentStore, _ body: () throws -> T) throws -> T {
        try access.runBlocking(s.directory) { try mapErrors(body) }
    }

    /// Takes the disk version after a save conflict or an external change.
    public func reloadProject(id: String) throws -> DesktopProject {
        let s = try store(id)
        _ = try mapErrors { try s.reload() }
        return DesktopProject(id: id, directory: s.directory, content: s.savedContent)
    }

    public func closeProject(id: String) {
        let w = lock.withLock { () -> ProjectDocumentWatcher? in stores[id] = nil; return watchers.removeValue(forKey: id) }
        w?.stop()
    }

    public func watchProject(id: String, onExternalChange: @escaping @Sendable (String) -> Void) throws {
        let s = try store(id)
        let watcher = ProjectDocumentWatcher(store: s, onChange: onExternalChange)
        let old = lock.withLock { () -> ProjectDocumentWatcher? in defer { watchers[id] = watcher }; return watchers[id] }
        old?.stop()
    }

    private func summary(_ p: ProjectSummary, library: String? = nil) -> DesktopProjectSummary {
        DesktopProjectSummary(directory: p.directory, id: p.id, title: p.title, modified: p.modified, libraryProjectId: library)
    }

    public func listProjects() -> [DesktopProjectSummary] {
        // realpath(3) so listed directories match open projects' (macOS /var is /private/var).
        let own = ProjectCatalog.list(realPath(projectsDir)).map { summary($0) }
        let fromLibraries = library.listProjects().compactMap { entry -> DesktopProjectSummary? in
            guard var p = ProjectCatalog.summary(realPath(entry.dir)) else { return nil }
            p.title = entry.title
            return summary(p, library: entry.id)
        }
        return (own + fromLibraries).sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.directory < $1.directory }
    }

    public func recentProjects() -> [DesktopProjectSummary] { recents.list().map { summary($0) } }

    public func forgetRecentProject(directory: String) throws { try mapErrors { try recents.remove(directory) } }

    public func clearRecentProjects() throws { try mapErrors { try recents.removeAll() } }

    // MARK: Media

    /// Runs blocking media work off the caller's thread. Task cancellation sets the MediaCancellation, which the
    /// engine-backed work checks between steps (each decoded frame, audio chunk or slot wait; a probe before and after
    /// its one engine call), so the work stops at the next step and throws MediaAbortError.
    private func blocking<T: Sendable>(_ body: @escaping @Sendable (MediaCancellation) throws -> T) async throws -> T {
        let cancellation = MediaCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result { do { return try body(cancellation) } catch { throw Self.desktopError(error) } })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    public func listMedia(projectId: String, query: String?) throws -> [DesktopMediaEntry] {
        let s = try store(projectId)
        let document = try? ProjectDocuments.validate(s.savedContent)
        return ProjectMediaCatalog.list(s.directory, document: document, query: query).compactMap {
            Self.desktopMediaEntry($0, categoryName: $0.category.rawValue)
        }
    }

    /// The panel's entry for `e`, or nil when the panel has no category named `categoryName`: a category added to
    /// `ProjectMediaCategory` but not to `DesktopMediaCategory` hides those files instead of crashing the media
    /// panel (#25); `MediaCategoryMappingTests` fails until both enums carry it. Spelled `Optional<…>` because the
    /// fallback scanner counts a type name ending in "try" plus "?" as an optional try (TODO(#46)).
    static func desktopMediaEntry(_ e: ProjectMediaEntry, categoryName: String) -> Optional<DesktopMediaEntry> {
        guard let category = DesktopMediaCategory(rawValue: categoryName) else { return nil }
        return DesktopMediaEntry(path: e.path, name: e.name, category: category, size: e.size, modified: e.modified, used: e.used,
                                 description: e.description, duration: e.duration, width: e.width, height: e.height)
    }

    public func mediaStreams(projectId: String, source: String) async throws -> DesktopMediaStreams {
        let dir = try store(projectId).directory
        return try await blocking { c in
            let m = try readProjectMediaMetadata(dir, source, cancellation: c)
            return DesktopMediaStreams(duration: m.duration, hasVideo: m.hasVideo, hasAudio: m.hasAudio, width: m.width, height: m.height)
        }
    }

    public func waveform(projectId: String, source: String, bars: Int) async throws -> [Double] {
        let dir = try store(projectId).directory
        return try await blocking { c in try WaveformPeaks.forProjectMedia(dir, source, bars: bars, cancellation: c) }
    }

    public func videoFrames(projectId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        try await frames(try store(projectId).directory, request)
    }

    public func silences(projectId: String, source: String, sourceStart: Double, sourceDuration: Double) async throws -> [DesktopTimeRange] {
        let dir = try store(projectId).directory
        return try await blocking { c in
            try analyzeProjectVideoSilence(dir, SilenceAnalysisRequest(source: source, sourceStart: sourceStart, sourceDuration: sourceDuration),
                                           cancellation: c).map { DesktopTimeRange(start: $0.start, end: $0.end) }
        }
    }

    public func renameMedia(projectId: String, from: String, to: String, content: String) throws -> DesktopMediaOperation {
        let s = try store(projectId)
        let r = try exclusive(s) { try s.renameMedia(from, to: to, content: content) }
        return DesktopMediaOperation(path: r.path, content: r.content, updatedAssets: r.updatedAssets, removedClips: r.removedClips)
    }

    public func deleteMedia(projectId: String, path: String, removeUsages: Bool, content: String) throws -> DesktopMediaOperation {
        let s = try store(projectId)
        let r = try exclusive(s) { try s.deleteMedia(path, removeUsages: removeUsages, content: content) }
        return DesktopMediaOperation(path: r.path, content: r.content, updatedAssets: r.updatedAssets, removedClips: r.removedClips)
    }

    public func duplicateMedia(projectId: String, path: String) throws -> String {
        let s = try store(projectId)
        return try exclusive(s) { try duplicateProjectMedia(s.directory, path, durableWrite: durableWrite) }
    }

    // MARK: Libraries

    public func libraryViews() async throws -> [DesktopLibraryView] {
        await library.views().map { v in
            let placements = (try? library.placements(v.id)) ?? []
            return DesktopLibraryView(id: v.id, name: v.name, path: v.path,
                events: v.events.map { DesktopLibraryEvent(id: $0.id, name: $0.name) },
                projects: v.projects.map { DesktopLibraryProject(id: $0.id, eventId: $0.eventId, name: $0.name, ready: $0.state == .ready,
                                                                 directory: PosixPath.join(v.path, "Projects", $0.id)) },
                assets: v.assets.map { a in
                    DesktopLibraryAsset(id: a.id, eventId: a.eventId, name: a.name, kind: a.kind, mode: a.mode.rawValue, ready: a.state == .ready,
                                        available: a.available ?? false,
                                        projectIds: placements.filter { $0.assetId == a.id }.map(\.projectId))
                },
                exports: v.jobs.map { DesktopLibraryExport(id: $0.id, projectId: $0.projectId, status: $0.status, output: $0.output, error: $0.error) })
        }
    }

    /// (folder, file name) of a library asset: media tools confine reads to the file's own folder.
    private func libraryAssetLocation(_ libraryId: String, _ assetId: String) throws -> (String, String) {
        let path = try mapErrors { try library.assetPath(libraryId, assetId) }
        return (PosixPath.dirname(path), PosixPath.basename(path))
    }

    public func libraryAssetStreams(libraryId: String, assetId: String) async throws -> DesktopMediaStreams {
        let (dir, name) = try libraryAssetLocation(libraryId, assetId)
        return try await blocking { c in
            let m = try readProjectMediaMetadata(dir, name, cancellation: c)
            return DesktopMediaStreams(duration: m.duration, hasVideo: m.hasVideo, hasAudio: m.hasAudio, width: m.width, height: m.height)
        }
    }

    public func libraryAssetFrames(libraryId: String, assetId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        let (dir, name) = try libraryAssetLocation(libraryId, assetId)
        var r = request; r.source = name
        return try await frames(dir, r)
    }

    public func libraryAssetWaveform(libraryId: String, assetId: String, bars: Int) async throws -> [Double] {
        let (dir, name) = try libraryAssetLocation(libraryId, assetId)
        // No cache folder next to the user's (possibly linked) originals.
        return try await blocking { c in try WaveformPeaks.forProjectMedia(dir, name, bars: bars, cache: false, cancellation: c) }
    }

    private func frames(_ dir: String, _ request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        return try await blocking { c in
            let r = try decodeNativeVideoFrames(dir, VideoFramesRequest(source: request.source, sourceStart: request.sourceStart,
                sourceRangeDuration: request.sourceRangeDuration, frameCount: request.frameCount, width: request.width, height: request.height),
                cancellation: c)
            return DesktopVideoFrames(duration: r.duration, aspect: r.aspect, width: r.width, height: r.height,
                                      jpegFrames: r.frames.compactMap { Data(base64Encoded: $0) })
        }
    }

    // MARK: Renders

    public func rendersDirectory(projectId: String) throws -> String {
        let s = try store(projectId)
        if isLibraryProject(s), let dir = try mapErrors({ try library.outputDirectory(s.id) }) {
            return dir
        }
        // Shared by standalone projects: Settings > Default export folder, else `<userData>/renders`.
        return preferences?.defaultExportFolder ?? PosixPath.join(userData, "renders")
    }

    public func renders(projectId: String) throws -> [DesktopRender] {
        let dir = try rendersDirectory(projectId: projectId)
        // A folder the user chose may hold their own videos: only files named like a render are the history.
        let chosen = dir == preferences?.defaultExportFolder
        return ProjectRenders.list(dir).filter { !chosen || ProjectRenders.isRenderId($0.id) }.map {
            DesktopRender(id: $0.id, filename: $0.filename, path: $0.path, size: $0.size, createdAt: $0.createdAt,
                          status: $0.status.rawValue, durationMs: $0.durationMs)
        }
    }

    public func renderOutputPath(projectId: String, jobId: String, format: String) throws -> String {
        let dir = try rendersDirectory(projectId: projectId)
        let path = try mapErrors { try ProjectRenders.outputPath(dir, jobId: jobId, format: format) }
        lock.withLock { renderDirs[jobId] = dir }
        return path
    }

    public func recordRender(projectId: String, jobId: String, failed: Bool, durationMs: Double?) throws {
        let dir = try rendersDirectory(projectId: projectId)
        try mapErrors { try ProjectRenders.recordOutcome(dir, jobId: jobId, failed: failed, durationMs: durationMs) }
    }

    public func deleteRender(projectId: String, id: String) throws {
        let dir = try lock.withLock({ renderDirs[id] }) ?? rendersDirectory(projectId: projectId)
        _ = try mapErrors { try ProjectRenders.delete(dir, id: id) }
    }

    public func renderFrames(projectId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        try await frames(try rendersDirectory(projectId: projectId), request)
    }

    public func installedFontFamilies() -> [String] { InstalledFonts.families() }

    // MARK: Export source (library snapshots)

    private func isLibraryProject(_ s: ProjectDocumentStore) -> Bool {
        guard let entry = library.resolveProject(s.id) else { return false }
        return realPath(entry.dir) == s.directory
    }

    public func beginExport(projectId: String, settings: JSONValue) async throws -> DesktopExportSource {
        let s = try store(projectId)
        guard isLibraryProject(s) else { return DesktopExportSource(directory: s.directory) }
        let native = (try? NativeJSONValue.parse(settings.serialized())) ?? .object(NativeJSONObject())
        let snapshot = try await mapErrorsAsync { try await self.library.snapshot(s.id, settings: native) }
        guard let snapshot else { return DesktopExportSource(directory: s.directory) }
        return DesktopExportSource(directory: snapshot.dir, snapshotId: snapshot.id, libraryId: snapshot.libraryId)
    }

    public func trackExport(_ source: DesktopExportSource, status: @escaping @Sendable () -> DesktopExportStatus) {
        guard let id = source.snapshotId, let libraryId = source.libraryId else { return }
        library.trackExport(LibrarySnapshot(id: id, dir: source.directory, libraryId: libraryId)) {
            let s = status()
            return LibraryExportStatus(status: s.status, outputPath: s.outputPath, error: s.error)
        }
    }

    public func abandonExport(_ source: DesktopExportSource, error: String) async throws {
        guard let id = source.snapshotId, let libraryId = source.libraryId else { return }
        try await mapErrorsAsync { try await self.library.failSnapshot(LibrarySnapshot(id: id, dir: source.directory, libraryId: libraryId), error) }
    }

    // MARK: Media import

    /// Copies files into the project: the library's managed import for a library project, otherwise into
    /// the project folder (under `directory` when given). Returns project-relative paths.
    private func copyIntoProject(_ s: ProjectDocumentStore, _ paths: [String], _ directory: String?) async throws -> LocalMediaImportResult {
        if let entry = library.resolveProject(s.id), realPath(entry.dir) == s.directory {
            return try await library.importForProject(s.id, paths)
        }
        return try importLocalMedia(projectRoot: s.directory, paths: paths, directory: directory, durableWrite: durableWrite)
    }

    public func importMedia(projectId: String, paths: [String], directory: String?) async throws -> DesktopMediaImport {
        try checkOpen()
        let s = try store(projectId)
        return try await withProject(projectId) {
            let copied = try await self.mapErrorsAsync { try await self.copyIntoProject(s, paths, directory) }
            let described = describeImportedMedia(projectDir: s.directory, files: copied.files)
            return DesktopMediaImport(
                media: described.media.map { DesktopImportedMedia(path: $0.path, name: $0.name, kind: $0.kind.rawValue,
                                                                  duration: $0.duration, hasVideo: $0.hasVideo, hasAudio: $0.hasAudio,
                                                                  width: $0.width, height: $0.height) },
                invalid: (copied.invalid + described.invalid).map { DesktopImportFailure(name: $0.name, reason: $0.reason) },
                notices: described.media.compactMap { m in m.notice.map { DesktopImportFailure(name: m.name, reason: $0) } })
        }
    }

    public func importFiles(projectId: String, paths: [String], directory: String?) async throws -> JSONValue {
        try checkOpen()
        let s = try store(projectId)
        return try await withProject(projectId) {
            let r = try await self.mapErrorsAsync { try await self.copyIntoProject(s, paths, directory) }
            return .object(["files": .array(r.files.map { .string($0) }),
                            "invalid": .array(r.invalid.map { .object(["name": .string($0.name), "reason": .string($0.reason)]) })])
        }
    }

    // MARK: Runtime

    public func openCrosspost(projectId: String, filename: String) async throws {
        throw DesktopError("Publishing is not supported in the native app", name: "NotSupportedError")
    }

    public func withProject<T: Sendable>(_ projectId: String, _ body: @Sendable () async throws -> T) async throws -> T {
        let key = lock.withLock { stores[projectId]?.directory } ?? projectId
        return try await withoutActuallyEscaping(body) { escapable in
            try await access.run(key) { try await escapable() }
        }
    }

    public var libraries: MpvfxDesktopCore.LibraryService? { bridge }

    public func close() async throws {
        let already = lock.withLock { () -> Bool in defer { closed = true }; return closed }
        if already { return }
        for w in lock.withLock({ Array(watchers.values) }) { w.stop() }
        await access.drain()
        await library.close()
    }

    // MARK: Errors

    private func mapErrors<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw Self.desktopError(error) }
    }
    private func mapErrorsAsync<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.desktopError(error) }
    }
    static func desktopError(_ error: Error) -> DesktopError {
        switch error {
        case let e as DesktopError: return e
        case let e as ProjectDocumentError: return DesktopError(e.message, name: e.kind == .conflict ? "ConflictError" : "Error")
        case let e as ProjectMediaOperationError:
            return DesktopError(e.message, name: e.kind == .inUse ? "MediaInUseError" : e.kind == .exists ? "ConflictError" : "Error")
        case let e as ProjectsError: return DesktopError(e.message)
        case let e as MediaToolError: return DesktopError(e.message)
        case let e as LibraryError: return DesktopError(e.message)
        default: return DesktopError("\(error)")
        }
    }
}

/// realpath(3) (the final path on Windows), as the project store records directories. Not `URL.resolvingSymlinksInPath()`: on macOS that maps
/// `/private/var/…` back to `/var/…`, so it never equals a realpath under the temporary or /tmp directories.
func realPath(_ path: String) -> String {
    do { return try nativeRealPath(path) } catch { return path }   // a path that cannot be resolved compares as given
}
