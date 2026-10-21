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
// What the desktop shell needs from the native runtime (projects, library, media import, publishing, shutdown).
import Foundation

/// An error with a name ("Error", "AbortError") and a message, shown to the user as is.
public struct DesktopError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum SaveFailure: String, Sendable {
        case diskFull = "ENOSPC", quotaExceeded = "EDQUOT", readOnly = "EROFS"
        case permissionDenied = "EACCES", folderMissing = "ENOENT"

        public var reason: String {
            switch self {
            case .diskFull: return "The disk is full"
            case .quotaExceeded: return "The storage quota is full"
            case .readOnly: return "The folder is read-only"
            case .permissionDenied: return "Permission to write was denied"
            case .folderMissing: return "The project folder is unavailable"
            }
        }
    }
    public var name: String
    public var message: String
    public private(set) var saveFailure: SaveFailure?
    public init(_ message: String, name: String = "Error") { self.message = message; self.name = name }
    public init(saveFailure: SaveFailure, folder: String) {
        self.saveFailure = saveFailure
        name = "SaveError"
        let action: String
        switch saveFailure {
        case .diskFull: action = "The disk holding \(folder) is full. Free some space."
        case .quotaExceeded: action = "The storage quota for \(folder) is full. Free some space or increase the quota."
        case .readOnly: action = "The folder \(folder) is read-only. Make the folder or its drive writable."
        case .permissionDenied: action = "MpVFX cannot write to \(folder). Give your account permission to write to this folder."
        case .folderMissing: action = "The project folder \(folder) is unavailable. Reconnect its drive or restore the folder."
        }
        message = action + " Your edits are kept in memory. Once this is fixed, save again or keep editing to retry."
    }
    public var description: String { message }
    public static func notImplemented(_ what: String) -> DesktopError {
        DesktopError("\(what) is not implemented yet")
    }
}

/// Library operations (LibraryService in MpvfxRuntime).
public protocol LibraryService: Sendable {
    func views() async throws -> JSONValue
    func create(root: String) async throws -> String
    func open(root: String) async throws -> String
    func createEvent(libraryId: String, name: String) async throws
    func createProject(libraryId: String, eventId: String, name: String) async throws -> String
    /// Returns invalid entries as (name, reason).
    func importMedia(libraryId: String, eventId: String, paths: [String], mode: String, projectId: String?) async throws -> [(String, String)]
    func attach(libraryId: String, projectId: String, assetId: String) async throws -> String
    func relink(libraryId: String, assetId: String, path: String) async throws
    func root(libraryId: String) throws -> String
    func saveOutput(libraryId: String, jobId: String, destination: String, overwrite: Bool) async throws
    func renameEvent(libraryId: String, eventId: String, name: String) async throws
    func renameProject(libraryId: String, projectId: String, name: String) async throws
}

/// An open project: its id, its directory, and the native document text as last read or saved.
public struct DesktopProject: Equatable, Sendable {
    public var id: String
    public var directory: String
    public var content: String
    public init(id: String, directory: String, content: String) { self.id = id; self.directory = directory; self.content = content }
}

/// One file copied into a project by `importMedia`, with the stream facts the editor needs.
public struct DesktopImportedMedia: Equatable, Sendable {
    /// Project-relative path of the copy.
    public var path: String
    public var name: String
    /// "video", "audio", "image", "font" or "lut".
    public var kind: String
    /// Seconds (0 for stills).
    public var duration: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Natural picture size probed during the import (sample aspect, rotation, EXIF orientation); nil when unknown.
    public var width: Double? = nil, height: Double? = nil
    public init(path: String, name: String, kind: String, duration: Double, hasVideo: Bool, hasAudio: Bool,
                width: Double? = nil, height: Double? = nil) {
        self.path = path; self.name = name; self.kind = kind; self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio
        self.width = width; self.height = height
    }
}

