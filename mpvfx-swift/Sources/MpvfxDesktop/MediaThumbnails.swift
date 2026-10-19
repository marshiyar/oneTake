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
import MpvfxPlayer
import MpvfxDesktopCore
import OneTakeMedia
import MpvfxShared

/// The session's shared media picture/peaks service: one decoded frame per (file, time, size) and one waveform per
/// (project file, bars), cached and decoded off the UI thread. The media bin uses it for card thumbnails and audio
/// rows; the timeline's filmstrips and waveforms come from the same caches (`filmstrip(...)`, `waveform(..., done:)`).
///
/// Frames are decoded by the media engine exactly as the preview decodes them (MediaFrameStream: fitted, RGBA), so a
/// thumbnail and the preview show the same picture. Waveforms come from the backend (cached on disk with the
/// project's waveform peaks).
final class MediaThumbnails {
    struct FrameKey: Hashable { var path: String; var millis: Int; var width: Int; var height: Int; var still: Bool }
    struct PeaksKey: Hashable { var projectId: String; var source: String; var bars: Int }

    /// Called on the UI thread when a requested picture or waveform arrives (the shell redraws).
    var onReady: () -> Void = {}
    var post: (@escaping () -> Void) -> Void

    private var frames: [FrameKey: CanvasImage] = [:]
    private var framePending: Set<FrameKey> = []
    private var frameFailed: Set<FrameKey> = []
    private var frameOrder: [FrameKey] = []
    private var peaks: [PeaksKey: [Double]] = [:]
    private var peaksPending: Set<PeaksKey> = []
    private var peaksWaiters: [PeaksKey: [([Double]) -> Void]] = [:]
    private var strips: [StripKey: Strip] = [:]
    private var stripPending: Set<StripKey> = []
    private var stripFailed: Set<StripKey> = []
    private var stripWaiters: [StripKey: [(Strip?) -> Void]] = [:]
    /// Called after `forget` / `reset` so views holding pictures from this cache drop them (the timeline filmstrips).
    var onForget: (_ path: String?, _ source: String?) -> Void = { _, _ in }
    private let queue = DispatchQueue(label: "mpvfx.media-thumbnails", qos: .utility)
    /// Cached pictures kept (oldest dropped first): at most `frameLimit`, and pictures plus filmstrips together
    /// within `budgetBytes` (`MemoryBudget.mediaThumbnails`: 2% of RAM, 64…256 MB).
    let frameLimit = 400
    var budgetBytes = MemoryBudget.mediaThumbnails()
    private(set) var frameBytes = 0, stripBytes = 0
    private var stripOrder: [StripKey] = []
    private var pressureToken: MemoryPressureMonitor.Token?

    init(post: @escaping (@escaping () -> Void) -> Void, pressure: MemoryPressureMonitor? = .shared) {
        self.post = post
        // The system source calls on the main queue (this cache's thread).
        pressureToken = pressure?.observe { [weak self] level in self?.purge(level) }
    }

    /// Bytes of pictures held (bin thumbnails and filmstrips).
    var bytes: Int { frameBytes + stripBytes }

    /// Memory pressure: a warning trims to half the budget, critical drops every picture (views re-request them).
    func purge(_ level: MemoryPressureMonitor.Level) {
        switch level {
        case .warning: trim(to: budgetBytes / 2)
        case .critical: frames = [:]; frameOrder = []; frameBytes = 0; strips = [:]; stripOrder = []; stripBytes = 0; onForget(nil, nil)
        }
    }

    /// Drops the oldest pictures, then the oldest filmstrips, until at most `limit` bytes remain.
    private func trim(to limit: Int) {
        while bytes > limit, !frameOrder.isEmpty {
            let drop = frameOrder.removeFirst()
            if let f = frames.removeValue(forKey: drop) { frameBytes -= f.rgba.count }
        }
        var dropped = false
        while bytes > limit, !stripOrder.isEmpty {
            let drop = stripOrder.removeFirst()
            if let s = strips.removeValue(forKey: drop) { stripBytes -= Self.size(s); dropped = true }
        }
        if dropped { onForget(nil, nil) }
    }

