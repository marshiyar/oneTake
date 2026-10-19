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
import MpvfxColor
import MpvfxShared

/// Grades preview frames off the main thread, latest request wins.
///
/// Each clip has one slot: the picture it last finished (shown at once on every draw), the request that should
/// replace it, and whether a grade is running. A draw asks for the look it wants and immediately gets the latest
/// finished picture; when a request is already waiting it is replaced, so a slider drag grades only the newest value
/// (intermediate values are dropped, never queued). When a grade finishes, `onFinished` fires (the compositor's
/// `frameReady`, which redraws on the UI thread), so the newest look is on screen one grade after the last change.
///
/// Pictures are graded at the size they are displayed: a source frame larger than its screen footprint is first
/// reduced (area average, on all cores) and the reduced picture is kept for the next parameter change. The renderer
/// is told which source picture it is grading (`sourceKey`), so the Metal path keeps it on the GPU and re-runs only
/// the kernels while a slider moves.
///
/// On the CPU renderer (Linux) a change to a picture larger than `draftSize` is first graded as a draft at that size
/// and shown at once (carrying the new grade, marked not current); the full display-size grade follows unless a newer
/// change arrived meanwhile, in which case only the newest value is graded. A slider drag therefore tracks the pointer
/// at draft cost and settles on the exact full-size look. A new picture (playback, a seek) after a finished one is
/// graded at full size straight away: a draft there would only double the work per frame.
///
/// Memory: the pictures every slot holds (finished look, reduced source, draft) stay within `budgetBytes`
/// (`MemoryBudget.gradedFrames`); past it the idle slots asked for least recently are dropped (never the one just
/// graded, never one with a grade running or waiting). A memory-pressure warning drops every idle slot but the most
/// recent; critical drops every idle slot. Slots of clips that left the timeline go with `keepOnly`.
public final class PreviewGrader: @unchecked Sendable {
    public struct Request {
        /// Everything the graded pixels depend on (source picture, target size, grade signature, time).
        public var key: String
        /// The source picture at its graded size (lane, frame, decoded size, target size).
        public var sourceKey: String
        public var image: CanvasImage
        public var target: PreviewDecodeSize?
        public var grade: ColorGradeRenderer
        public var time: Double
    }
    public struct Result {
        public var key: String
        public var image: CanvasImage
        /// The grade signature the pixels carry.
        public var signature: String
        /// Seconds the grade took (reduce + render).
        public var seconds: Double
        /// The source picture graded (the request's `sourceKey`).
        public var sourceKey = ""
    }

    final class Slot {
        var result: Result?
        var pending: Request?
        var runningKey: String?
        var reduced: (key: String, image: CanvasImage)?
        var draft: (key: String, image: CanvasImage)?
        /// When the slot was last asked for a picture (eviction order).
        var used: UInt64 = 0
        var bytes: Int {
            (result?.image.rgba.count ?? 0) + (reduced?.image.rgba.count ?? 0) + (draft?.image.rgba.count ?? 0)
        }
        var busy: Bool { runningKey != nil || pending != nil }
    }

    /// The CPU draft size (a 1080p picture is drafted at a quarter of its pixels).
    public var draftSize = PreviewDecodeSize(width: 960, height: 540)

    public var renderer: ColorRenderer
    /// Called on the grading queue when a newer picture is ready.
    public var onFinished: (() -> Void)?
    let queue = DispatchQueue(label: "mpvfx.preview-grade", qos: .userInteractive)
    let lock = NSLock()
    var slots: [String: Slot] = [:]
    public private(set) var finished = 0, dropped = 0
    /// CPU drafts shown ahead of a full grade (diagnostics, tests).
    public private(set) var drafts = 0
    /// Seconds spent reducing and grading, summed over every grade (diagnostics, the preview benchmark).
    public private(set) var busySeconds = 0.0