public struct DesktopMediaImport: Equatable, Sendable {
    public var media: [DesktopImportedMedia]
    /// (file name, reason) for each file that was not imported.
    public var invalid: [DesktopImportFailure]
    /// (file name, reason) for each imported file that came in without part of it, e.g. a video whose sound uses a
    /// codec the editor cannot decode yet (it imports without sound).
    public var notices: [DesktopImportFailure] = []
    public init(media: [DesktopImportedMedia] = [], invalid: [DesktopImportFailure] = [], notices: [DesktopImportFailure] = []) {
        self.media = media; self.invalid = invalid; self.notices = notices
    }
}

public struct DesktopImportFailure: Equatable, Sendable {
    public var name: String
    public var reason: String
    public init(name: String, reason: String) { self.name = name; self.reason = reason }
}

/// A project the app can open (projects folder, recent list, or a library).
public struct DesktopProjectSummary: Equatable, Sendable {
    public var directory: String
    /// The document id.
    public var id: String
    public var title: String
    /// Document modification time, seconds since 1970.
    public var modified: Double
    /// Set for a project that belongs to an open library.
    public var libraryProjectId: String?
    public init(directory: String, id: String, title: String, modified: Double, libraryProjectId: String? = nil) {
        self.directory = directory; self.id = id; self.title = title; self.modified = modified; self.libraryProjectId = libraryProjectId
    }
}

/// Assets panel groups, in panel order.
public enum DesktopMediaCategory: String, CaseIterable, Sendable { case audio, images, video, fonts }

/// One media or font file in a project.
public struct DesktopMediaEntry: Equatable, Sendable {
    public var path: String
    public var name: String
    public var category: DesktopMediaCategory
    public var size: Int64
    public var modified: Double
    /// A document asset points at the file.
    public var used: Bool
    /// From the project's `.media/manifest.jsonl`, when present.
    public var description: String?
    public var duration: Double?
    public var width: Double?
    public var height: Double?
    public init(path: String, name: String, category: DesktopMediaCategory, size: Int64, modified: Double, used: Bool,
                description: String? = nil, duration: Double? = nil, width: Double? = nil, height: Double? = nil) {
        self.path = path; self.name = name; self.category = category; self.size = size; self.modified = modified; self.used = used
        self.description = description; self.duration = duration; self.width = width; self.height = height
    }
}

/// Probe facts for one project media file (the media engine's MediaProbe).
public struct DesktopMediaStreams: Equatable, Sendable {
    public var duration: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Natural picture size (sample aspect applied, swapped for a 90° rotation); nil without a picture.
    public var width: Double?, height: Double?
    public init(duration: Double, hasVideo: Bool, hasAudio: Bool, width: Double? = nil, height: Double? = nil) {
        self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.width = width; self.height = height
    }
}

/// Thumbnail strip request: 1-6 frames of at most 480x270, optionally from a source range (seconds).
public struct DesktopVideoFramesRequest: Equatable, Sendable {
    public var source: String
    public var sourceStart: Double?
    public var sourceRangeDuration: Double?
    public var frameCount: Int
    public var width: Int
    public var height: Int
    public init(source: String, sourceStart: Double? = nil, sourceRangeDuration: Double? = nil, frameCount: Int, width: Int, height: Int) {
        self.source = source; self.sourceStart = sourceStart; self.sourceRangeDuration = sourceRangeDuration
        self.frameCount = frameCount; self.width = width; self.height = height
    }
}

/// Decoded thumbnails: JPEG bytes per frame.
public struct DesktopVideoFrames: Equatable, Sendable {
    public var duration: Double
    public var aspect: Double
    public var width: Int
    public var height: Int
    public var jpegFrames: [Data]
    public init(duration: Double, aspect: Double, width: Int, height: Int, jpegFrames: [Data]) {
        self.duration = duration; self.aspect = aspect; self.width = width; self.height = height; self.jpegFrames = jpegFrames
    }
}

