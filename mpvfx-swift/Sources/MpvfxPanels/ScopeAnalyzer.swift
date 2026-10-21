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

/// Turns scope frames into scope bitmaps (`ColorScopes.analyze` then `ColorScopes.render`) on one serial background
/// queue, so a scope update never blocks a draw. Only the newest request is kept: a request replaces one that has not
/// started, and a request equal to the one being analysed is not queued again.
///
/// A request is identified by the mode and a fingerprint of the frame (`fingerprint`), so redrawing the same frame
/// costs one lookup; `onReady` (called on the background queue) asks the host to redraw once the bitmap is done.
public final class ScopeAnalyzer: @unchecked Sendable {
    struct Key: Equatable { var mode: ColorScopes.Mode; var frame: String }

    /// Called on the background queue after a bitmap is finished; hosts hop to the UI thread and redraw.
    public var onReady: (() -> Void)?

    let queue = DispatchQueue(label: "mpvfx.scopes", qos: .userInitiated)
    let lock = NSLock()
    var pending: (key: Key, frame: CanvasImage)?
    var running: Key?
    var scheduled = false
    var finished: (key: Key, image: CanvasImage)?
    var analysedCount = 0

    public init() {}

    /// Frames analysed so far (tests, diagnostics).
    public var analysed: Int { lock.lock(); defer { lock.unlock() }; return analysedCount }

    /// The bitmap of `frame` in `mode` when it is finished; else nil, and the analysis is queued (latest wins).
    /// Call on the UI thread; never waits for the analysis.
    public func bitmap(_ mode: ColorScopes.Mode, of frame: CanvasImage) -> CanvasImage? {
        let key = Key(mode: mode, frame: Self.fingerprint(frame))
        lock.lock(); defer { lock.unlock() }
        if let done = finished, done.key == key { return done.image }
        if running != key { pending = (key, frame) }
        if !scheduled {
            scheduled = true
            queue.async { [weak self] in self?.drain() }
        }
        return nil
    }

    /// The last finished bitmap when it is of `mode` (shown while a newer frame is analysed).
    public func last(_ mode: ColorScopes.Mode) -> CanvasImage? {
        lock.lock(); defer { lock.unlock() }
        return finished?.key.mode == mode ? finished?.image : nil
    }

    /// Forgets the finished bitmap and any queued request (the refresh button, closing the scopes).
    public func reset() { lock.lock(); finished = nil; pending = nil; lock.unlock() }

    /// Blocks until queued analyses have run (tests).
    public func wait() { queue.sync {} }

    func drain() {
        while true {
            lock.lock()
            guard let job = pending else { scheduled = false; running = nil; lock.unlock(); return }
            pending = nil; running = job.key
            lock.unlock()
            let image = ColorScopes.render(job.key.mode, ColorScopes.analyze(job.frame))
            lock.lock()
            finished = (job.key, image); analysedCount += 1; running = nil
            lock.unlock()
            onReady?()
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
