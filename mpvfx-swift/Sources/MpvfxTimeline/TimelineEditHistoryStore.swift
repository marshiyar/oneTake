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

/// Undo/redo history that survives a restart:
/// per project, at most `maxHistoryEntries` entries, each holding the document it returns to. It is only taken back
/// when the document on disk is the one the history was saved against (a content-hash check), so an external
/// edit in between drops it instead of undoing into a different file.
public struct TimelinePersistedHistory: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var label: String
        public var time: Double
        /// The document undo (or redo) of this entry returns to.
        public var document: NativeProjectDocument
    }
    public static let version = 1
    public var version = TimelinePersistedHistory.version
    public var documentHash: String
    public var undo: [Entry]
    public var redo: [Entry]
}

public extension TimelineEditor {
    /// Stable content hash of a document (FNV-1a 64 over its sorted-key JSON).
    static func documentHash(_ doc: NativeProjectDocument) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(doc)) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The stacks as documents: each inverse is played back from the current document (pure; nothing changes).
    /// Entries past one that cannot be played back are dropped. Costs a document clone per entry (up to
    /// `maxHistoryEntries` per stack): hosts that persist after every edit take `historySnapshot()` on the UI
    /// thread and call `persisted()` on a worker.
    func persistedHistory() -> TimelinePersistedHistory { historySnapshot().persisted() }

    /// The current document and stacks, captured in O(1) (value copies), for `persisted()` off the UI thread.
    func historySnapshot() -> TimelineHistorySnapshot {
        TimelineHistorySnapshot(document: document, undo: undoStack, redo: redoStack, engine: engine)
    }

    /// Take a saved history back when it was saved against this document. Returns false (history untouched) otherwise.
    @discardableResult
    func restoreHistory(_ h: TimelinePersistedHistory) -> Bool {
        guard h.version == TimelinePersistedHistory.version, h.documentHash == Self.documentHash(document) else { return false }
        undoStack = h.undo.suffix(maxHistoryEntries).map { TimelineHistoryEntry(inverse: .restoreDocument($0.document), label: $0.label, coalesceKey: nil, time: $0.time) }
        redoStack = h.redo.map { TimelineHistoryEntry(inverse: .restoreDocument($0.document), label: $0.label, coalesceKey: nil, time: $0.time) }
        onChange?()
        return true
    }
}

/// The editor's document and undo/redo stacks at one moment. `persisted()` is pure and may run on any thread
/// (the keyframe engine it replays through is thread-safe).
public struct TimelineHistorySnapshot: @unchecked Sendable {
    public let document: NativeProjectDocument
    public let undo: [TimelineHistoryEntry]
    public let redo: [TimelineHistoryEntry]
    let engine: KeyframeEngine?

    public func persisted() -> TimelinePersistedHistory {
        func walk(_ stack: [TimelineHistoryEntry]) -> [TimelinePersistedHistory.Entry] {
            var cur = document, out: [TimelinePersistedHistory.Entry] = []
            for e in stack.reversed() {
                guard let r = try? applyNativeProjectClipCommand(cur, e.inverse, engine: engine), case .success(let doc, _) = r else { break }
                out.append(.init(label: e.label, time: e.time, document: doc)); cur = doc
            }
            return out.reversed()
        }
        return TimelinePersistedHistory(documentHash: TimelineEditor.documentHash(document), undo: walk(undo), redo: walk(redo))
    }
}

/// One JSON file per project under a directory.
public final class FileTimelineHistoryStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    func url(_ projectId: String) -> URL {
        let safe = String(projectId.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
        return directory.appendingPathComponent("\(safe)-\(TimelineHistoryHash.short(projectId)).json")
    }

    public func load(projectId: String) -> TimelinePersistedHistory? {
        guard let data = try? Data(contentsOf: url(projectId)) else { return nil }
        return try? JSONDecoder().decode(TimelinePersistedHistory.self, from: data)
    }

    public func save(projectId: String, _ h: TimelinePersistedHistory) {
        guard let data = try? JSONEncoder().encode(h) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(projectId), options: .atomic)
    }

    public func delete(projectId: String) { try? FileManager.default.removeItem(at: url(projectId)) }
}

enum TimelineHistoryHash {
    static func short(_ s: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
        return String(h, radix: 16)
    }
}

/// Writes the persisted history after edits without costing the UI thread: `submit` only stores the snapshot
/// (O(1)); a utility worker replays it into documents and writes the file. Snapshots submitted while the worker
/// is busy collapse into the newest one, so a burst of edits (a slider drag, preset clicks) costs one replay
/// and one write when the worker comes free, not one per edit.
public final class TimelineHistoryPersister: @unchecked Sendable {
    let save: (TimelinePersistedHistory) -> Void
    let queue = DispatchQueue(label: "mpvfx.edit-history", qos: .utility)
    /// Guards the fields below; signalled when the worker goes idle (`waitUntilIdle(timeout:)`).
    let lock = NSCondition()
    var pending: TimelineHistorySnapshot?
    var scheduled = false
    var writes_ = 0

    public init(save: @escaping (TimelinePersistedHistory) -> Void) { self.save = save }
    public convenience init(store: FileTimelineHistoryStore, projectId: String) {
        self.init { store.save(projectId: projectId, $0) }
    }

    /// Called on the waiting thread, outside the lock, when `waitUntilIdle(timeout:)` finds a write still to
    /// finish; tests hold a write back and release it here to prove the closer really waits for it.
    public var onWait: (() -> Void)?

    /// Histories written so far (collapsed snapshots are not counted).
    public var writes: Int { lock.lock(); defer { lock.unlock() }; return writes_ }

    public func submit(_ snapshot: TimelineHistorySnapshot) {
        lock.lock()
        pending = snapshot
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Blocks until every submitted snapshot is written (tests).
    public func waitUntilIdle() {
        lock.lock(); defer { lock.unlock() }
        while scheduled { lock.wait() }
    }

    /// Blocks until every submitted snapshot is written or `timeout` seconds pass; true when written. The quit
    /// path waits here so the last edit's history reaches the file, but a stuck disk cannot hold the app open.
    /// Never call it on the persister's own queue (the worker would wait on itself). The deadline stays finite:
    /// `NSCondition.wait(until: .distantFuture)` traps on Linux, so an unbounded wait is `waitUntilIdle()`.
    @discardableResult
    public func waitUntilIdle(timeout: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        if scheduled, let onWait { lock.unlock(); onWait(); lock.lock() }
        defer { lock.unlock() }
        while scheduled {
            if !lock.wait(until: deadline) { return !scheduled }
        }
        return true
    }

    func drain() {
        while true {
            lock.lock()
            guard let s = pending else { scheduled = false; lock.broadcast(); lock.unlock(); return }
            pending = nil
            lock.unlock()
            save(s.persisted())
            lock.lock(); writes_ += 1; lock.unlock()
        }
    }
}
