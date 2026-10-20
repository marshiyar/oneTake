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
// The export API a native export dialog calls: settings (the export panel's format, quality, frame rate,
// resolution presets/custom size, plus a frame range), a pre-flight plan, and a background job with progress,
// cancellation and an atomic finish (staged render, published into place without replacing anything there). Rendering is renderNativeTimeline: the
// preview's painter per frame, encoded by the media engine.
import Foundation
import OneTakeMedia
import MpvfxShared

/// Everything the export panel chooses. Defaults are the panel's first-run settings (MP4, Standard, 30 fps, auto).
public struct ExportSettings: Equatable {
    public var format: ExportFormat
    public var quality: ExportQuality
    public var fps: ExportFrameRate
    /// auto (canvas size), a named preset, custom, or the legacy 1080p/4K scale.
    public var resolution: ExportResolutionChoice
    /// Used when `resolution` is `.custom`; even width/height inside the 8K envelope.
    public var customDimensions: ExportDimensions?
    /// Exports [startFrame, endFrame) of the sequence in project frames; nil exports the whole sequence.
    public var range: ExportFrameRange?
    public init(format: ExportFormat = .mp4, quality: ExportQuality = .standard, fps: ExportFrameRate = .fps30,
                resolution: ExportResolutionChoice = .scale(.auto), customDimensions: ExportDimensions? = nil,
                range: ExportFrameRange? = nil) {
        self.format = format; self.quality = quality; self.fps = fps; self.resolution = resolution
        self.customDimensions = customDimensions; self.range = range
    }
}

/// What an export with these settings will produce, for the dialog to show before starting.
public struct ExportPlan: Equatable {
    public var outputDimensions: ExportDimensions?
    public var durationSeconds: Double
    public var frameCount: Double
    /// Audio stream size at the PCM rate (estimateExportAudioSizeBytes; FLAC is smaller); video size depends on content.
    public var estimatedAudioBytes: Double
    public var fileExtension: String
    /// False for MOV (lossless PNG frames) and refused formats: the dialog hides the quality choice.
    public var qualityApplies: Bool
    /// Every reason the export cannot start; empty means it can.
    public var issues: [String]
    /// Facts about the output that do not stop the export, e.g. layers the renderer skips.
    public var notices: [String] = []
    public var canStart: Bool { issues.isEmpty }
}

/// The output size for a resolution choice (persistedRenderDimensions + resolvePersistedRenderResolution:
/// a legacy 1080p/4K choice follows the canvas aspect).
public func exportOutputDimensions(_ settings: ExportSettings, canvas: NativeCanvas) -> ExportDimensions? {
    let authored = ExportDimensions(width: canvas.width, height: canvas.height)
    var choice = settings.resolution
    if case .scale(let s) = choice, s != .auto {
        let aspect = compositionAspect(authored)
        if s == .p1080 { choice = .preset(aspect == .portrait ? .verticalFullHd : aspect == .square ? .squareFullHd : .fullHd) }
        else { choice = .preset(aspect == .portrait ? .vertical4k : aspect == .square ? .square4k : .uhd4k) }
    }
    guard let d = resolveExportTargetDimensions(choice, authored, settings.customDimensions), isValidExportOutputDimensions(d) else { return nil }
    return ExportDimensions(width: d.width, height: d.height)
}

/// The Renders tab's resolution (CompositionRenderResolution) as export settings for `canvas`: auto renders the
/// composition size; a scaled or custom choice becomes the custom size that keeps the composition's aspect (no
/// size when it falls outside the 8K envelope, which planExport reports).
public func compositionExportResolution(_ choice: CompositionRenderResolution, customWidth: Double,
                                        canvas: NativeCanvas) -> (resolution: ExportResolutionChoice, customDimensions: ExportDimensions?) {
    if choice == .auto { return (.scale(.auto), nil) }
    return (.custom, choice.dimensions(compositionWidth: canvas.width, compositionHeight: canvas.height, customWidth: customWidth))
}

