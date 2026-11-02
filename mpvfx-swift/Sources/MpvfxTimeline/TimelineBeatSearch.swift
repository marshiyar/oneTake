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

/// Find beats for one audio clip off the main thread (#290). The analysis itself is a closure the host supplies (it
/// decodes the clip's audio and runs `BeatAnalysis`), so the timeline does not depend on the audio code. Nothing in the
/// document changes until the analysis finishes: the result is applied on the main thread, only if the job was not
/// cancelled and the clip still reads the same slice of the same file, and replaces the clip's analysed marks only
/// (`TimelineEditor.replaceAnalysisBeats`).
public final class TimelineBeatSearch {
    public struct Options: Equatable, Sendable {
        /// 0...1, higher finds more onsets.
        public var sensitivity = 0.5
        /// Keep every 1st, 2nd or 4th beat.
        public var every = 1
        public init(sensitivity: Double = 0.5, every: Int = 1) { self.sensitivity = sensitivity; self.every = every }
    }

    public enum Outcome: Equatable, Sendable {
        /// The marks were stored; the count is how many the analysis found.
        case applied(marks: Int)
        case cancelled
        /// The clip was trimmed, replaced or removed while the analysis ran, so its result was dropped.
        case clipChanged
        case failed(String)
    }

    /// The analysis: marks as seconds from the start of the media with a 0...1 strength, or nil when it noticed
    /// `isCancelled` and stopped. It runs on a background queue and reports 0...1 progress through `progress`.
    public typealias Analysis = (_ source: TimelineBeatAnalysisSource, _ options: Options, _ isCancelled: () -> Bool,
                                 _ progress: (Double) -> Void) throws -> [(seconds: Double, strength: Double)]?

    /// One running search; its flag is read from the analysis thread.
    private final class Job {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    private let editor: TimelineEditor
    private let analysis: Analysis
    private let queue: DispatchQueue
    private let deliver: (@escaping () -> Void) -> Void
    private var job: Job?
    /// True from `start` until the outcome is reported. Read and written on the delivery (main) thread.
    public private(set) var isRunning = false
    public private(set) var progress = 0.0
    /// The clip being searched, while `isRunning`.
    public private(set) var clipId: String?
    /// Reported on the delivery thread as the analysis advances.
    public var onProgress: ((Double) -> Void)?
    /// Reported once per search, on the delivery thread.
    public var onFinish: ((Outcome) -> Void)?

    /// `deliver` runs a block on the thread that owns the editor (the main queue by default).
    public init(editor: TimelineEditor, analysis: @escaping Analysis,
                queue: DispatchQueue = DispatchQueue(label: "onetake.beat-search", qos: .userInitiated),
                deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.editor = editor; self.analysis = analysis; self.queue = queue; self.deliver = deliver
    }

    /// Starts searching `clipId`. False, with nothing started, when a search is already running or the clip cannot hold
    /// beats (not audio, locked, no media file).
    @discardableResult
    public func start(clipId: String, options: Options = Options()) -> Bool {
        guard !isRunning, let source = editor.beatAnalysisSource(clipId: clipId),
            options.sensitivity.isFinite, (0...1).contains(options.sensitivity),
            NativeBeatChoices.every.contains(options.every)
        else {
            return false
        }
        let job = Job()
        self.job = job; isRunning = true; progress = 0; self.clipId = clipId
        let analysis = self.analysis, deliver = self.deliver
        queue.async { [weak self] in
            let outcome: Result<[(seconds: Double, strength: Double)]?, Error>
            do {
                let marks = try analysis(source, options, { job.isCancelled }, { fraction in
                    deliver { [weak self] in
                        guard let self, self.job === job, !job.isCancelled else { return }
                        self.progress = fraction; self.onProgress?(fraction)
                    }
                })
                outcome = .success(marks)
            } catch {
                outcome = .failure(error)
            }
            deliver { self?.finish(job, source: source, options: options, outcome) }
        }
        return true
    }

    /// Stops the running search; its result is discarded and the document is untouched.
    public func cancel() { job?.cancel() }

    private func finish(_ job: Job, source: TimelineBeatAnalysisSource, options: Options,
                        _ result: Result<[(seconds: Double, strength: Double)]?, Error>) {
        guard self.job === job else {
            return
        }
        self.job = nil; isRunning = false; clipId = nil
        let outcome: Outcome
        switch result {
        case .failure(let error):
            outcome = job.isCancelled ? .cancelled : .failed("\(error)")
        case .success(let marks):
            if job.isCancelled || marks == nil {
                outcome = .cancelled
            } else if editor.beatAnalysisSource(clipId: source.clipId) != source {
                outcome = .clipChanged
            } else if let marks, editor.replaceAnalysisBeats(clipId: source.clipId, marks: marks, sensitivity: options.sensitivity, every: options.every) {
                outcome = .applied(marks: marks.count)
            } else {
                outcome = .failed(editor.lastFailure?.message ?? "No beats were changed")
            }
        }
        if case .applied = outcome { progress = 1 }
        onFinish?(outcome)
    }
}

/// The values the beat options accept.
enum NativeBeatChoices {
    static let every = [1, 2, 4]
}