/// A pause in a video's audio, in source seconds.
public struct DesktopTimeRange: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Result of renaming or deleting project media.
public struct DesktopMediaOperation: Equatable, Sendable {
    /// New path (rename) or recovery copy (delete).
    public var path: String
    /// Document text after the edit; already saved. The editor loads it.
    public var content: String
    public var updatedAssets: Int
    public var removedClips: Int
    public init(path: String, content: String, updatedAssets: Int, removedClips: Int) {
        self.path = path; self.content = content; self.updatedAssets = updatedAssets; self.removedClips = removedClips
    }
}

/// Result of `importCaptions`: the document text with the new caption track, already saved; the editor loads it.
public struct DesktopCaptionImport: Equatable, Sendable {
    public var content: String
    public var cueCount: Int
    public init(content: String, cueCount: Int) { self.content = content; self.cueCount = cueCount }
}

/// A library as the sidebar shows it: its events, projects, media and exports.
public struct DesktopLibraryView: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The `.mpvfxlibrary` folder.
    public var path: String
    public var events: [DesktopLibraryEvent]
    public var projects: [DesktopLibraryProject]
    public var assets: [DesktopLibraryAsset]
    public var exports: [DesktopLibraryExport]
    public init(id: String, name: String, path: String, events: [DesktopLibraryEvent], projects: [DesktopLibraryProject],
                assets: [DesktopLibraryAsset], exports: [DesktopLibraryExport]) {
        self.id = id; self.name = name; self.path = path; self.events = events; self.projects = projects; self.assets = assets; self.exports = exports
    }
}
public struct DesktopLibraryEvent: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct DesktopLibraryProject: Equatable, Sendable {
    public var id: String
    public var eventId: String
    public var name: String
    public var ready: Bool
    /// The project folder inside the library (open it with `openProject(path:)`).
    public var directory: String
    public init(id: String, eventId: String, name: String, ready: Bool, directory: String) {
        self.id = id; self.eventId = eventId; self.name = name; self.ready = ready; self.directory = directory
    }
}
public struct DesktopLibraryAsset: Equatable, Sendable {
    public var id: String
    public var eventId: String
    public var name: String
    /// "video", "audio", "image", "font" or "lut".
    public var kind: String
    /// "managed" (copied into the library) or "linked" (left in place).
    public var mode: String
    public var ready: Bool
    /// The file is reachable (a linked original may have moved: relink it).
    public var available: Bool
    /// Projects the asset was added to.
    public var projectIds: [String]
    public init(id: String, eventId: String, name: String, kind: String, mode: String, ready: Bool, available: Bool, projectIds: [String]) {
        self.id = id; self.eventId = eventId; self.name = name; self.kind = kind; self.mode = mode
        self.ready = ready; self.available = available; self.projectIds = projectIds
    }
}
public struct DesktopLibraryExport: Equatable, Sendable {
    public var id: String
    public var projectId: String
    /// "rendering", "complete", "failed" or "cancelled".
    public var status: String
    /// Absolute path of the output (empty until complete).
    public var output: String
    public var error: String
    public init(id: String, projectId: String, status: String, output: String, error: String) {
        self.id = id; self.projectId = projectId; self.status = status; self.output = output; self.error = error
    }
}

/// One finished export in a project's render history (Renders tab).
public struct DesktopRender: Equatable, Sendable {
    public var id: String
    public var filename: String
    public var path: String
    public var size: Int64
    /// Seconds since 1970.
    public var createdAt: Double
    /// "complete" or "failed".
    public var status: String
    public var durationMs: Double?
    public init(id: String, filename: String, path: String, size: Int64, createdAt: Double, status: String, durationMs: Double?) {
        self.id = id; self.filename = filename; self.path = path; self.size = size; self.createdAt = createdAt; self.status = status; self.durationMs = durationMs
    }
}

/// Where an export reads the project from. A library project exports from an isolated snapshot (a copy of
/// that revision) so editing during the render cannot change the output; the library tracks the job.
public struct DesktopExportSource: Equatable, Sendable {
    /// Directory to render from (the snapshot, or the project directory itself).
    public var directory: String
    /// Set for a library snapshot: pass it to `trackExport` / `abandonExport`.
    public var snapshotId: String?
    public var libraryId: String?
    public init(directory: String, snapshotId: String? = nil, libraryId: String? = nil) {
        self.directory = directory; self.snapshotId = snapshotId; self.libraryId = libraryId
    }
}

