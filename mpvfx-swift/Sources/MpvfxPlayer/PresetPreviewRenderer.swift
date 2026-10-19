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

/// Grade preset thumbnails (the look previews of the grade presets): the selected clip's current
/// frame graded with each preset plus the clip's LUT (`normalizeHfColorGrading({ preset, lut })`), downscaled to the
/// tile's device pixels.
///
/// The source is the raw frame the preview already decoded (`compositor.cache`, exact frame else the nearest one of
/// the same lane). When the clip is not under the playhead the compositor has no lane for it, so the renderer runs
/// one small decode lane of its own at tile size into a private cache.
///
/// Work runs on one serial background queue; `preview` never blocks. Thumbnails sit in an LRU bounded by
/// `budgetBytes` (a few MB: 18 tiles at 2x are ~2.5 MB), keyed by lane + frame + preset + LUT + size; requests that a
/// newer one replaced before they ran are dropped.
public final class PresetPreviewRenderer: @unchecked Sendable {
    public enum State {
        case ready(CanvasImage)
        case rendering
        case unavailable
    }

    public struct Key: Hashable, Sendable {
        public var lane: String, frame: Int, preset: String, lut: String, width: Int, height: Int
    }

    public let compositor: PreviewCompositor
    public let budgetBytes: Int
    /// Project folder for resolving the LUT path (read on the caller's thread).
    public var projectDir: () -> String? = { nil }
    public var colorRenderer: ColorRenderer = ColorRendering.shared
    /// Called on a background queue when a thumbnail (or a frame it was waiting for) is ready; hosts hop to the UI.
    public var onReady: (() -> Void)?

    let queue = DispatchQueue(label: "mpvfx.preset-preview", qos: .userInitiated)
    let lock = NSLock()
    var images: [Key: (image: CanvasImage, tick: UInt64)] = [:]
    var tick: UInt64 = 0
    public private(set) var bytes = 0
    var pending = Set<Key>()
    /// The newest key asked for per preset tile; queued jobs for anything else are skipped.
    var latest: [String: Key] = [:]
    /// Thumbnails rendered (tests, diagnostics).
    public private(set) var rendered = 0

    /// Off-playhead source frames: one lane at a time, decoded at tile size into a small cache of its own.
    let ownCache: PreviewFrameCache
    var ownLane: PreviewDecodeLane?

    public init(compositor: PreviewCompositor, budgetBytes: Int = 6 << 20, decodeBudgetBytes: Int = 2 << 20) {
        self.compositor = compositor
        self.budgetBytes = max(1, budgetBytes)
        ownCache = PreviewFrameCache(budgetBytes: decodeBudgetBytes)
    }

    deinit { ownLane?.stop() }

    /// Thumbnail of `presetId` for `clipId` at composition `time` (clamped into the clip), `pixelWidth` x
    /// `pixelHeight` device pixels at most (aspect-fit). Call on the UI thread.
    public func preview(clipId: String, presetId: String, lut: ColorGradeParams.Lut?, time: Double, pixelWidth: Int, pixelHeight: Int) -> State {
        guard pixelWidth > 1, pixelHeight > 1, let comp = compositor.composition,
              let entry = comp.entries.first(where: { $0.clip.id == clipId }) else { return .unavailable }
        let c = entry.clip
        let first = c.startFrame / comp.fps, last = (c.startFrame + max(1, c.durationFrames) - 1) / comp.fps
        let t = max(first, min(last, time))
        let layer = comp.layer(entry, at: t)
        let want = layer.kind == .image ? PreviewDecodeLane.stillFrame : max(layer.startFrame, min(layer.endFrame - 1, comp.frameIndex(at: t)))
        guard let source = sourceFrame(layer, want: want, fps: comp.fps, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return compositor.decodesMedia ? .rendering : .unavailable
        }
        let lutKey = lut.map { "\($0.src)@\($0.intensity)" } ?? ""
        let key = Key(lane: layer.laneKey, frame: source.frame, preset: presetId, lut: lutKey, width: pixelWidth, height: pixelHeight)
        lock.lock()
        if let hit = images[key] {
            tick += 1; images[key] = (hit.image, tick); latest[presetId] = key
            lock.unlock()
            return .ready(hit.image)
        }
        latest[presetId] = key
        let queued = pending.contains(key)
        if !queued { pending.insert(key) }
        lock.unlock()
        if !queued {
            let dir = projectDir(), renderer = colorRenderer
            let shownFrame = layer.kind == .image ? comp.frameIndex(at: t) : source.frame
            let gradeTime = Double(shownFrame) / comp.fps
            queue.async { [weak self] in
                self?.render(key, slot: presetId, raw: source.image, time: gradeTime, renderer: renderer) {
                    ColorGradeRenderer.forClip(Self.params(preset: presetId, lut: lut), clipId: clipId, projectDir: dir)
                }
            }
        }
        return .rendering
    }

