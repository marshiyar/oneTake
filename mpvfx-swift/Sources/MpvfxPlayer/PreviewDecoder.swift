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
import MpvfxShared
import OneTakeMedia

/// Decode target in device pixels, even-sized.
public struct PreviewDecodeSize: Equatable, Sendable {
    public var width: Int, height: Int
    public init(width: Int, height: Int) { self.width = max(2, width & ~1); self.height = max(2, height & ~1) }

    /// Even-sized target for `pixels` on screen, at most `maxSide` on its longer side.
    public static func fitting(_ pixels: (width: Double, height: Double), maxSide: Int = 3840) -> PreviewDecodeSize {
        var w = max(2, pixels.width.rounded(.up)), h = max(2, pixels.height.rounded(.up))
        let longer = max(w, h)
        if longer > Double(maxSide) { let k = Double(maxSide) / longer; w = max(2, (w * k).rounded()); h = max(2, (h * k).rounded()) }
        return PreviewDecodeSize(width: Int(w) + (Int(w) & 1), height: Int(h) + (Int(h) & 1))
    }

    /// The largest even size with `aspect` (width/height) inside `self`.
    public func containing(aspect: Double) -> PreviewDecodeSize {
        guard aspect.isFinite, aspect > 0 else { return self }
        let w = Double(width), h = Double(height)
        return w / h > aspect ? PreviewDecodeSize(width: Int((h * aspect).rounded()), height: height)
                              : PreviewDecodeSize(width: width, height: Int((w / aspect).rounded()))
    }

    /// Whether a stream decoding at `self` can keep serving `wanted` (not visibly softer, not wastefully larger).
    public func serves(_ wanted: PreviewDecodeSize) -> Bool {
        let rw = Double(wanted.width) / Double(width), rh = Double(wanted.height) / Double(height)
        let aspect = (Double(wanted.width) / Double(wanted.height)) / (Double(width) / Double(height))
        return rw <= 1.1 && rh <= 1.1 && rw >= 0.6 && rh >= 0.6 && abs(aspect - 1) < 0.02
    }
}

/// Decodes one layer's media into the shared frame cache on its own queue. A video lane keeps the file open in one
/// engine reader and one stream reading it forward: during playback it stays `ahead` frames past the playhead; when it falls behind
/// it skips (decodes and discards) up to a second of frames, and further than that or backwards it restarts the
/// stream at the wanted frame. Playing backward (`behind` > 0) it decodes in chunks: one stream start a chunk
/// before the playhead fills that chunk front to back, and the next chunk is started a chunk early, so reverse
/// playback and shuttle seek once per chunk instead of on every frame. Requests are latest-wins and
/// never block the caller.
public final class PreviewDecodeLane: @unchecked Sendable {
    public let layer: PreviewLayer
    public let key: String
    let fps: Double
    let cache: PreviewFrameCache
    let queue: DispatchQueue
    /// Called on the lane's queue when the frame the display is waiting for has arrived.
    var onFrame: (() -> Void)?

    let lock = NSLock()
    var want = 0, ahead = 0, behind = 0
    var size = PreviewDecodeSize(width: 2, height: 2)
    var waiting = false, scheduled = false, stopped = false

    // Lane queue only.
    var reader: VideoFrameReader?
    var stream: MediaFrameStream?
    var streamSize: PreviewDecodeSize?
    var streamNext = 0          // timeline frame index the stream returns next
    var deadFrom = Int.max      // the media ran out at this timeline frame
    /// Frames ahead of the playhead a lane that fell behind aims at: what the playhead moved on while it last caught up.
    var lead = 0
    var stillSize: PreviewDecodeSize?
    /// Width/height of the media's picture, learned from the first decoded frame. Once known, frames are decoded
    /// at the media's own aspect, so a box whose size is animated does not restart the stream every frame.
    public private(set) var mediaAspect: Double?
    public private(set) var restarts = 0
    public private(set) var framesDecoded = 0
    public private(set) var framesSkipped = 0
    /// Seconds spent getting frames from the engine, summed (diagnostics, the preview benchmark).
    public private(set) var decodeSeconds = 0.0
    /// Set under `lock` when the lane gave up before producing any picture: the media could not be opened, or it
    /// yielded no frame. Tile previews waiting on this lane then fall back instead of showing "Rendering" forever.
    var gaveUpFlag = false
    public var gaveUp: Bool { lock.lock(); defer { lock.unlock() }; return gaveUpFlag }
    func giveUpIfNothingDecoded() {
        guard framesDecoded == 0 else { return }
        lock.lock(); gaveUpFlag = true; lock.unlock()
    }