public func planExport(_ project: NativeProjectDocument, settings: ExportSettings) -> ExportPlan {
    var issues: [String] = []
    let capability = exportFormatCapability(settings.format)
    if let refusal = capability.unsupportedMessage { issues.append(refusal) }
    let fps = project.frameRate.numerator / project.frameRate.denominator
    let totalFrames = sequenceEndFrame(project)
    var frames = totalFrames
    if let r = settings.range {
        if !(r.startFrame.isFinite && r.endFrame.isFinite && r.startFrame >= 0 && r.endFrame > r.startFrame && r.endFrame <= totalFrames) {
            issues.append("The export range must lie inside the sequence and end after it starts.")
        } else { frames = r.endFrame - r.startFrame }
    }
    let dims = exportOutputDimensions(settings, canvas: project.canvas)
    if dims == nil {   // the export panel's messages
        issues.append(settings.resolution == .custom
            ? "Custom dimensions must be even whole pixels within the 8K limit (7680 long edge, 4320 short edge)."
            : "Canvas dimensions exceed the 8K export limit (7680 long edge, 4320 short edge).")
    }
    do { try assertNativeTimelineSupported(project) } catch { issues.append("\(error)") }
    let duration = frames / fps
    let hasAudio = exportMayHaveAudio(project)
    return ExportPlan(outputDimensions: dims, durationSeconds: duration, frameCount: exportFrameCount(duration, settings.fps),
                      estimatedAudioBytes: estimateExportAudioSizeBytes(duration, settings.format, hasAudio),
                      fileExtension: capability.extension, qualityApplies: capability.video.qualityApplies, issues: issues,
                      notices: project.undrawnElementLayersNotice.map { [$0] } ?? [])
}

public enum ExportStatus: Equatable, Sendable { case rendering, completed, cancelled, failed }

public struct ExportProgress: Equatable, Sendable {
    /// 0...100.
    public var percent: Double
    public var stage: String
}

public enum ExportOutcome: Equatable, Sendable {
    case completed(path: String, sizeBytes: Double, elapsedSeconds: Double)
    case cancelled
    case failed(message: String)
}

/// A running export. Thread-safe; callbacks arrive on a background thread.
public final class ExportJob: @unchecked Sendable {
    public let outputPath: String
    public let settings: ExportSettings
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private let cancellation = MediaCancellation()
    private var currentProgress = ExportProgress(percent: 0, stage: "Preparing")
    private var finalOutcome: ExportOutcome?

    init(outputPath: String, settings: ExportSettings) { self.outputPath = outputPath; self.settings = settings }

    public var progress: ExportProgress { lock.lock(); defer { lock.unlock() }; return currentProgress }
    public var outcome: ExportOutcome? { lock.lock(); defer { lock.unlock() }; return finalOutcome }
    public var status: ExportStatus {
        switch outcome {
        case nil: return .rendering
        case .completed?: return .completed
        case .cancelled?: return .cancelled
        case .failed?: return .failed
        }
    }
    /// Stops the render at the next frame and removes every partial file. Safe to call at any time.
    public func cancel() { cancellation.cancel() }
    public var isCancelled: Bool { cancellation.isCancelled }
    /// Blocks until the job finishes (nil on timeout).
    @discardableResult public func wait(timeout: Double? = nil) -> ExportOutcome? {
        let ok = timeout.map { done.wait(timeout: .now() + $0) == .success } ?? { done.wait(); return true }()
        if ok { done.signal() }
        return ok ? outcome : nil
    }

    fileprivate var mediaCancellation: MediaCancellation { cancellation }
    fileprivate func report(_ p: ExportProgress) -> ExportProgress {
        lock.lock(); defer { lock.unlock() }
        // Never move backwards (the audio mix and the encode report separately).
        if p.percent >= currentProgress.percent || p.stage != currentProgress.stage { currentProgress = ExportProgress(percent: Swift.max(p.percent, currentProgress.percent), stage: p.stage) }
        return currentProgress
    }
    fileprivate func finish(_ o: ExportOutcome) { lock.lock(); finalOutcome = o; lock.unlock(); done.signal() }
}

public struct ExportStartError: Error, Equatable, CustomStringConvertible {
    public let issues: [String]
    public var description: String { issues.joined(separator: " ") }
}

