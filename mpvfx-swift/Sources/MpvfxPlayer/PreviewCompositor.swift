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
import MpvfxTheme
import MpvfxTimeline
import MpvfxColor
import MpvfxShared

/// The preview's frame source: composites every visible video/image layer at the playhead, bottom track first,
/// with crop, keyframed transform and opacity, at the display's pixel density.
///
/// Drawing never waits for a decoder. Each layer shows its exact frame when cached, else the closest earlier
/// frame of the same clip (playback drops frames instead of stalling), else the last picture the clip drew (a
/// paused seek after the cache was trimmed), else nothing yet; `Shown.exact` is true only for the exact frame.
/// While playing forward every visible clip decodes ahead of the playhead, and clips about to start are pre-rolled
/// so cuts don't flash.
/// Time comes from the transport, which follows the audio device clock when audio is playing, so picture stays
/// in sync with sound by construction.
///
/// The cache holds raw decoded frames; each clip's color grade and stylize effects are applied on top by
/// `PreviewGrader`, off the main thread, at the size the clip is displayed (Metal on macOS, the CPU port elsewhere).
/// A draw never waits for a grade: it shows the clip's latest finished look and asks for the current one; rapid
/// edits coalesce to the newest value, and `frameReady` fires when it is graded. A grade edit therefore never
/// restarts a decoder, never flushes the frame cache, and re-runs only the shader on a frame already on the GPU.
public final class PreviewCompositor: FrameSource {
    /// The document as layers. Setting it keeps decoders whose clip and media did not change, and drops the cached
    /// frames and graded pictures of clips that are no longer in it.
    public var composition: PreviewComposition? { didSet { releaseRemovedClips() } }
    /// False for a compositor that only draws text and placeholders (tests, audits): no decoder is started.
    public let decodesMedia: Bool
    public let cache: PreviewFrameCache
    /// Called (on a decoder queue) when a frame the display was waiting for is ready; hosts hop to the UI thread.
    public var frameReady: (() -> Void)?
    public let placeholder: PlaceholderFrameSource
    /// Upper bound for decode-ahead per clip while playing.
    public var maxLookahead = 12
    /// Longest side of a decoded frame, in device pixels.
    public var maxDecodeSide = 3840

    public private(set) var lanes: [String: PreviewDecodeLane] = [:]

    /// What the last draw put on screen, per layer, bottom first (diagnostics and tests).
    public struct Shown: Equatable {
        public var clipId: String; public var frame: Int?; public var exact: Bool
        /// Signature of the grade the drawn pixels carry (nil: ungraded), and whether it is the clip's current grade.
        public var grade: String? = nil
        public var gradeCurrent = true
    }
    public private(set) var lastShown: [Shown] = []
    var blendSurface: RasterCanvas?
    /// Draws where a layer showed a stand-in instead of its exact frame.
    public private(set) var heldFrames = 0
    /// The lane each clip last drew from (a trim or retime switches lanes; the old frames bridge the gap).
    var shownLane: [String: String] = [:]
    /// A raw decoded picture of a clip, the lane and frame it came from, and whether it is the frame being drawn.
    struct Picture { var image: CanvasImage; var frame: Int; var lane: String; var exact: Bool }
    /// The last picture each clip drew: the stand-in of last resort, when the clip's lanes have nothing cached near the
    /// playhead (its frames evicted by other clips), so a paused seek does not blank the clip while its exact frame
    /// decodes. Bounded: an eighth of the frame cache budget, clips the last draw drew, nothing under memory pressure.
    let standIns: PreviewStandIns
    /// Grades frames for display off the main thread (latest request wins).
    public let grader = PreviewGrader()
    /// The renderer that grades preview frames.
    public var colorRenderer: ColorRenderer { get { grader.renderer } set { grader.renderer = newValue } }
    var gradedNow = 0
    /// Frames graded for display or by `decodeNow` (diagnostics, tests).
    public var framesGraded: Int { grader.finished + gradedNow }

    /// Clip of each lane that has stored frames (lane keys start with the clip id, which may itself contain "|").
    var laneClip: [String: String] = [:]

    /// `cacheBudgetBytes`: raw frame cache budget, by default `MemoryBudget.previewFrames()` (min(2 GB, 10% of RAM)).
    public init(decodesMedia: Bool = true, cacheBudgetBytes: Int = MemoryBudget.previewFrames(), background: CanvasColor = CanvasColor(ThemeTokens.stageDefaultBackground)) {
        self.decodesMedia = decodesMedia
        cache = PreviewFrameCache(budgetBytes: cacheBudgetBytes)
        standIns = PreviewStandIns(budgetBytes: cacheBudgetBytes / 8)
        placeholder = PlaceholderFrameSource(background: background)
        grader.onFinished = { [weak self] in self?.frameReady?() }
    }