    init(layer: PreviewLayer, fps: Double, cache: PreviewFrameCache) {
        self.layer = layer; key = layer.laneKey; self.fps = fps; self.cache = cache
        queue = DispatchQueue(label: "mpvfx.preview-decode.\(layer.clipId)", autoreleaseFrequency: .workItem)
    }

    /// Frame index of an image lane's single still.
    public static let stillFrame = 0

    /// Ask for `frame` on screen now, and (playing forward) `ahead` more after it, or (playing backward) `behind`
    /// more before it. Returns immediately.
    public func request(frame: Int, ahead: Int, behind: Int = 0, size: PreviewDecodeSize) {
        let f = layer.isStill ? Self.stillFrame : max(layer.startFrame, min(layer.endFrame - 1, frame))
        lock.lock()
        want = f; self.ahead = max(0, ahead); self.behind = max(0, behind); self.size = size
        waiting = !cache.contains(lane: key, frame: f)
        let go = !scheduled && !stopped
        if go { scheduled = true }
        lock.unlock()
        if go { queue.async { self.pump() } }
    }

    /// Stops decoding and closes the file; cached frames stay.
    public func stop() {
        lock.lock(); stopped = true; let idle = !scheduled; lock.unlock()
        if idle { queue.async { self.closeStream() } }
    }

    /// Blocks until queued work has run (tests, synchronous previews).
    public func wait() { queue.sync {} }

    /// The engine reader's time per stage (nil before the file is opened). Blocks until queued work has run.
    public func engineStats() throws -> VideoFrameReader.Stats? { try queue.sync { try reader?.stats() } }

    func closeStream() { stream = nil; streamSize = nil }

    /// The lane's open reader of its source (opened on first use; nil when the file cannot be read).
    func openReader() -> VideoFrameReader? {
        if reader == nil { reader = try? VideoFrameReader(path: layer.source) }
        if reader == nil { giveUpIfNothingDecoded() }
        return reader
    }

    func pump() {
        while true {
            lock.lock()
            if stopped { scheduled = false; lock.unlock(); closeStream(); reader = nil; return }
            let w = want, a = ahead, b = behind, sz = size
            lock.unlock()
            // One pool per decoded frame: this loop runs for as long as playback keeps asking for frames, and the
            // queue only drains its own pool when the loop returns.
            let worked = withAutoreleasePool {
                layer.isStill ? stepStill(sz) : b > 0 ? stepReverse(want: w, behind: b, size: sz) : stepVideo(want: w, ahead: a, size: sz)
            }
            if !worked {
                lock.lock()
                // A request may have landed after we read `want`; only go idle when nothing changed.
                if want == w && ahead == a && behind == b && size == sz || stopped { scheduled = false; lock.unlock(); if stopped { closeStream(); reader = nil }; return }
                lock.unlock()
            }
        }
    }

    func delivered(_ frame: Int) {
        lock.lock()
        let notify = waiting && frame == want
        if notify { waiting = false }
        lock.unlock()
        if notify { onFrame?() }
    }