    /// The selected clip's frame at `time` with its own grade (the scopes' captured frame), at most `pixelWidth` x
    /// `pixelHeight`. Shares the queue, the source lookup and the bounded cache with the preset tiles.
    public func gradedFrame(clipId: String, time: Double, pixelWidth: Int, pixelHeight: Int) -> State {
        guard pixelWidth > 1, pixelHeight > 1, let comp = compositor.composition,
              let entry = comp.entries.first(where: { $0.clip.id == clipId }) else { return .unavailable }
        let c = entry.clip
        let first = c.startFrame / comp.fps, last = (c.startFrame + max(1, c.durationFrames) - 1) / comp.fps
        let t = max(first, min(last, time))
        let layer = comp.layer(entry, at: t)
        let want = layer.kind == .image ? PreviewDecodeLane.stillFrame : max(layer.startFrame, min(layer.endFrame - 1, comp.frameIndex(at: t)))
        guard let source = sourceFrame(layer, want: want, fps: comp.fps, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return compositor.decodesMedia ? .rendering : .unavailable
        }
        let slot = "\u{0}scope"
        let shownFrame = layer.kind == .image ? comp.frameIndex(at: t) : source.frame
        let key = Key(lane: layer.laneKey, frame: source.frame, preset: "\(slot)|\(layer.grade?.signature ?? "-")|\(shownFrame)", lut: "",
                      width: pixelWidth, height: pixelHeight)
        lock.lock()
        if let hit = images[key] {
            tick += 1; images[key] = (hit.image, tick); latest[slot] = key
            lock.unlock()
            return .ready(hit.image)
        }
        latest[slot] = key
        let queued = pending.contains(key)
        if !queued { pending.insert(key) }
        lock.unlock()
        if !queued {
            let renderer = colorRenderer, grade = layer.grade, gradeTime = Double(shownFrame) / comp.fps
            queue.async { [weak self] in
                self?.render(key, slot: slot, raw: source.image, time: gradeTime, renderer: renderer) { grade }
            }
        }
        return .rendering
    }

    /// Whether `clipId` has a picture to preview: a visual clip with readable media, and a decoder or a decoded frame.
    public func isAvailable(clipId: String) -> Bool {
        guard let comp = compositor.composition, let e = comp.entries.first(where: { $0.clip.id == clipId }) else { return false }
        if compositor.decodesMedia { return true }
        let lane = comp.layer(e, at: e.clip.startFrame / comp.fps).laneKey
        return compositor.cache.nearest(lane: lane, to: 0) != nil
    }

