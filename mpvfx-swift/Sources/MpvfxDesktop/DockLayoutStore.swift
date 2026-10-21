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
import MpvfxDesktopCore
import MpvfxPanels

/// `<userData>/dock-layout.json`: read once at startup, written after every committed layout change through
/// `NativeDurableWrite` (temp file, fsync, rename, folder fsync), so a crash mid-write leaves the previous file.
/// Writes run on one serial queue, newest last; a write that fails is reported once through `onWriteError` and the
/// layout in memory stays as it is.
final class DockLayoutStore: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "mpvfx.dock-layout.write")
    private let lock = NSLock()
    private var pending: Data?
    private var reported = false
    /// Called (on the write queue) with the first failure of a run.
    var onWriteError: (Error) -> Void = { e in
        FileHandle.standardError.write(Data("[MpVFX] panel layout not saved: \(e)\n".utf8))
    }

    init(userData: String) { path = (userData as NSString).appendingPathComponent("dock-layout.json") }

    /// The saved file's bytes; nil when there is none (the first launch) or it cannot be read.
    func read() -> Data? { FileManager.default.contents(atPath: path) }

    /// The saved layout when it is usable, else `fallback`; a refused file is logged with its reason.
    func load(registry: DockRegistry, fallback: DockFile) -> DockFile {
        let result = DockCodec.load(read(), registry: registry, fallback: fallback)
        if let e = result.error { FileHandle.standardError.write(Data("[MpVFX] panel layout reset: \(e)\n".utf8)) }
        for note in result.notes { FileHandle.standardError.write(Data("[MpVFX] panel layout: \(note)\n".utf8)) }
        return result.file
    }

    /// Queues a write of `file`; only the newest of several queued writes is written.
    func save(_ file: DockFile) {
        let data: Data
        do { data = try DockCodec.encode(file) } catch { FileHandle.standardError.write(Data("[MpVFX] panel layout not encoded: \(error)\n".utf8)); return }
        lock.withLock { pending = data }
        queue.async { [weak self] in self?.writePending() }
    }

    /// Blocks until every queued write has finished (quit, tests).
    func flush() { queue.sync {} }

    private func writePending() {
        guard let data = lock.withLock({ () -> Data? in defer { pending = nil }; return pending }) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try NativeDurableWrite().write(data, to: path, tempName: ".dock-layout.json.\(UUID().uuidString.lowercased()).tmp",
                                           preserveMode: true, beforeRename: {})
        } catch {
            report(error)
        }
    }

    private func report(_ e: Error) {
        let first = lock.withLock { () -> Bool in defer { reported = true }; return !reported }
        if first { onWriteError(e) }
    }
}