    /// Bytes all slots' pictures may hold together.
    public var budgetBytes = MemoryBudget.gradedFrames()
    var tick: UInt64 = 0
    var pressureToken: MemoryPressureMonitor.Token?

    public init(renderer: ColorRenderer = ColorRendering.shared, pressure: MemoryPressureMonitor? = .shared) {
        self.renderer = renderer
        pressureToken = pressure?.observe { [weak self] level in self?.purge(level) }
    }

    /// Bytes of pictures held across slots.
    public var bytes: Int { lock.lock(); defer { lock.unlock() }; return slots.values.reduce(0) { $0 + $1.bytes } }

    /// Drops the slots of clips not in `clips` (removed from the timeline, project closed).
    public func keepOnly(_ clips: Set<String>) {
        lock.lock(); slots = slots.filter { clips.contains($0.key) }; lock.unlock()
    }

    /// Memory pressure: a warning keeps only the most recently used idle slot, critical keeps no idle slot.
    public func purge(_ level: MemoryPressureMonitor.Level) {
        lock.lock(); defer { lock.unlock() }
        let newest = level == .warning ? slots.filter { !$0.value.busy }.max { $0.value.used < $1.value.used }?.key : nil
        slots = slots.filter { $0.value.busy || $0.key == newest }
    }

    /// Drops least recently used idle slots (not `keep`) until the pictures fit the budget. Call with `lock` held.
    func trimLocked(keep: String) {
        var total = slots.values.reduce(0) { $0 + $1.bytes }
        guard total > budgetBytes else { return }
        for (clip, slot) in slots.sorted(by: { $0.value.used < $1.value.used }) where clip != keep && !slot.busy {
            if total <= budgetBytes { break }
            total -= slot.bytes
            slots[clip] = nil
        }
    }

    /// The latest finished picture for `clip`, if any.
    public func latest(_ clip: String) -> Result? { lock.lock(); defer { lock.unlock() }; return slots[clip]?.result }

    /// Asks for `request` on `clip` (no-op when it is already finished, running or waiting). Never blocks.
    public func request(_ clip: String, _ request: Request) {
        lock.lock()
        let slot = slots[clip] ?? Slot()
        slots[clip] = slot
        tick += 1; slot.used = tick
        if slot.result?.key == request.key || slot.runningKey == request.key || slot.pending?.key == request.key { lock.unlock(); return }
        if slot.pending != nil { dropped += 1 }
        slot.pending = request
        let start = slot.runningKey == nil
        if start { slot.runningKey = request.key }
        lock.unlock()
        if start { queue.async { self.run(clip) } }
    }

    func run(_ clip: String) {
        // One autorelease pool per grade: this loop runs as long as edits keep coming (a slider drag).
        while withAutoreleasePool({ step(clip) }) {}
    }