/// Starts exporting `project` (media resolved against `projectDir`) to `outputPath` on a background thread.
/// Throws ExportStartError before starting when the plan has issues, the output exists, its extension does not
/// match the format, or no frame renderer is installed. A file created at `outputPath` while the export renders is
/// never replaced: the export then fails with ExportOutputExistsError's message and leaves that file alone. `progress` and `completion` are called on a background thread.
@discardableResult
public func startExport(project: NativeProjectDocument, projectDir: String, outputPath: String, settings: ExportSettings,
                        keyframeEngine: KeyframeEngine? = nil,
                        progress: @escaping (ExportProgress) -> Void = { _ in },
                        completion: @escaping (ExportOutcome) -> Void = { _ in }) throws -> ExportJob {
    let plan = planExport(project, settings: settings)
    var issues = plan.issues
    let ext = PosixPath.extname(outputPath).lowercased()
    if ext != plan.fileExtension { issues.append("The output file must end in \(plan.fileExtension) for \(exportFormatCapability(settings.format).name).") }
    if FileManager.default.fileExists(atPath: outputPath) { issues.append("The output file already exists.") }
    if NativeExportFrames.defaultRenderer == nil { issues.append(EXPORT_NO_FRAME_RENDERER_MESSAGE) }
    guard issues.isEmpty, let dims = plan.outputDimensions else { throw ExportStartError(issues: issues) }

    let job = ExportJob(outputPath: outputPath, settings: settings)
    let staging = createExportStagingPaths(outputPath, "export-\(UUID().uuidString.lowercased())")
    let started = Date()
    // The render-history record beside the output, which the Renders tab reads on reopen.
    let metaPath = exportMetaPath(outputPath)
    Thread.detachNewThread {
        func cleanUp() {
            try? FileManager.default.removeItem(atPath: staging.directory)
            #if os(Windows)
            _ = Foundation._rmdir(PosixPath.dirname(staging.directory))  // only when no other export is staging there
            #else
            _ = Foundation.rmdir(PosixPath.dirname(staging.directory))   // only when no other export is staging there
            #endif
        }
        let cancellation = job.mediaCancellation
        do {
            try FileManager.default.createDirectory(atPath: staging.directory, withIntermediateDirectories: true)
            progress(job.report(.init(percent: 0, stage: "Rendering")))
            // The mix decodes its stems before the first frame: the first 10 % when the export has sound.
            let mixesAudio = exportMayHaveAudio(project)
            let input = NativeTimelineRenderInput(project: project, projectDir: projectDir, outputPath: staging.encodedOutputPath,
                format: settings.format, outputDimensions: dims, outputFps: settings.fps.rawValue, quality: settings.quality,
                cancellation: cancellation,
                onProgress: { p in progress(job.report(.init(percent: p, stage: p < 10 && mixesAudio ? "Mixing audio" : "Rendering"))) },
                keyframeEngine: keyframeEngine, range: settings.range)
            try renderNativeTimeline(input)
            try cancellation.throwIfCancelled()
            try publishExport(staging.encodedOutputPath, to: outputPath)   // never replaces a file created meanwhile
            let size = ((try? FileManager.default.attributesOfItem(atPath: outputPath))?[.size] as? NSNumber)?.doubleValue ?? 0
            let elapsed = Date().timeIntervalSince(started)
            let outcome = ExportOutcome.completed(path: outputPath, sizeBytes: size, elapsedSeconds: elapsed)
            // The one write of the history record (RenderRun does not write it again).
            try? Data(#"{"status":"complete","durationMs":\#(Int(elapsed * 1000))}"#.utf8).write(to: URL(fileURLWithPath: metaPath), options: .atomic)
            cleanUp()
            progress(job.report(.init(percent: 100, stage: "Complete")))
            job.finish(outcome); completion(outcome)
        } catch {
            let outcome: ExportOutcome = cancellation.isCancelled ? .cancelled : .failed(message: exportErrorMessage(error))
            // A cancel is not a failure and leaves no history record. Nothing at outputPath or metaPath is removed:
            // the export publishes there only after its last cancellation check, so a file there now is someone
            // else's (issue #24; it used to be deleted).
            if !cancellation.isCancelled && !(error is ExportOutputExistsError) {
                // No record beside a file that is not ours: it would describe someone else's file.
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                try? Data(#"{"status":"failed","durationMs":\#(ms)}"#.utf8).write(to: URL(fileURLWithPath: metaPath), options: .atomic)
            }
            cleanUp()
            job.finish(outcome); completion(outcome)
        }
    }
    return job
}

/// An unmuted audio or video clip: the export may carry sound (whether it does depends on the media's tracks).
func exportMayHaveAudio(_ project: NativeProjectDocument) -> Bool {
    project.sequence.tracks.contains { $0.clips.contains { clip in
        !clip.muted && project.assets.first(where: { $0.id == clip.assetId }).map { $0.kind == .audio || $0.kind == .video } == true } }
}

/// Why an export cannot start in a process that never installed the preview's painter (NativeExportFrames).
public let EXPORT_NO_FRAME_RENDERER_MESSAGE = "Export cannot draw frames: no frame renderer is installed."

/// `<output>.meta.json` for an .mp4/.webm/.mov output.
public func exportMetaPath(_ outputPath: String) -> String {
    outputPath.replacingOccurrences(of: "\\.(mp4|webm|mov)$", with: ".meta.json", options: .regularExpression)
}

func exportErrorMessage(_ error: Error) -> String {
    switch error {
    case let e as MediaToolError: return e.message
    case let e as ExportOutputExistsError: return e.message
    case let e as UnsupportedNativeMediaError: return e.message
    case let e as ExportFailedError: return e.message
    case let e as MediaError: return e.message
    default: return String(describing: error)
    }
}