    /// Frees what belongs to clips the composition no longer has: their cached raw frames, their graded picture and
    /// the lane they last drew from. Lanes of clips still present stay (an edit's old lane bridges the redecode).
    func releaseRemovedClips() {
        let live = Set(composition?.entries.map(\.clip.id) ?? [])
        for (lane, clip) in laneClip where !live.contains(clip) {
            cache.removeLane(lane); laneClip[lane] = nil
        }
        for clip in shownLane.keys where !live.contains(clip) { shownLane[clip] = nil }
        standIns.keepOnly(live)
        grader.keepOnly(live)
    }

    /// Bytes of graded pictures the grader holds for redraws (finished looks, reduced sources, drafts).
    public var gradedMemoBytes: Int { grader.bytes }

    /// Bytes the grader may hold across clips (`MemoryBudget.gradedFrames`: 2% of RAM, 64…256 MB).
    public var gradedMemoBudget: Int { get { grader.budgetBytes } set { grader.budgetBytes = newValue } }

    /// Closing the project: ends every decoder and frees every cached frame and graded picture.
    public func releaseAll() {
        stopAll()
        cache.removeAll()
        laneClip = [:]; shownLane = [:]; standIns.removeAll()
    }

    deinit { for l in lanes.values { l.stop() } }

    public func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement]) {
        draw(c, in: rect, time: time, elements: elements, context: FrameDrawContext())
    }

    public func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement], context: FrameDrawContext) {
        guard let comp = composition, comp.canvas.width > 0 else {
            placeholder.draw(c, in: rect, time: time, elements: elements); return
        }
        let s = rect.width / comp.canvas.width
        let live = context.liveElementIds.map { ids in elements.filter { ids.contains($0.id) } } ?? elements
        let layers = Self.applyStage(live, to: comp.layers(at: time), frame: rect, scale: s)
        let frame = comp.frameIndex(at: time)
        let forward = context.isPlaying && context.speed > 0, backward = context.isPlaying && context.speed < 0
        let ahead = forward ? lookahead(layers, comp: comp, scale: s, backing: context.backingScale, speed: context.speed) : 0
        let behind = backward ? reverseChunk(layers, comp: comp, scale: s, backing: context.backingScale, speed: -context.speed) : 0

        // A frame holding a blended layer is painted on a raster surface the blend can read back, then drawn in `rect`
        // (the picture export paints); other frames draw straight onto `c`.
        let blended = layers.contains { $0.isVisible && $0.blend != .normal }
        let offscreen = blended ? blendCanvas(rect, backing: context.backingScale) : nil
        let target: CanvasContext = offscreen ?? c
        let area = offscreen.map { CanvasRect(x: 0, y: 0, width: Double($0.surface.width), height: Double($0.surface.height)) } ?? rect
        let areaScale = offscreen == nil ? s : area.width / comp.canvas.width
        if let offscreen { offscreen.clear(.transparent) }
        target.fillRect(area, comp.background)
        defer { if let offscreen { c.drawImage(offscreen.image(), in: rect) } }

        var used = Set<String>()
        var shown: [Shown] = []
        for layer in layers where layer.isVisible {
            if layer.kind == .offline {   // missing media: a slate naming the file, never decoded
                PreviewPainter.drawOffline(layer, on: target, frame: area, scale: areaScale)
                shown.append(Shown(clipId: layer.clipId, frame: frame, exact: true)); continue
            }
            if layer.isProcedural {   // text layers are laid out, not decoded
                PreviewPainter.drawText(layer, on: target, frame: area, scale: areaScale)
                shown.append(Shown(clipId: layer.clipId, frame: frame, exact: true)); continue
            }
            let size = decodeSize(layer, scale: s, backing: context.backingScale)
            if let lane = lane(for: layer, fps: comp.fps) {
                lane.request(frame: frame, ahead: ahead, behind: behind, size: size)
                used.insert(lane.key)
            }
            let want = layer.isStill ? PreviewDecodeLane.stillFrame : frame
            guard let pick = picture(for: layer, want: want) else {
                shown.append(Shown(clipId: layer.clipId, frame: nil, exact: false)); continue
            }
            let look = shownImage(layer, pick.image, frame: pick.frame, time: time, fps: comp.fps, target: size,
                                  lane: pick.lane)
            draw(layer, raw: pick.image, shown: look.image, shownIsCurrent: look.current, on: target, frame: area, scale: areaScale,
                 context: context)
            shown.append(Shown(clipId: layer.clipId, frame: pick.frame, exact: pick.exact,
                               grade: look.grade, gradeCurrent: look.current))
            drew(pick, for: layer)
        }
        // Pre-roll clips starting soon so their first frames are ready at the cut.
        if forward {
            let horizon = max(0.5, Double(ahead) / comp.fps) * max(1, context.speed)
            for up in comp.upcoming(after: time, within: horizon) where up.isVisible {
                guard let lane = lane(for: up, fps: comp.fps) else { continue }
                lane.request(frame: up.startFrame, ahead: min(ahead, 3), size: decodeSize(up, scale: s, backing: context.backingScale))
                used.insert(lane.key)
            }
        }
        // Backward: clips that end just before the playhead get their last chunk ready for the cut.
        if backward {
            let horizon = max(0.5, Double(behind) / comp.fps)
            for up in comp.upcomingReverse(before: time, within: horizon) where up.isVisible {
                guard let lane = lane(for: up, fps: comp.fps) else { continue }
                lane.request(frame: up.endFrame - 1, ahead: 0, behind: behind, size: decodeSize(up, scale: s, backing: context.backingScale))
                used.insert(lane.key)
            }
        }
        for (k, lane) in lanes where !used.contains(k) { lane.stop(); lanes[k] = nil }
        lastShown = shown; cache.fitBudget(); grader.fitBudget()   // the caches count drawables this draw made
        standIns.keepOnly(Set(shown.filter { $0.frame != nil }.map(\.clipId)))   // inactive clips keep no stand-in

        // Element clips (no media of their own) keep their labelled box; video/image clips whose file is missing
        // were drawn above as offline slates.
        let mediaIds = Set(layers.map(\.clipId))
        let rest = elements.filter { !mediaIds.contains($0.id) && $0.kind == .element }
        if !rest.isEmpty { PlaceholderFrameSource.drawBoxes(c, rest) }
    }

    /// After `pick` was drawn for `layer`: counts a stand-in, keeps the clip's last picture and the lane it drew from.
    func drew(_ pick: Picture, for layer: PreviewLayer) {
        if !pick.exact { heldFrames += 1 }
        standIns.store(pick, clip: layer.clipId)
        // A picture from the clip's earlier lane bridges a trim or retime until its own lane draws.
        if pick.lane == layer.laneKey { shownLane[layer.clipId] = layer.laneKey }
    }

    /// What a media layer draws for frame `want`: the exact frame, else the nearest cached frame of its lane, else a
    /// stand-in from `standIn`. Never waits for a decoder.
    func picture(for layer: PreviewLayer, want: Int) -> Picture? {
        if let image = cache.frame(lane: layer.laneKey, frame: want) {
            return Picture(image: image, frame: want, lane: layer.laneKey, exact: true)
        }
        if let held = cache.nearest(lane: layer.laneKey, to: want) {
            return Picture(image: held.image, frame: held.frame, lane: layer.laneKey, exact: false)
        }
        return standIn(for: layer, want: want)
    }

    /// A picture for a layer whose lane has nothing cached: the frames of the lane the clip drew from before (a trim or
    /// retime starts a new lane), else the last picture the clip drew. Never exact: the exact frame replaces it.
    func standIn(for layer: PreviewLayer, want: Int) -> Picture? {
        if let prev = shownLane[layer.clipId], prev != layer.laneKey {
            if let image = cache.frame(lane: prev, frame: want) {
                return Picture(image: image, frame: want, lane: prev, exact: false)
            }
            if let held = cache.nearest(lane: prev, to: want) {
                return Picture(image: held.image, frame: held.frame, lane: prev, exact: false)
            }
        }
        guard var last = standIns.picture(layer.clipId) else { return nil }
        last.exact = false
        return last
    }

    /// Compare is a presentation-only wipe. Both halves use the same cached decoded image; only the right half
    /// asks `PreviewGrader` for the current look, so moving the divider cannot create or restart a decode lane.
    func draw(_ layer: PreviewLayer, raw: CanvasImage, shown: CanvasImage, shownIsCurrent: Bool = true,
              on c: CanvasContext, frame: CanvasRect, scale: Double, context: FrameDrawContext) {
        guard context.compareClipId == layer.clipId else {
            PreviewPainter.draw(layer, image: shown, on: c, frame: frame, scale: scale); return
        }
        let split = frame.x + frame.width * max(0, min(1, context.comparePosition))
        // A completed grade from a previous request is useful during normal playback, but must never be paired
        // with a different raw source frame in Compare. Until this frame's grade completes, show it raw on both sides.
        let after = shownIsCurrent ? shown : raw
        // The wipe is clipped on `c`; a blend reads the whole canvas back, so the compared clip draws unblended.
        var plain = layer; plain.blend = .normal
        c.withState {
            c.clip(CanvasRect(x: frame.x, y: frame.y, width: max(0, split - frame.x), height: frame.height))
            PreviewPainter.draw(plain, image: raw, on: c, frame: frame, scale: scale)
        }
        c.withState {
            c.clip(CanvasRect(x: split, y: frame.y, width: max(0, frame.maxX - split), height: frame.height))
            PreviewPainter.draw(plain, image: after, on: c, frame: frame, scale: scale)
        }
    }

    /// The raster surface a blended frame is painted on: `rect` in device pixels, kept while the size is unchanged.
    func blendCanvas(_ rect: CanvasRect, backing: Double) -> RasterCanvas? {
        let w = max(1, Int((rect.width * max(backing, 1)).rounded())), h = max(1, Int((rect.height * max(backing, 1)).rounded()))
        if let canvas = blendSurface, canvas.surface.width == w, canvas.surface.height == h { return canvas }
        blendSurface = try? RasterCanvas(width: w, height: h)
        return blendSurface
    }

    func decodeSize(_ layer: PreviewLayer, scale s: Double, backing: Double) -> PreviewDecodeSize {
        PreviewDecodeSize.fitting(PreviewPainter.screenPixels(layer, viewScale: s, backingScale: backing), maxSide: maxDecodeSide)
    }

    /// Frames to decode past the playhead per clip: about a third of a second, bounded by the cache budget.
    func lookahead(_ layers: [PreviewLayer], comp: PreviewComposition, scale s: Double, backing: Double, speed: Double) -> Int {
        let videos = layers.filter { $0.kind == .video && !$0.isStill && $0.isVisible }
        guard !videos.isEmpty else { return 0 }
        let bytes = videos.reduce(0) { acc, l in let d = decodeSize(l, scale: s, backing: backing); return acc + d.width * d.height * 4 }
        let byBudget = cache.budgetBytes / 2 / max(bytes, 1)
        let byTime = Int((comp.fps / 3 * max(1, speed)).rounded(.up))
        return max(0, min(maxLookahead, byTime, byBudget))
    }

    /// Frames per reverse chunk: about two thirds of a second of playback, bounded by the cache budget.
    func reverseChunk(_ layers: [PreviewLayer], comp: PreviewComposition, scale s: Double, backing: Double, speed: Double) -> Int {
        let videos = layers.filter { $0.kind == .video && !$0.isStill && $0.isVisible }
        guard !videos.isEmpty else { return 1 }
        let bytes = videos.reduce(0) { acc, l in let d = decodeSize(l, scale: s, backing: backing); return acc + d.width * d.height * 4 }
        let byBudget = cache.budgetBytes / 3 / max(bytes, 1)
        let byTime = Int((comp.fps * 2 / 3 * max(1, speed)).rounded(.up))
        return max(0, min(maxReverseChunk, byTime, byBudget))
    }
    /// Upper bound for one reverse chunk per clip.
    public var maxReverseChunk = 48

    func lane(for layer: PreviewLayer, fps: Double) -> PreviewDecodeLane? {
        guard decodesMedia, !layer.isProcedural, layer.kind != .offline else { return nil }
        if let l = lanes[layer.laneKey] { return l }
        let l = PreviewDecodeLane(layer: layer, fps: fps, cache: cache)
        l.onFrame = { [weak self] in self?.frameReady?() }
        lanes[layer.laneKey] = l
        laneClip[layer.laneKey] = layer.clipId
        return l
    }

    /// Live stage edits (a drag in progress) override the document's box, rotation and crop until committed.
    /// `elements` are in view coordinates; their rects map back to composition px through `frame` and `scale`.
    public static func applyStage(_ elements: [StageElement], to layers: [PreviewLayer], frame: CanvasRect, scale s: Double) -> [PreviewLayer] {
        guard !elements.isEmpty, s > 0 else { return layers }
        let byId = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return layers.map { layer in
            guard let e = byId[layer.clipId] else { return layer }
            var l = layer
            // The stage rect already includes layout.left/top (StageGeometry.baseRect: the media's box), so it maps
            // straight to the layer box; adding the layout origin again drew a grabbed clip offset by it.
            l.box = CanvasRect(x: (e.rect.x - frame.x) / s, y: (e.rect.y - frame.y) / s,
                               width: e.rect.width / s, height: e.rect.height / s)
            l.rotation = e.rotation + layer.motionRotation
            l.crop = CropInsets(top: e.crop.top / s, right: e.crop.right / s, bottom: e.crop.bottom / s, left: e.crop.left / s)
            if let o = e.opacity { l.opacity = max(0, min(1, o)) }
            if let k = e.scale { l.scaleX = k; l.scaleY = k }
            return l
        }
    }

    /// What to draw for a raw decoded frame: its graded look when that is finished, else the clip's latest finished
    /// look (and the current one is requested), else the raw frame until the first look is graded. Never blocks.
    /// Video frames are graded at their own frame's time, stills at the frame being shown; the picture is graded at
    /// `target` (its screen footprint) when the decoded frame is larger.
    func shownImage(_ layer: PreviewLayer, _ image: CanvasImage, frame: Int, time: Double, fps: Double, target: PreviewDecodeSize,
                    lane: String? = nil) -> (image: CanvasImage, grade: String?, current: Bool) {
        guard let g = layer.grade, g.isActive, image.width > 0, image.height > 0 else { return (image, nil, true) }
        let shownFrame = layer.isStill ? Int((time * fps + 1e-6).rounded(.down)) : frame
        let fit = target.containing(aspect: Double(image.width) / Double(image.height))
        let reduce = image.width * 10 > fit.width * 11 || image.height * 10 > fit.height * 11
        let gw = reduce ? fit.width : image.width, gh = reduce ? fit.height : image.height
        let sourceKey = "\(lane ?? layer.laneKey)|\(frame)|\(image.width)x\(image.height)>\(gw)x\(gh)"
        let key = "\(sourceKey)|\(g.signature)|\(shownFrame)"
        if let r = grader.latest(layer.clipId), r.key == key { return (r.image, r.signature, true) }
        grader.request(layer.clipId, PreviewGrader.Request(key: key, sourceKey: sourceKey, image: image,
                                                           target: reduce ? PreviewDecodeSize(width: gw, height: gh) : nil,
                                                           grade: g, time: Double(shownFrame) / fps))
        if let r = grader.latest(layer.clipId) { return (r.image, r.signature, r.key == key) }
        return (image, nil, false)
    }

    /// `image` graded now on the calling thread at its own size (stills, thumbnails, tests).
    public func graded(_ layer: PreviewLayer, _ image: CanvasImage, frame: Int, time: Double, fps: Double) -> CanvasImage {
        guard let g = layer.grade, g.isActive else { return image }
        let shownFrame = layer.isStill ? Int((time * fps + 1e-6).rounded(.down)) : frame
        gradedNow += 1
        return grader.gradeNow(image, grade: g, time: Double(shownFrame) / fps)
    }

    /// Synchronous decode of one layer's frame at `time`, graded as the preview draws it (tests, stills for
    /// thumbnails). Blocks the caller.
    public func decodeNow(_ layer: PreviewLayer, time: Double, fps: Double, size: PreviewDecodeSize) -> CanvasImage? {
        guard let raw = decodeRawNow(layer, time: time, fps: fps, size: size) else { return nil }
        return graded(layer, raw.image, frame: raw.frame, time: time, fps: fps)
    }

    /// The decoded frame before grading, and the frame index it is.
    public func decodeRawNow(_ layer: PreviewLayer, time: Double, fps: Double, size: PreviewDecodeSize) -> (frame: Int, image: CanvasImage)? {
        guard let lane = lane(for: layer, fps: fps) else { return nil }
        let f = layer.isStill ? PreviewDecodeLane.stillFrame : Int((time * fps + 1e-6).rounded(.down))
        lane.request(frame: f, ahead: 0, size: size)
        lane.wait()
        let clamped = layer.isStill ? f : max(layer.startFrame, min(layer.endFrame - 1, f))
        if let img = cache.frame(lane: layer.laneKey, frame: clamped) { return (clamped, img) }
        return cache.frame(lane: layer.laneKey, frame: f).map { (f, $0) }
    }

    /// Ends every decoder (closing the project, tests).
    public func stopAll() { for l in lanes.values { l.stop() }; lanes = [:]; grader.waitUntilIdle(); grader.removeAll() }
}