    /// Grades the slot's waiting request; false when there was none.
    func step(_ clip: String) -> Bool {
        do {
            lock.lock()
            guard let slot = slots[clip], let r = slot.pending else { slots[clip]?.runningKey = nil; lock.unlock(); return false }
            slot.pending = nil
            slot.runningKey = r.key
            let reduced = slot.reduced
            lock.unlock()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let source: CanvasImage
            if let t = r.target, r.image.width > t.width || r.image.height > t.height {
                if let m = reduced, m.key == r.sourceKey { source = m.image } else {
                    source = r.image.reduced(width: t.width, height: t.height)
                    lock.lock(); slot.reduced = (r.sourceKey, source); lock.unlock()
                }
            } else { source = r.image }
            lock.lock(); let newPicture = slot.result.map { $0.sourceKey != r.sourceKey } ?? false; lock.unlock()
            if renderer.backend == "cpu", !newPicture, source.width > draftSize.width || source.height > draftSize.height {
                // Draft first: the new look at reduced size, then the exact one unless a newer change is waiting.
                let fit = draftSize.containing(aspect: Double(source.width) / Double(source.height))
                let dw = min(fit.width, source.width), dh = min(fit.height, source.height)
                let small: CanvasImage
                if let m = slot.draft, m.key == r.sourceKey { small = m.image } else {
                    small = source.reduced(width: dw, height: dh)
                    lock.lock(); slot.draft = (r.sourceKey, small); lock.unlock()
                }
                var dpx = small.rgba
                r.grade.render(&dpx, width: small.width, height: small.height, time: r.time, sourceKey: r.sourceKey + "|draft", using: renderer)
                let d = Result(key: r.key + "|draft", image: CanvasImage(width: small.width, height: small.height, rgba: dpx),
                               signature: r.grade.signature, seconds: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9,
                               sourceKey: r.sourceKey)
                lock.lock(); slot.result = d; drafts += 1; let newer = slot.pending != nil; lock.unlock()
                onFinished?()
                if newer { lock.lock(); busySeconds += d.seconds; lock.unlock(); return true }
            }
            var px = source.rgba
            r.grade.render(&px, width: source.width, height: source.height, time: r.time, sourceKey: r.sourceKey, using: renderer)
            let out = Result(key: r.key, image: CanvasImage(width: source.width, height: source.height, rgba: px), signature: r.grade.signature,
                             seconds: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, sourceKey: r.sourceKey)
            lock.lock(); slot.result = out; finished += 1; busySeconds += out.seconds; trimLocked(keep: clip); lock.unlock()
            onFinished?()
            return true
        }
    }

    /// Grades `image` now on the calling thread at its own size (stills, thumbnails, tests).
    public func gradeNow(_ image: CanvasImage, grade: ColorGradeRenderer, time: Double) -> CanvasImage {
        var px = image.rgba
        grade.render(&px, width: image.width, height: image.height, time: time, using: renderer)
        return CanvasImage(width: image.width, height: image.height, rgba: px)
    }

    /// Blocks until queued grades have finished (tests).
    public func waitUntilIdle() { queue.sync {} }

    public func removeAll() { lock.lock(); slots = [:]; lock.unlock() }
}

extension CanvasImage {
    /// The picture reduced to `width` x `height` by area averaging (alpha-weighted, so transparent padding does not
    /// darken edges), rows spread over the cores.
    func reduced(width w: Int, height h: Int) -> CanvasImage {
        let sw = self.width, sh = self.height
        guard w > 0, h > 0, w < sw || h < sh else { return self }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let fx = Double(sw) / Double(w), fy = Double(sh) / Double(h)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let y0 = Double(y) * fy, y1 = y0 + fy
                    let iy0 = Int(y0), iy1 = min(sh, Int(y1.rounded(.up)))
                    for x in 0..<w {
                        let x0 = Double(x) * fx, x1 = x0 + fx
                        let ix0 = Int(x0), ix1 = min(sw, Int(x1.rounded(.up)))
                        var r = 0.0, g = 0.0, b = 0.0, a = 0.0, area = 0.0
                        for sy in iy0..<iy1 {
                            let wy = min(Double(sy + 1), y1) - max(Double(sy), y0)
                            var i = (sy * sw + ix0) * 4
                            for sx in ix0..<ix1 {
                                let wgt = wy * (min(Double(sx + 1), x1) - max(Double(sx), x0))
                                let al = Double(src[i + 3]) * wgt
                                r += Double(src[i]) * al; g += Double(src[i + 1]) * al; b += Double(src[i + 2]) * al
                                a += al; area += wgt
                                i += 4
                            }
                        }
                        let o = (y * w + x) * 4
                        if a > 0 {
                            base[o] = UInt8(min(255, (r / a).rounded())); base[o + 1] = UInt8(min(255, (g / a).rounded()))
                            base[o + 2] = UInt8(min(255, (b / a).rounded()))
                        }
                        base[o + 3] = UInt8(min(255, (a / max(area, 1e-9)).rounded()))
                    }
                }
            }
        }
        return CanvasImage(width: w, height: h, rgba: out)
    }
}