/// An export job's state as `trackExport` polls it: status "rendering", "complete", "failed" or "cancelled".
public struct DesktopExportStatus: Equatable, Sendable {
    public var status: String
    public var outputPath: String?
    public var error: String?
    public init(status: String, outputPath: String? = nil, error: String? = nil) { self.status = status; self.outputPath = outputPath; self.error = error }
}

public protocol DesktopBackend: Sendable {
    /// Creates a project. `directory` nil puts it in the app's projects folder.
    func createProject(name: String, directory: String?) throws -> DesktopProject
    /// Opens a project directory (or its `.studio/project.json`).
    func openProject(path: String) throws -> DesktopProject
    /// The default project the app opens when none is given (created on first launch).
    func openDefaultProject() throws -> DesktopProject
    /// Saves document text crash-safely. Throws when the file changed on disk since it was opened or saved.
    func saveProject(id: String, content: String) throws
    /// Rereads the document from disk (after an external change the user chose to take).
    func reloadProject(id: String) throws -> DesktopProject
    /// Stops tracking a project (and its watcher).
    func closeProject(id: String)
    /// Calls `onExternalChange` (on a background queue) with the new text whenever the document is changed
    /// on disk by anything other than this backend. Replaces an earlier watch on the same project.
    func watchProject(id: String, onExternalChange: @escaping @Sendable (String) -> Void) throws
    /// Like `watchProject(id:onExternalChange:)`, and also reports `.missing` when the project's folder was moved or
    /// deleted (`ProjectMoved.swift`). Replaces an earlier watch on the same project.
    func watchProjectEvents(id: String, onEvent: @escaping @Sendable (DesktopProjectEvent) -> Void) throws
    /// Points an open project at the folder it was moved to (`path`: the folder, its `.studio` or the document) and keeps
    /// its id and watch; returns the document found there. Nothing is written.
    func relocateProject(id: String, to path: String) throws -> DesktopProject
    /// Project folders in the projects directory and the open libraries, newest first.
    func listProjects() -> [DesktopProjectSummary]
    /// Recently opened projects that still exist, newest first.
    func recentProjects() -> [DesktopProjectSummary]
    func forgetRecentProject(directory: String) throws
    /// Forgets every recorded project, also those `recentProjects()` leaves out because they are not there now.
    func clearRecentProjects() throws

