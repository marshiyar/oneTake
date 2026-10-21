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
// Projects the app knows about: every project folder in the projects directory, the recently opened
// list (persisted in user data), and a watcher that notices when the open document changes on disk.
import Foundation
import MpvfxShared

public struct ProjectSummary: Equatable, Sendable {
    public var directory: String
    /// The document id.
    public var id: String
    /// The main sequence name, else the folder name.
    public var title: String
    /// Modification time of the document, seconds since 1970.
    public var modified: Double
}

public enum ProjectCatalog {
    /// Summary of the project in `directory`; nil when it is not a readable project. The directory is
    /// reported as realpath(3), as open project stores record it (macOS /var is /private/var).
    public static func summary(_ directory0: String) -> ProjectSummary? {
        let directory = (try? ProjectFS.realpath(directory0)) ?? directory0
        let path = PosixPath.join(directory, NATIVE_PROJECT_DOCUMENT_PATH)
        guard let text = try? ProjectFS.readUTF8(path), let doc = try? ProjectDocuments.validate(text),
              let info = try? ProjectFS.statInfo(path) else { return nil }
        let name = doc.sequence.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty || name == "Main" ? PosixPath.basename(directory) : name
        return ProjectSummary(directory: directory, id: doc.id, title: title, modified: Double(info.mtimeNs) / 1e9)
    }

    /// Every project folder directly inside `projectsDir`, newest first.
    public static func list(_ projectsDir: String) -> [ProjectSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projectsDir)) ?? []
        return names.compactMap { name -> ProjectSummary? in
            guard !name.hasPrefix(".") else { return nil }
            return summary(PosixPath.join(projectsDir, name))
        }.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.directory < $1.directory }
    }
}

/// Recently opened project folders, newest first, persisted as a JSON array in `<userData>/recent-projects.json`.
public final class RecentProjects: @unchecked Sendable {
    public static let limit = 12
    private let file: String
    private let lock = NSLock()
    private var paths: [String]

    public init(userData: String) {
        file = PosixPath.join(userData, "recent-projects.json")
        let stored = (try? ProjectFS.readUTF8(file)).flatMap { try? NativeJSONValue.parse($0) }?.arrayValue ?? []
        paths = stored.compactMap(\.stringValue)
    }

    /// Recorded folders that still hold a project, newest first.
    public func list() -> [ProjectSummary] { lock.withLock { paths }.compactMap(ProjectCatalog.summary) }

    public func add(_ directory: String) throws {
        let snapshot: [String] = lock.withLock {
            paths.removeAll { $0 == directory }
            paths.insert(directory, at: 0)
            if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
            return paths
        }
        try persist(snapshot)
    }

    public func remove(_ directory: String) throws {
        let snapshot: [String] = lock.withLock { paths.removeAll { $0 == directory }; return paths }
        try persist(snapshot)
    }

    /// Every recorded folder, also those `list()` leaves out because they are not there now (an unmounted drive).
    public func removeAll() throws {
        lock.withLock { paths = [] }
        try persist([])
    }

    private func persist(_ list: [String]) throws {
        try ProjectFS.mkdirRecursive(PosixPath.dirname(file))
        try libraryAtomicJson(file, .array(list.map { .string($0) }))
    }
}

/// Polls an open project's document and reports content that differs from what the store last read or
/// saved: an edit made outside the app (another editor, a sync client, version control).
public final class ProjectDocumentWatcher: @unchecked Sendable {
    private let store: ProjectDocumentStore
    private let interval: Double
    private let onChange: @Sendable (String) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var lastStamp: (Int64, Int128, UInt64)?
    private var lastReported: String?

    /// `onChange` runs on a background queue with the document text now on disk.
    public init(store: ProjectDocumentStore, interval: Double = 1, onChange: @escaping @Sendable (String) -> Void) {
        self.store = store; self.interval = interval; self.onChange = onChange
        schedule()
    }

    public func stop() { lock.withLock { stopped = true } }

    private func schedule() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            self.check()
            self.schedule()
        }
    }

    /// One poll; public so tests and the backend can check on demand.
    public func check() {
        let path = PosixPath.join(store.directory, NATIVE_PROJECT_DOCUMENT_PATH)
        guard let info = try? ProjectFS.statInfo(path) else { return }
        let stamp = (info.size, info.mtimeNs, info.ino)
        if let last = lastStamp, last == stamp { return }
        lastStamp = stamp
        guard let text = try? ProjectFS.readUTF8(path), text != store.savedContent, text != lastReported else { return }
        lastReported = text
        onChange(text)
    }
}