    /// The one picture of an image or a held frame, decoded once at a size that serves the request. Returns false
    /// when there is nothing to do.
    func stepStill(_ sz: PreviewDecodeSize) -> Bool {
        if let s = stillSize, s.width * 10 >= sz.width * 9 && s.height * 10 >= sz.height * 9 { return false }
        stillSize = sz
        let frames = layer.holdSourceTime.map { MediaFrameStream.Frames(from: max(0, $0), fps: fps, width: sz.width, height: sz.height) }
            ?? .still(width: sz.width, height: sz.height)
        guard let reader = openReader(),
              let img = MediaFrameStream(reader: reader, frames: frames).next()
        else { giveUpIfNothingDecoded(); return false }
        framesDecoded += 1
        cache.store(img, lane: key, frame: Self.stillFrame)
        delivered(Self.stillFrame)
        return true
    }

    /// Capacity for this lane's frame size, including a slightly larger stream or cached frame we can reuse.
    /// Keep the wanted frame recent: speculative frames must not evict the picture the display needs now.
    func frameCapacity(want: Int, size: PreviewDecodeSize) -> Int {
        var bytes = size.width * size.height * 4
        if let s = streamSize, s.serves(size) { bytes = max(bytes, s.width * s.height * 4) }
        if let image = cache.frame(lane: key, frame: want) { bytes = max(bytes, image.width * image.height * 4) }
        // The cache keeps at least the most recently stored frame, even when one frame exceeds its budget.
        return max(1, cache.budgetBytes / max(1, bytes))
    }

    /// Decodes at most one frame toward the request. Returns false when the request is satisfied (or impossible).
    func stepVideo(want w: Int, ahead a: Int, size boxSize: PreviewDecodeSize) -> Bool {
        let sz = mediaAspect.map { boxSize.containing(aspect: $0) } ?? boxSize
        // A window that cannot fit would evict its own start and be decoded again forever.
        let a = min(a, frameCapacity(want: w, size: sz) - 1)
        let last = min(layer.endFrame - 1, w + a)
        // The first frame in [w, w+a] the cache lacks (for the current size).
        var target: Int?
        // Playing forward, frames the stream passed over (aiming ahead of the playhead) are not gone back for.
        var f = a > 0 && stream != nil && streamNext > w && streamNext <= last ? streamNext : w
        while f <= last && f < deadFrom {
            if !cache.contains(lane: key, frame: f) { target = f; break }
            f += 1
        }
        // A frame decoded at a visibly different size than wanted (window resized) is decoded again.
        if target == nil, w < deadFrom, let img = cache.frame(lane: key, frame: w),
           !PreviewDecodeSize(width: img.width, height: img.height).serves(sz) { target = w }
        guard var target else { return false }
        // Playing and behind the playhead: aim where the playhead will be once the frame is decoded, not where it is.
        // When even that overshoots by a second (decoding is far slower than playback), keep reading forward and show
        // what decodes instead of chasing the playhead through frames that all have to be decoded anyway.
        let second = Int(fps.rounded())
        let behind = a > 0 && streamNext < w && target == w && stream != nil
        let overloaded = behind && lead >= second
        if behind { target = overloaded ? streamNext : min(last, w + lead) }

        let reach = overloaded ? 4 * second : second
        let usable = stream != nil && streamSize.map { $0.serves(sz) } == true && streamNext <= target && target - streamNext <= reach
        if !usable {
            closeStream()
            let t = layer.sourceTime(at: Double(target) / fps)
            guard let r = openReader() else {
                deadFrom = min(deadFrom, target); return false
            }
            stream = MediaFrameStream(reader: r, frames: .init(from: max(0, t), fps: fps, width: sz.width, height: sz.height).playing(at: layer.rate))
            streamSize = sz; streamNext = target; restarts += 1; lead = 0
        }
        guard let s = stream else { return false }
        // Frames before the target are behind the playhead or already cached: pass over them instead of decoding and
        // converting each (the engine decodes forward to the target, skipping pictures nothing references).
        if streamNext < target { s.skip(target - streamNext); framesSkipped += target - streamNext; streamNext = target }
        let idx = streamNext
        guard let img = timedNext(s) else {
            // Media shorter than the clip: hold the last frame from here on (none at all: the lane gave up).
            deadFrom = min(deadFrom, idx); closeStream(); giveUpIfNothingDecoded(); return true
        }
        streamNext += 1
        if mediaAspect == nil { mediaAspect = Self.opaqueAspect(img) }
        lock.lock(); let currentWant = want; lock.unlock()
        if behind { lead = max(0, min(2 * Int(fps.rounded()), lead + currentWant - idx)) }
        // The playhead moved on while this frame decoded. It is still the newest picture of the clip, so it is kept to
        // be shown instead of an older one (dropping it froze the picture whenever decoding ran slower than playback);
        // it is dropped only when a newer frame is already cached.
        if idx < currentWant, let held = cache.nearest(lane: key, to: currentWant), held.frame >= idx { framesSkipped += 1; return true }
        framesDecoded += 1
        cache.store(img, lane: key, frame: idx)
        delivered(idx)
        return true
    }