    static func size(_ s: Strip) -> Int { s.frames.reduce(0) { $0 + $1.rgba.count } }

    /// The frame of `path` (absolute) at `seconds`, fitted inside width×height; nil until decoded (onReady fires) or when
    /// the engine cannot decode it (not retried until `forget`).
    func frame(path: String, at seconds: Double, width: Int, height: Int, still: Bool = false) -> CanvasImage? {
        let key = FrameKey(path: path, millis: still ? 0 : Int((max(0, seconds) * 1000).rounded()), width: width, height: height, still: still)
        if let f = frames[key] { return f }
        guard !framePending.contains(key), !frameFailed.contains(key) else { return nil }
        framePending.insert(key)
        let post = self.post
        queue.async { [weak self] in
            let img = (try? MediaFrameStream(source: path, frames: .one(at: Double(key.millis) / 1000, width: width, height: height,
                                                                             still: still)))?.next()
            post {
                guard let self else { return }
                self.framePending.remove(key)
                guard let img else { self.frameFailed.insert(key); return }
                self.frames[key] = img
                self.frameBytes += img.rgba.count
                self.frameOrder.append(key)
                if self.frameOrder.count > self.frameLimit {
                    let drop = self.frameOrder.removeFirst()
                    if let f = self.frames.removeValue(forKey: drop) { self.frameBytes -= f.rgba.count }
                }
                self.trim(to: self.budgetBytes)
                self.onReady()
            }
        }
        return nil
    }

    /// Normalised peaks (0…1) of a project media file; nil until loaded.
    func waveform(backend: DesktopBackend, projectId: String, source: String, bars: Int) -> [Double]? {
        let key = PeaksKey(projectId: projectId, source: source, bars: bars)
        if let p = peaks[key] { return p }
        loadPeaks(backend: backend, key: key)
        return nil
    }

    /// The same peaks, answered through `done` on the UI thread (immediately when cached; [] when unreadable).
    func waveform(backend: DesktopBackend, projectId: String, source: String, bars: Int, done: @escaping ([Double]) -> Void) {
        let key = PeaksKey(projectId: projectId, source: source, bars: bars)
        if let p = peaks[key] { return done(p) }
        peaksWaiters[key, default: []].append(done)
        loadPeaks(backend: backend, key: key)
    }

    private func loadPeaks(backend: DesktopBackend, key: PeaksKey) {
        guard !peaksPending.contains(key) else { return }
        peaksPending.insert(key)
        let post = self.post
        Task { [weak self] in
            let p = (try? await backend.waveform(projectId: key.projectId, source: key.source, bars: key.bars)) ?? []
            post {
                guard let self else { return }
                self.peaksPending.remove(key)
                self.peaks[key] = p
                for w in self.peaksWaiters.removeValue(forKey: key) ?? [] { w(p) }
                if !p.isEmpty { self.onReady() }
            }
        }
    }

    // MARK: Filmstrips (timeline clips)

    /// A strip of `count` frames across a file. Videos come from the backend's thumbnails (VideoFrames:
    /// JPEG frames spread over the source) when there is one; images, and sessions without a backend, decode with
    /// the engine from the file. Cached per (file, frame count); `done` runs on the UI thread, nil when undecodable.
    struct StripKey: Hashable { var path: String; var count: Int }
    struct Strip { var frames: [CanvasImage]; var aspect: Double }
    static let stripFrameSize = (width: 160, height: 90)

