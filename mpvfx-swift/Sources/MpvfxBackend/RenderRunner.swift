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
import MpvfxRuntime
import MpvfxShared

/// One Renders-tab export end to end: the output path in the project's renders
/// folder, the export source (a library snapshot for library projects), the export with progress and cancel,
/// library tracking, and the outcome in the render history (written by startExport) before `completion` runs.
/// The caller saves the project first; every callback arrives on a background thread.
public final class RenderRun: @unchecked Sendable {
    public let id: String
    public let outputPath: String
    private let lock = NSLock()
    private var exportJob: ExportJob?
    private var cancelled = false

    init(id: String, outputPath: String) { self.id = id; self.outputPath = outputPath }

    public var job: ExportJob? { lock.lock(); defer { lock.unlock() }; return exportJob }

    /// Stops the export (also before it has started; it then finishes as cancelled).
    public func cancel() {
        lock.lock(); cancelled = true; let j = exportJob; lock.unlock()
        j?.cancel()
    }

    fileprivate func attach(_ j: ExportJob) -> Bool {
        lock.lock(); exportJob = j; let c = cancelled; lock.unlock()
        if c { j.cancel() }
        return !c
    }
    fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Starts the render. Throws before anything starts when the output path cannot be made or the plan has issues
    /// (an unsupported format such as WebM, or no frame renderer installed: the app installs the preview's painter).
    public static func start(backend: DesktopBackend, _ request: RenderRequest, _ callbacks: RenderCallbacks) throws -> RenderRun {
        let plan = planExport(request.document, settings: request.settings)
        guard plan.canStart else { throw DesktopError(plan.issues.joined(separator: " ")) }
        guard NativeExportFrames.defaultRenderer != nil else { throw DesktopError("Can't export: \(EXPORT_NO_FRAME_RENDERER_MESSAGE)") }
        let outputPath = try backend.renderOutputPath(projectId: request.projectId, jobId: request.jobId, format: request.settings.format.rawValue)
        let run = RenderRun(id: request.jobId, outputPath: outputPath)
        let requestBox = UncheckedBox(request)
        Task {
            let source: DesktopExportSource
            do { source = try await backend.beginExport(projectId: requestBox.value.projectId, settings: requestBox.value.settingsJSON) }
            catch { callbacks.completion(.failed(message: "Couldn't prepare the export: \((error as? DesktopError)?.message ?? "\(error)")"), 0); return }
            if run.isCancelled {
                try? await backend.abandonExport(source, error: "Cancelled")
                callbacks.completion(.cancelled, 0); return
            }
            do {
                try run.export(backend: backend, requestBox.value, from: source, callbacks)
            } catch {
                let message = (error as? ExportStartError)?.description ?? "\(error)"
                try? await backend.abandonExport(source, error: message)
                callbacks.completion(.failed(message: message), 0)
            }
        }
        return run
    }

    /// Runs the export from the prepared `source`, records the outcome in the render history and tracks the job.
    private func export(backend: DesktopBackend, _ request: RenderRequest, from source: DesktopExportSource,
                        _ callbacks: RenderCallbacks) throws {
        let t0 = Date()
        // startExport writes the render-history record (`<jobId>.meta.json`) itself; it is not written again here.
        let job = try startExport(project: request.document, projectDir: source.directory, outputPath: outputPath,
                                  settings: request.settings, keyframeEngine: request.keyframeEngine,
                                  progress: callbacks.progress,
                                  completion: { outcome in callbacks.completion(outcome, Date().timeIntervalSince(t0) * 1000) })
        _ = attach(job)
        callbacks.started(self)
        backend.trackExport(source) {
            switch job.outcome {
            case nil: return DesktopExportStatus(status: "rendering")
            case .completed(let path, _, _)?: return DesktopExportStatus(status: "complete", outputPath: path)
            case .cancelled?: return DesktopExportStatus(status: "cancelled")
            case .failed(let message)?: return DesktopExportStatus(status: "failed", error: message)
            }
        }
    }
}

/// What one Renders-tab export renders: the project, its saved document, the export settings (typed, and as the
/// panel's JSON for the export source), the job id naming the output, and the keyframe engine to evaluate with.
public struct RenderRequest {
    public var projectId: String
    public var document: NativeProjectDocument
    public var settings: ExportSettings
    public var settingsJSON: JSONValue
    public var jobId = "render-" + UUID().uuidString.lowercased()
    public var keyframeEngine: KeyframeEngine?
    public init(projectId: String, document: NativeProjectDocument, settings: ExportSettings, settingsJSON: JSONValue) {
        self.projectId = projectId; self.document = document; self.settings = settings; self.settingsJSON = settingsJSON
    }
}

/// What the Renders tab hears about a run, each on a background thread: it started, its progress, and how it ended
/// (with the elapsed milliseconds).
public struct RenderCallbacks: Sendable {
    public var started: @Sendable (RenderRun) -> Void = { _ in }
    public var progress: @Sendable (ExportProgress) -> Void = { _ in }
    public var completion: @Sendable (ExportOutcome, _ durationMs: Double) -> Void
    public init(completion: @escaping @Sendable (ExportOutcome, _ durationMs: Double) -> Void) { self.completion = completion }
}

/// Carries a non-Sendable reference into the export task (used read-only there).
private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
