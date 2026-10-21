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
import MpvfxPanels

/// The composited program frame at the playhead, for the Grade scopes' Program mode: every visible track at that time,
/// graded and blended by the export painter (`ExportFramePainter`, the code export writes frames with), with the
/// project canvas fitted into `ColorScopes.analysisSide` pixels on its long side. The pictures are the raw frames the
/// preview already decoded (`compositor.cache`: the exact frame, else the nearest one of the same lane), so this
/// never decodes; a layer with nothing cached yet is left out until its lane has a frame, and the newer frame then
/// changes the key and paints again.
///
/// Why not read back the stage's pixels: the stage also draws live drag edits, zoom, guides and selection outlines, at
/// the window's size, on a platform canvas that cannot be read back on every backend. The painter draws exactly what
/// export draws for that time, at scope size.
///
/// `frame(at:)` never blocks: it resolves the layers and looks up their frames on the caller's thread, then paints on
/// one serial background queue. Only the newest request is kept: a request replaces one that has not started.
public final class ProgramScopeRenderer: @unchecked Sendable {
    public typealias State = PresetPreviewRenderer.State

    /// One layer of a program frame: what is drawn, at which size, from which decoded picture.
    struct Part: Equatable {
        var layer: PreviewLayer
        var width: Int, height: Int
        /// Lane frame of the picture and its pixel size (nil: a text layer, or nothing cached yet).
        var picture: PictureId?
    }
    struct PictureId: Equatable { var lane: String; var frame: Int; var width: Int; var height: Int }

    /// What a program frame is painted from: equal keys paint equal pixels.
    struct Key: Equatable {
        var frameIndex: Int
        var width: Int, height: Int
        var canvas: CanvasSize
        var background: CanvasColor
        var parts: [Part]
    }

    struct Job {
        var key: Key
        var composition: PreviewComposition
        var time: Double
        var pictures: [CanvasImage?]
    }

    public let compositor: PreviewCompositor
    /// Called on the background queue when a newer program frame is ready; hosts hop to the UI thread and redraw.
    public var onReady: (() -> Void)?

    let queue = DispatchQueue(label: "mpvfx.program-scope", qos: .userInitiated)
    let lock = NSLock()
    var pending: Job?
    var running: Key?
    var scheduled = false
    var finished: (key: Key, image: CanvasImage)?
    var paintedCount = 0
    var failure: Error?
    /// The key whose paint threw (shown as unavailable until the frame, an edit or the size changes the key).
    var failedKey: Key?

    public init(compositor: PreviewCompositor) { self.compositor = compositor }

    /// Program frames painted so far (tests, diagnostics).
    public var painted: Int { lock.lock(); defer { lock.unlock() }; return paintedCount }
    /// Why the last paint failed (the raster canvas could not be made or drawn), nil after a success.
    public var lastError: Error? { lock.lock(); defer { lock.unlock() }; return failure }

    /// The output size of a `canvas` fitted inside `width` × `height` (never upscaled, at least 1 × 1).
    public static func outputSize(_ canvas: CanvasSize, fitting width: Int, _ height: Int) -> (width: Int, height: Int) {
        let cw = max(canvas.width, 1), ch = max(canvas.height, 1)
        let s = min(1, min(Double(width) / cw, Double(height) / ch))
        return (max(1, Int((cw * s).rounded())), max(1, Int((ch * s).rounded())))
    }

    /// The program frame at composition `time`, fitted inside `pixelWidth` × `pixelHeight`: `.ready` when the newest
    /// request is painted, `.rendering` while it paints, `.unavailable` with no composition or when its paint threw
    /// (`lastError`). Call on the UI thread.
    public func frame(at time: Double, pixelWidth: Int = ColorScopes.analysisSide,
                      pixelHeight: Int = ColorScopes.analysisSide) -> State {
        guard pixelWidth > 0, pixelHeight > 0, time.isFinite, let comp = compositor.composition,
              comp.canvas.width > 0, comp.canvas.height > 0 else { return .unavailable }
        let job = makeJob(comp, time: time, fitting: pixelWidth, pixelHeight)
        lock.lock(); defer { lock.unlock() }
        if let done = finished, done.key == job.key { return .ready(done.image) }
        if failedKey == job.key { return .unavailable }   // painting it again would fail again; a new key retries
        if running != job.key { pending = job }
        if !scheduled {
            scheduled = true
            queue.async { [weak self] in self?.drain() }
        }
        return .rendering
    }

    /// The layers at `time` and the decoded pictures they draw (looked up now, painted later).
    func makeJob(_ comp: PreviewComposition, time: Double, fitting w: Int, _ h: Int) -> Job {
        let size = Self.outputSize(comp.canvas, fitting: w, h)
        let scale = min(Double(size.width) / comp.canvas.width, Double(size.height) / comp.canvas.height)
        let frameIndex = comp.frameIndex(at: time)
        var parts: [Part] = [], pictures: [CanvasImage?] = []
        for (layer, lw, lh) in ExportFramePainter.layers(comp, at: time, scale: scale) {
            let picture = layer.kind == .text ? nil : cachedPicture(layer, frameIndex: frameIndex)
            pictures.append(picture?.image)
            parts.append(Part(layer: layer, width: lw, height: lh, picture: picture.map {
                PictureId(lane: layer.laneKey, frame: $0.frame, width: $0.image.width, height: $0.image.height)
            }))
        }
        let key = Key(frameIndex: frameIndex, width: size.width, height: size.height, canvas: comp.canvas,
                      background: comp.background, parts: parts)
        return Job(key: key, composition: comp, time: time, pictures: pictures)
    }

    /// The raw picture the preview holds for `layer` at timeline frame `frameIndex`: exact, else the nearest cached.
    func cachedPicture(_ layer: PreviewLayer, frameIndex: Int) -> (frame: Int, image: CanvasImage)? {
        let want = layer.kind == .image ? PreviewDecodeLane.stillFrame : frameIndex
        if let image = compositor.cache.frame(lane: layer.laneKey, frame: want) { return (want, image) }
        return compositor.cache.nearest(lane: layer.laneKey, to: want)
    }

    /// Paints queued jobs until none is left; a job replaced before it started is never painted.
    func drain() {
        while true {
            lock.lock()
            guard let job = pending else { scheduled = false; running = nil; lock.unlock(); return }
            pending = nil; running = job.key
            lock.unlock()
            var image: CanvasImage?
            var error: Error?
            do { image = try Self.paint(job) } catch let e { error = e }
            lock.lock()
            failure = error
            failedKey = error == nil ? nil : job.key
            if let image { finished = (job.key, image); paintedCount += 1 }
            running = nil
            lock.unlock()
            if image != nil { onReady?() }
        }
    }

    /// One program frame through the export painter; throws when the raster canvas cannot be made or drawn.
    static func paint(_ job: Job) throws -> CanvasImage {
        let painter = try ExportFramePainter(composition: job.composition, width: job.key.width,
                                             height: job.key.height, pad: .opaqueBlack)
        let layers = job.key.parts.map { (layer: $0.layer, width: $0.width, height: $0.height) }
        var byClip: [String: CanvasImage] = [:]
        for (part, picture) in zip(job.key.parts, job.pictures) {
            if let picture { byClip[part.layer.clipId] = PresetPreviewRenderer.downscale(picture, fitting: part.width, part.height) }
        }
        return try painter.paint(layers, time: job.time) { layer, _, _, _ in byClip[layer.clipId] }
    }

    /// Blocks until queued paints have run (tests).
    public func wait() { queue.sync {} }
}
