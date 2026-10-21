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
import MpvfxCanvas
import MpvfxScopes
import MpvfxTheme

/// One frame analysed for the shown scopes: the counts, a trace bitmap per scope and the false-colour picture.
public struct ScopeResult: @unchecked Sendable {
    public let analysis: ScopeAnalysis
    public let traces: [ScopeKind: CanvasImage]
    public let settings: ScopeSettings
}

/// Analyses scope frames on one serial background queue, so a scope update never blocks a draw. Only the newest
/// request is kept: it replaces a request that has not started, and a request equal to the running one is not
/// queued again. A draw shows the last finished result until the newer one is ready; `onReady` (called on the
/// background queue) asks the host to redraw.
public final class ScopeWorker: @unchecked Sendable {
    struct Key: Equatable { var frame: String; var settings: ScopeSettings }

    public var onReady: (() -> Void)?

    let queue = DispatchQueue(label: "mpvfx.scopes", qos: .userInitiated)
    let lock = NSLock()
    var pending: (key: Key, frame: CanvasImage)?
    var running: Key?
    var scheduled = false
    var finished: (key: Key, result: ScopeResult)?
    /// Bumped by `reset`; a job started under an older generation is not published.
    var generation = 0
    var completed = 0
    var failure: ScopeError?

    public init() {}

    /// Frames analysed so far (tests, diagnostics).
    public var analysed: Int { lock.lock(); defer { lock.unlock() }; return completed }

    /// Why the newest frame could not be analysed (the row shows it), nil after a frame that could.
    public var lastFailure: ScopeError? { lock.lock(); defer { lock.unlock() }; return failure }

    /// The result for `frame` with `settings` when it is finished; else the analysis is queued (latest wins) and
    /// the last finished result, if any, is returned so the scopes do not blank while it runs. UI thread; never waits.
    public func result(for frame: CanvasImage, settings: ScopeSettings) -> (result: ScopeResult?, current: Bool) {
        let key = Key(frame: Self.fingerprint(frame), settings: settings)
        lock.lock(); defer { lock.unlock() }
        if let done = finished, done.key == key { return (done.result, true) }
        if running != key { pending = (key, frame) }
        if !scheduled {
            scheduled = true
            queue.async { [weak self] in self?.drain() }
        }
        return (finished?.result, false)
    }

    /// Drops the finished result, any queued request and the job in flight (refresh, closing the scopes).
    public func reset() {
        lock.lock(); finished = nil; pending = nil; running = nil; failure = nil; generation &+= 1; lock.unlock()
    }

    /// Blocks until queued work has run (tests).
    public func wait() { queue.sync {} }

    func drain() {
        while true {
            lock.lock()
            guard let job = pending else { scheduled = false; running = nil; lock.unlock(); return }
            pending = nil; running = job.key
            let started = generation
            lock.unlock()
            let outcome = Result { try Self.analyse(job.frame, settings: job.key.settings) }
            lock.lock()
            let current = started == generation
            if current {
                switch outcome {
                case .success(let result): finished = (job.key, result); completed += 1; failure = nil
                case .failure(let error): failure = error as? ScopeError
                }
            }
            running = nil
            lock.unlock()
            if current { onReady?() }
        }
    }

    /// The analysis and the bitmaps of the shown scopes; throws `ScopeError` when the frame is not a valid picture.
    static func analyse(_ frame: CanvasImage, settings: ScopeSettings) throws -> ScopeResult {
        let scopeFrame = try ScopeFrame(width: frame.width, height: frame.height, rgba: frame.rgba)
        let a = ScopeEngine.analyze(scopeFrame, options: settings.options)
        var traces: [ScopeKind: CanvasImage] = [:]
        for kind in settings.kinds { traces[kind] = trace(kind, a, scopeFrame, settings: settings) }
        return ScopeResult(analysis: a, traces: traces, settings: settings)
    }

    static func trace(_ kind: ScopeKind, _ a: ScopeAnalysis, _ frame: ScopeFrame, settings: ScopeSettings) -> CanvasImage? {
        let T = ThemeTokens.self, gain = settings.gain
        switch kind {
        case .waveform: return ScopeTraces.waveform(a, planes: [(.luma, T.scopeLuma)], gain: gain)
        case .overlay: return ScopeTraces.waveform(a, planes: [(.red, T.scopeRed), (.green, T.scopeGreen), (.blue, T.scopeBlue)], gain: gain)
        case .parade: return ScopeTraces.parade(a, colours: [T.scopeRed, T.scopeGreen, T.scopeBlue], gain: gain)
        case .vectorscope: return ScopeTraces.vectorscope(a, colour: T.scopeVector, gain: gain)
        case .falseColor: return CanvasImage(width: frame.width, height: frame.height, rgba: FalseColor.map(frame, matrix: settings.matrix))
        case .histogram: return nil   // drawn as curves over the counts
        }
    }

    /// Size plus an FNV-1a hash of about 4096 bytes spread over the frame: equal frames share it.
    static func fingerprint(_ f: CanvasImage) -> String {
        var h: UInt64 = 1469598103934665603
        let step = max(1, f.rgba.count / 4096)
        for i in stride(from: 0, to: f.rgba.count, by: step) { h = (h ^ UInt64(f.rgba[i])) &* 1099511628211 }
        return "\(f.width)x\(f.height):\(h)"
    }
}