    /// The project's media and fonts, grouped in panel order, used first; `query` searches names and descriptions.
    func listMedia(projectId: String, query: String?) throws -> [DesktopMediaEntry]
    func mediaStreams(projectId: String, source: String) async throws -> DesktopMediaStreams
    /// Normalized peaks (0...1) of the file's first audio channel.
    func waveform(projectId: String, source: String, bars: Int) async throws -> [Double]
    func videoFrames(projectId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames
    /// Pauses in a video's audio within the source range.
    func silences(projectId: String, source: String, sourceStart: Double, sourceDuration: Double) async throws -> [DesktopTimeRange]
    /// Renames media and repoints the document's assets, saving `content` (the editor's document) in the same commit.
    func renameMedia(projectId: String, from: String, to: String, content: String) throws -> DesktopMediaOperation
    /// Moves media to the recovery folder. Placed media needs `removeUsages` (its clips and assets are removed).
    func deleteMedia(projectId: String, path: String, removeUsages: Bool, content: String) throws -> DesktopMediaOperation

    /// Copies a media file next to itself as "name (copy).ext" (then "(copy 2)", ...). Returns the new path.
    func duplicateMedia(projectId: String, path: String) throws -> String

    /// Reads an SRT file into the caption track of `content` (the editor's document) and saves it. All or nothing: a
    /// file that does not read in full throws an error naming its line, and nothing is saved.
    func importCaptions(projectId: String, path: String, content: String) throws -> DesktopCaptionImport
    /// Writes the caption track of `content` as an SRT file at `path` (crash-safe); returns the number of captions.
    func exportCaptions(projectId: String, path: String, content: String) throws -> Int

    /// Typed library views (the `libraries` service has the commands that change them).
    func libraryViews() async throws -> [DesktopLibraryView]
    func libraryAssetStreams(libraryId: String, assetId: String) async throws -> DesktopMediaStreams
    /// Thumbnails of a library asset; `request.source` is ignored.
    func libraryAssetFrames(libraryId: String, assetId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames
    func libraryAssetWaveform(libraryId: String, assetId: String, bars: Int) async throws -> [Double]

    /// Where the project's exports go: the library's renders folder for a library project, else the app's.
    func rendersDirectory(projectId: String) throws -> String
    /// Finished exports, newest first.
    func renders(projectId: String) throws -> [DesktopRender]
    /// Output path for a new export with this job id and format ("mp4", "webm", "mov").
    func renderOutputPath(projectId: String, jobId: String, format: String) throws -> String
    /// Records how an export ended so the history shows its duration and failures.
    func recordRender(projectId: String, jobId: String, failed: Bool, durationMs: Double?) throws
    func deleteRender(projectId: String, id: String) throws
    /// Thumbnails of a finished export; `request.source` is the render's filename.
    func renderFrames(projectId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames

    /// Call before starting an export: saves nothing, but for a library project copies the saved revision into
    /// a snapshot and opens a library job. `settings` are the export settings recorded with the job.
    func beginExport(projectId: String, settings: JSONValue) async throws -> DesktopExportSource
    /// Follows a started library export until it ends and records the result in the library (exports list).
    func trackExport(_ source: DesktopExportSource, status: @escaping @Sendable () -> DesktopExportStatus)
    /// The export did not start: marks the library job failed.
    func abandonExport(_ source: DesktopExportSource, error: String) async throws

    /// Font families installed on this computer, sorted.
    func installedFontFamilies() -> [String]

    /// Copies media into the project and reads its stream facts.
    func importMedia(projectId: String, paths: [String], directory: String?) async throws -> DesktopMediaImport
    /// `{ files, invalid }`: the copied files and the ones refused.
    func importFiles(projectId: String, paths: [String], directory: String?) async throws -> JSONValue
    func openCrosspost(projectId: String, filename: String) async throws
    /// Serialises work on one project.
    func withProject<T: Sendable>(_ projectId: String, _ body: @Sendable () async throws -> T) async throws -> T
    /// nil means "Library service is unavailable".
    var libraries: LibraryService? { get }
    /// Per-user settings kept in preferences.json (render settings, hidden renders); nil without a data directory.
    var preferences: DesktopPreferences? { get }
    func close() async throws
}

/// Backend for tests and hosts without a runtime. Every operation fails explicitly; nothing is faked.
public struct NotImplementedBackend: DesktopBackend {
    public init() {}
    public func createProject(name: String, directory: String?) throws -> DesktopProject { throw DesktopError.notImplemented("Projects") }
    public func openProject(path: String) throws -> DesktopProject { throw DesktopError.notImplemented("Projects") }
    public func openDefaultProject() throws -> DesktopProject { throw DesktopError.notImplemented("Projects") }
    public func saveProject(id: String, content: String) throws { throw DesktopError.notImplemented("Saving") }
    public func importMedia(projectId: String, paths: [String], directory: String?) async throws -> DesktopMediaImport {
        throw DesktopError.notImplemented("Media import")
    }
    public func reloadProject(id: String) throws -> DesktopProject { throw DesktopError.notImplemented("Projects") }
    public func closeProject(id: String) {}
    public func watchProject(id: String, onExternalChange: @escaping @Sendable (String) -> Void) throws { throw DesktopError.notImplemented("Projects") }
    public func listProjects() -> [DesktopProjectSummary] { [] }
    public func recentProjects() -> [DesktopProjectSummary] { [] }
    public func forgetRecentProject(directory: String) throws { throw DesktopError.notImplemented("Projects") }
    public func clearRecentProjects() throws { throw DesktopError.notImplemented("Projects") }
    public func listMedia(projectId: String, query: String?) throws -> [DesktopMediaEntry] { throw DesktopError.notImplemented("Media") }
    public func mediaStreams(projectId: String, source: String) async throws -> DesktopMediaStreams { throw DesktopError.notImplemented("Media") }
    public func waveform(projectId: String, source: String, bars: Int) async throws -> [Double] { throw DesktopError.notImplemented("Waveforms") }
    public func videoFrames(projectId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        throw DesktopError.notImplemented("Thumbnails")
    }
    public func silences(projectId: String, source: String, sourceStart: Double, sourceDuration: Double) async throws -> [DesktopTimeRange] {
        throw DesktopError.notImplemented("Silence analysis")
    }
    public func renameMedia(projectId: String, from: String, to: String, content: String) throws -> DesktopMediaOperation {
        throw DesktopError.notImplemented("Media")
    }
    public func deleteMedia(projectId: String, path: String, removeUsages: Bool, content: String) throws -> DesktopMediaOperation {
        throw DesktopError.notImplemented("Media")
    }
    public func duplicateMedia(projectId: String, path: String) throws -> String { throw DesktopError.notImplemented("Media") }
    public func libraryViews() async throws -> [DesktopLibraryView] { throw DesktopError.notImplemented("Libraries") }
    public func libraryAssetStreams(libraryId: String, assetId: String) async throws -> DesktopMediaStreams { throw DesktopError.notImplemented("Libraries") }
    public func libraryAssetFrames(libraryId: String, assetId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        throw DesktopError.notImplemented("Libraries")
    }
    public func libraryAssetWaveform(libraryId: String, assetId: String, bars: Int) async throws -> [Double] { throw DesktopError.notImplemented("Libraries") }
    public func rendersDirectory(projectId: String) throws -> String { throw DesktopError.notImplemented("Renders") }
    public func renders(projectId: String) throws -> [DesktopRender] { throw DesktopError.notImplemented("Renders") }
    public func renderOutputPath(projectId: String, jobId: String, format: String) throws -> String { throw DesktopError.notImplemented("Renders") }
    public func recordRender(projectId: String, jobId: String, failed: Bool, durationMs: Double?) throws { throw DesktopError.notImplemented("Renders") }
    public func deleteRender(projectId: String, id: String) throws { throw DesktopError.notImplemented("Renders") }
    public func renderFrames(projectId: String, request: DesktopVideoFramesRequest) async throws -> DesktopVideoFrames {
        throw DesktopError.notImplemented("Renders")
    }
    public func installedFontFamilies() -> [String] { [] }
    public func beginExport(projectId: String, settings: JSONValue) async throws -> DesktopExportSource { throw DesktopError.notImplemented("Export") }
    public func trackExport(_ source: DesktopExportSource, status: @escaping @Sendable () -> DesktopExportStatus) {}
    public func abandonExport(_ source: DesktopExportSource, error: String) async throws { throw DesktopError.notImplemented("Export") }
    public func importFiles(projectId: String, paths: [String], directory: String?) async throws -> JSONValue {
        throw DesktopError.notImplemented("Media import")
    }
    public func openCrosspost(projectId: String, filename: String) async throws { throw DesktopError.notImplemented("Publishing") }
    public func withProject<T: Sendable>(_ projectId: String, _ body: @Sendable () async throws -> T) async throws -> T { try await body() }
    public var libraries: LibraryService? { nil }
    public var preferences: DesktopPreferences? { nil }
    public func close() async throws {}
}

public extension NotImplementedBackend {
    func importCaptions(projectId: String, path: String, content: String) throws -> DesktopCaptionImport {
        throw DesktopError.notImplemented("Caption import")
    }
    func exportCaptions(projectId: String, path: String, content: String) throws -> Int { throw DesktopError.notImplemented("Caption export") }
}
