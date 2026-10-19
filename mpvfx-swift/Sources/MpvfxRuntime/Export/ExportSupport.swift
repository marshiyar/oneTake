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
// Export support: render cancellation leases, staging paths, and reading the project's native document.
import Foundation
import MpvfxShared

public struct ExportFailedError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: render cancellation leases

public let DEFAULT_RENDER_LEASE_TIMEOUT_MS = 90_000.0
public let DEFAULT_RENDER_LEASE_SWEEP_INTERVAL_MS = 2_500.0

public struct RenderCancellationLifecycle {
    public let cancellation: MediaCancellation
    public let cancel: () -> Void
    public let finish: () -> Void
}

public struct RenderJobAlreadyActiveError: Error, Equatable, CustomStringConvertible {
    public let jobId: String
    public var description: String { "Render job \"\(jobId)\" is already active" }
}

public final class RenderCancellationRegistry: @unchecked Sendable {
    private final class Entry { let cancellation = MediaCancellation(); var lastHeartbeatAt: Double; init(_ t: Double) { lastHeartbeatAt = t } }
    private let lock = NSLock()
    private var active: [String: Entry] = [:]
    private let now: () -> Double
    private let leaseTimeoutMs: Double
    private var timer: DispatchSourceTimer?

    /// `now` is milliseconds (Date.now). A positive sweep interval starts a background sweep timer.
    public init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                leaseTimeoutMs: Double = DEFAULT_RENDER_LEASE_TIMEOUT_MS, sweepIntervalMs: Double = DEFAULT_RENDER_LEASE_SWEEP_INTERVAL_MS) {
        self.now = now; self.leaseTimeoutMs = leaseTimeoutMs
        if sweepIntervalMs > 0 {
            let t = DispatchSource.makeTimerSource(queue: .global())
            let interval = DispatchTimeInterval.milliseconds(Int(Swift.max(1, sweepIntervalMs)))
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in _ = self?.sweepExpired() }
            t.resume(); timer = t
        }
    }
    deinit { timer?.cancel() }

    public func register(_ jobId: String) throws -> RenderCancellationLifecycle {
        lock.lock(); defer { lock.unlock() }
        if active[jobId] != nil { throw RenderJobAlreadyActiveError(jobId: jobId) }
        let entry = Entry(now())
        active[jobId] = entry
        return RenderCancellationLifecycle(cancellation: entry.cancellation, cancel: { [weak self] in _ = self?.cancel(jobId) }, finish: { [weak self] in
            guard let self else { return }
            self.lock.lock(); if self.active[jobId] === entry { self.active[jobId] = nil }; self.lock.unlock()
        })
    }
    public func heartbeat(_ jobId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = active[jobId] else { return false }
        entry.lastHeartbeatAt = now(); return true
    }
    @discardableResult public func cancel(_ jobId: String) -> Bool {
        lock.lock(); let entry = active.removeValue(forKey: jobId); lock.unlock()
        guard let entry else { return false }
        entry.cancellation.cancel(); return true
    }
    public func cancelAll() { lock.lock(); let ids = Array(active.keys); lock.unlock(); ids.forEach { cancel($0) } }
    public func sweepExpired() -> Int {
        lock.lock(); let cutoff = now() - leaseTimeoutMs
        let expired = active.filter { $0.value.lastHeartbeatAt <= cutoff }.map(\.key); lock.unlock()
        return expired.filter { cancel($0) }.count
    }
    public func activeCount() -> Int { lock.lock(); defer { lock.unlock() }; return active.count }
    public func dispose() { timer?.cancel(); timer = nil; cancelAll() }
}

// MARK: staging

public struct ExportStagingPaths: Equatable { public let directory: String; public let nativeOutputPath: String; public let encodedOutputPath: String }

public func createExportStagingPaths(_ outputPath: String, _ jobId: String) -> ExportStagingPaths {
    let ext = PosixPath.extname(outputPath).isEmpty ? ".mp4" : PosixPath.extname(outputPath)
    let safeJobId = String(String.UnicodeScalarView(jobId.unicodeScalars.map { s -> Unicode.Scalar in
        (s.isASCII && (CharacterSet.alphanumerics.contains(s) || "._-".unicodeScalars.contains(s))) ? s : "_" }))
    let directory = PosixPath.join(PosixPath.dirname(outputPath), ".studio-render-tmp", safeJobId)
    return ExportStagingPaths(directory: directory, nativeOutputPath: PosixPath.join(directory, "native\(ext)"),
                              encodedOutputPath: PosixPath.join(directory, "encoded\(ext)"))
}

// MARK: native project document

public func readNativeProjectDocumentContent(_ projectDir: String) throws -> String {
    let path = PosixPath.join(projectDir, NATIVE_PROJECT_DOCUMENT_PATH)
    guard FileManager.default.fileExists(atPath: path) else { return "" }
    return try ProjectFS.readUTF8(path)
}

/// The document as the media exporter renders it, after checking that every drawn clip can be exported. Every
/// document is a native timeline; element layers the renderer cannot draw are skipped by the render itself
/// (`NativeProjectDocument.isUndrawnElementClip`), so the document passes through unchanged.
public func mediaTimelineForExport(_ project: NativeProjectDocument) throws -> NativeProjectDocument {
    try assertNativeTimelineSupported(project)
    return project
}