    /// Reverse playback: the highest frame in [want - behind, want] the cache lacks is decoded as part of a chunk
    /// that ends at it and starts `behind` frames earlier, read forward from one stream start. Frames before the
    /// playhead are kept (they are what reverse playback shows next). Returns false when nothing is missing.
    func stepReverse(want w: Int, behind b: Int, size boxSize: PreviewDecodeSize) -> Bool {
        let sz = mediaAspect.map { boxSize.containing(aspect: $0) } ?? boxSize
        // Reverse fills up to two chunks, and a reused stream may start one frame before a chunk.
        let b = min(b, (frameCapacity(want: w, size: sz) - 1) / 2)
        guard b > 0 else { return stepVideo(want: w, ahead: 0, size: boxSize) }
        let low = max(layer.startFrame, w - b)
        var top: Int?
        var f = min(w, deadFrom - 1)
        while f >= low {
            if !cache.contains(lane: key, frame: f) { top = f; break }
            f -= 1
        }
        if top == nil, w < deadFrom, let img = cache.frame(lane: key, frame: w),
           !PreviewDecodeSize(width: img.width, height: img.height).serves(sz) { top = w }
        guard let top else { return false }
        // Read forward toward `top` when the open stream is already in this chunk; otherwise start the chunk.
        let chunkStart = max(layer.startFrame, top - b + 1)
        let usable = stream != nil && streamSize.map { $0.serves(sz) } == true && streamNext <= top && streamNext >= chunkStart - 1
        if !usable {
            closeStream()
            let t = layer.sourceTime(at: Double(chunkStart) / fps)
            guard let r = openReader() else {
                deadFrom = min(deadFrom, chunkStart); return false
            }
            stream = MediaFrameStream(reader: r, frames: .init(from: max(0, t), fps: fps, width: sz.width, height: sz.height).playing(at: layer.rate))
            streamSize = sz; streamNext = chunkStart; restarts += 1
        }
        guard let s = stream else { return false }
        let idx = streamNext
        guard let img = timedNext(s) else { deadFrom = min(deadFrom, idx); closeStream(); return true }
        streamNext += 1
        if mediaAspect == nil { mediaAspect = Self.opaqueAspect(img) }
        framesDecoded += 1
        cache.store(img, lane: key, frame: idx)
        delivered(idx)
        if idx >= top { closeStream() }   // chunk done; the next one starts a chunk lower
        return true
    }

    func timedNext(_ s: MediaFrameStream) -> CanvasImage? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { decodeSeconds += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }
        return s.next()
    }

    /// Aspect of the non-transparent part of a frame (the picture inside its letterbox padding).
    static func opaqueAspect(_ img: CanvasImage) -> Double? {
        var minX = img.width, maxX = -1, minY = img.height, maxY = -1
        img.rgba.withUnsafeBufferPointer { p in
            for y in 0..<img.height {
                var i = y * img.width * 4 + 3
                for x in 0..<img.width {
                    if p[i] != 0 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
                    i += 4
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return Double(maxX - minX + 1) / Double(maxY - minY + 1)
    }
}