    /// `preview` with the LUT as the clip stores it (`lut.src`, `lut.intensity`).
    public func preview(clipId: String, presetId: String, lutSrc: String?, lutIntensity: Double, time: Double, pixelWidth: Int, pixelHeight: Int) -> State {
        let lut = lutSrc.flatMap { s -> ColorGradeParams.Lut? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : ColorGradeParams.Lut(src: t, intensity: lutIntensity.isFinite ? min(1, max(0, lutIntensity)) : 1)
        }
        return preview(clipId: clipId, presetId: presetId, lut: lut, time: time, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// The raw frame to grade: the preview's exact frame, then our own decode's exact frame, then (while that
    /// decode runs) the nearest frame either cache holds. Starts the own decode when the preview has no exact frame.
    func sourceFrame(_ layer: PreviewLayer, want: Int, fps: Double, pixelWidth: Int, pixelHeight: Int) -> (frame: Int, image: CanvasImage)? {
        let lane = layer.laneKey
        if let img = compositor.cache.frame(lane: lane, frame: want) { return (want, img) }
        if let img = ownCache.frame(lane: lane, frame: want) { return (want, img) }
        // Under the playhead the preview's own lane is already decoding this frame; elsewhere ask for it ourselves.
        if compositor.decodesMedia, compositor.lanes[lane] == nil {
            if ownLane?.key != lane {
                ownLane?.stop()
                let l = PreviewDecodeLane(layer: layer, fps: fps, cache: ownCache)
                l.onFrame = { [weak self] in self?.onReady?() }
                ownLane = l
            }
            ownLane?.request(frame: want, ahead: 0, size: PreviewDecodeSize(width: pixelWidth, height: pixelHeight))
        }
        return compositor.cache.nearest(lane: lane, to: want) ?? ownCache.nearest(lane: lane, to: want)
    }

    func render(_ key: Key, slot: String, raw: CanvasImage, time: Double, renderer: ColorRenderer, grade makeGrade: () -> ColorGradeRenderer?) {
        lock.lock()
        let wanted = latest[slot] == key
        if !wanted { pending.remove(key) }
        lock.unlock()
        guard wanted else { return }
        var img = Self.downscale(raw, fitting: key.width, key.height)
        if let grade = makeGrade(), grade.isActive {
            var px = img.rgba
            renderer.render(grade, &px, width: img.width, height: img.height, time: time)
            img = CanvasImage(width: img.width, height: img.height, rgba: px)
        }
        lock.lock()
        pending.remove(key)
        tick += 1
        if let old = images[key] { bytes -= Self.size(old.image) }
        images[key] = (img, tick)
        bytes += Self.size(img)
        evict(protecting: key)
        rendered += 1
        lock.unlock()
        onReady?()
    }

    /// `normalizeHfColorGrading({ preset, lut })`.
    public static func params(preset: String, lut: ColorGradeParams.Lut?) -> ColorGradeParams? {
        var o: NativeJSONObject = ["preset": .string(preset)]
        if let lut { o["lut"] = .object(["src": .string(lut.src), "intensity": .number(lut.intensity)]) }
        return ColorGradeParams(json: o)
    }

    static func size(_ i: CanvasImage) -> Int { i.width * i.height * 4 }

    func evict(protecting keep: Key) {
        guard bytes > budgetBytes else { return }
        for v in images.filter({ $0.key != keep }).sorted(by: { $0.value.tick < $1.value.tick }) {
            if bytes <= budgetBytes { break }
            if let old = images.removeValue(forKey: v.key) { bytes -= Self.size(old.image) }
        }
    }

    /// Cached thumbnails (tests).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return images.count }

    /// Drops every thumbnail and the own decode (closing a project).
    public func reset() {
        lock.lock(); images = [:]; bytes = 0; latest = [:]; lock.unlock()
        ownLane?.stop(); ownLane = nil
    }

    /// Blocks until queued renders have run (tests).
    public func wait() { ownLane?.wait(); queue.sync {} }

    /// Area-average downscale to the largest size with the image's aspect inside `w` x `h` (never upscales).
    public static func downscale(_ img: CanvasImage, fitting w: Int, _ h: Int) -> CanvasImage {
        guard img.width > 0, img.height > 0 else { return img }
        let s = min(1, min(Double(w) / Double(img.width), Double(h) / Double(img.height)))
        let ow = max(1, Int((Double(img.width) * s).rounded())), oh = max(1, Int((Double(img.height) * s).rounded()))
        if ow == img.width && oh == img.height { return img }
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        img.rgba.withUnsafeBufferPointer { src in
            for y in 0..<oh {
                let y0 = y * img.height / oh, y1 = max(y0 + 1, (y + 1) * img.height / oh)
                for x in 0..<ow {
                    let x0 = x * img.width / ow, x1 = max(x0 + 1, (x + 1) * img.width / ow)
                    var r = 0, g = 0, b = 0, a = 0
                    for sy in y0..<y1 {
                        var i = (sy * img.width + x0) * 4
                        for _ in x0..<x1 { r += Int(src[i]); g += Int(src[i + 1]); b += Int(src[i + 2]); a += Int(src[i + 3]); i += 4 }
                    }
                    let n = (y1 - y0) * (x1 - x0), o = (y * ow + x) * 4
                    out[o] = UInt8(r / n); out[o + 1] = UInt8(g / n); out[o + 2] = UInt8(b / n); out[o + 3] = UInt8(a / n)
                }
            }
        }
        return CanvasImage(width: ow, height: oh, rgba: out)
    }
}