    func filmstrip(path: String, still: Bool, count: Int, duration: Double,
                   backend: (backend: DesktopBackend, projectId: String, source: String)?, done: @escaping (Strip?) -> Void) {
        let key = StripKey(path: path, count: still ? 1 : max(1, min(6, count)))
        if let s = strips[key] { return done(s) }
        if stripFailed.contains(key) { return done(nil) }
        stripWaiters[key, default: []].append(done)
        guard !stripPending.contains(key) else { return }
        stripPending.insert(key)
        let post = self.post, queue = self.queue
        let finish: (Strip?) -> Void = { strip in
            post { [weak self] in
                guard let self else { return }
                self.stripPending.remove(key)
                if let strip {
                    if let old = self.strips[key] { self.stripBytes -= Self.size(old) } else { self.stripOrder.append(key) }
                    self.strips[key] = strip; self.stripBytes += Self.size(strip)
                    self.trim(to: self.budgetBytes)
                } else { self.stripFailed.insert(key) }
                for w in self.stripWaiters.removeValue(forKey: key) ?? [] { w(strip) }
            }
        }
        let size = Self.stripFrameSize
        if !still, let b = backend {
            Task {
                let r = try? await b.backend.videoFrames(projectId: b.projectId, request: DesktopVideoFramesRequest(
                    source: b.source, frameCount: key.count, width: size.width, height: size.height))
                queue.async {
                    guard let r else { return finish(nil) }
                    let frames = r.jpegFrames.compactMap { Self.decodeJPEG($0, width: r.width, height: r.height) }
                    finish(frames.isEmpty ? nil : Strip(frames: frames, aspect: r.aspect))
                }
            }
            return
        }
        queue.async {
            let n = key.count
            guard let reader = try? VideoFrameReader(path: path) else { return finish(nil) }
            let frames = (0..<n).compactMap { i in
                // Centre of each of n equal slices of the file (the backend's strip spacing).
                MediaFrameStream(reader: reader, frames: .one(at: max(0, duration) * (Double(i) + 0.5) / Double(n),
                                                              width: size.width, height: size.height, still: still)).next()
            }
            finish(frames.isEmpty ? nil : Strip(frames: frames, aspect: Double(size.width) / Double(size.height)))
        }
    }

    /// A backend JPEG frame as RGBA, fitted inside width×height like every other thumbnail.
    static func decodeJPEG(_ data: Data, width: Int, height: Int) -> CanvasImage? {
        guard width > 0, height > 0, let img = try? ImageCodec.decode(data) else { return nil }
        if img.width == width && img.height == height { return CanvasImage(width: width, height: height, rgba: img.rgba) }
        guard img.width > 0, img.height > 0, let surface = try? RasterSurface(width: width, height: height) else { return nil }
        let k = min(Double(width) / Double(img.width), Double(height) / Double(img.height))
        let w = Double(img.width) * k, h = Double(img.height) * k
        let rect = RasterRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
        guard (try? surface.drawImage(RasterImage(rgba: img.rgba, width: img.width, height: img.height), in: rect)) != nil else { return nil }
        return CanvasImage(width: width, height: height, rgba: surface.rgba())
    }

    /// Drops everything cached for a file (renamed, deleted or replaced on disk).
    func forget(path: String) {
        for (k, f) in frames where k.path == path { frames[k] = nil; frameBytes -= f.rgba.count }
        frameFailed = frameFailed.filter { $0.path != path }
        frameOrder.removeAll { $0.path == path }
        for (k, s) in strips where k.path == path { strips[k] = nil; stripBytes -= Self.size(s) }
        stripOrder.removeAll { $0.path == path }
        stripFailed = stripFailed.filter { $0.path != path }
        onForget(path, nil)
    }

    func forget(source: String) { peaks = peaks.filter { $0.key.source != source }; onForget(nil, source) }

    func reset() {
        frames = [:]; frameFailed = []; frameOrder = []; peaks = [:]; strips = [:]; stripFailed = []
        frameBytes = 0; stripBytes = 0; stripOrder = []
        onForget(nil, nil)
    }
}
