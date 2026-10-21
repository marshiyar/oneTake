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
import MpvfxPanels
import MpvfxShared

/// Effects catalog tiles on the clip: the selected clip's frame (the same source lookup, queue, cache and budget as the
/// Grade preset tiles) graded with a tile's grade JSON, which is the clip's own grade plus the effect or look.
extension PresetPreviewRenderer {
    /// The frame of `req.clipId` at `time` graded with `req.grade`, at most the request's size. `req.key` names the
    /// tile ("fx:blur"): a newer request for it drops an older one still queued. `.unavailable` when the request
    /// names no clip, the clip has no picture or its media could not be decoded, and for a size outside
    /// 2…`EffectPreviewRenderer.maxSide` (the host then shows the sample picture, or its typed size failure). Call on
    /// the UI thread.
    public func effectPreview(_ req: EffectPreviewRequest, time: Double) -> State {
        let slot = req.key, grade = req.grade, pixelWidth = req.pixelWidth, pixelHeight = req.pixelHeight
        let sizes = 2...EffectPreviewRenderer.maxSide
        guard sizes.contains(pixelWidth), sizes.contains(pixelHeight), let clipId = req.clipId,
              let found = decodableEntry(clipId) else { return .unavailable }
        let comp: PreviewComposition = found.comp, entry: PreviewComposition.Entry = found.entry
        let c = entry.clip
        let first = c.startFrame / comp.fps, last = (c.startFrame + max(1, c.durationFrames) - 1) / comp.fps
        let t = max(first, min(last, time))
        let layer = comp.layer(entry, at: t)
        let want = layer.isStill ? PreviewDecodeLane.stillFrame : max(layer.startFrame, min(layer.endFrame - 1, comp.frameIndex(at: t)))
        guard let source = sourceFrame(layer, want: want, fps: comp.fps, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return compositor.decodesMedia && !decodeGaveUp(lane: layer.laneKey) ? .rendering : .unavailable
        }
        let shownFrame = layer.isStill ? comp.frameIndex(at: t) : source.frame
        let key = Key(lane: layer.laneKey, frame: source.frame, preset: "\(slot)|\(shownFrame)|\(EffectPreviewRenderer.gradeText(grade))",
                      lut: "", width: pixelWidth, height: pixelHeight)
        if let hit = cachedOrQueue(key, slot: slot) { return hit }
        let dir = projectDir(), renderer = colorRenderer, gradeTime = Double(shownFrame) / comp.fps
        queue.async { [weak self] in
            self?.render(key, slot: slot, raw: source.image, time: gradeTime, renderer: renderer) {
                ColorGradeRenderer.forClip(ColorGradeParams(json: grade), clipId: clipId, projectDir: dir)
            }
        }
        return .rendering
    }

    /// Whether the lane that would decode `lane`'s frames (the preview's own, else this renderer's) gave up before
    /// producing any picture: missing, unreadable or undecodable media. Such a tile waits for nothing.
    func decodeGaveUp(lane: String) -> Bool {
        if let l = compositor.lanes[lane] { return l.gaveUp }
        return ownLane?.key == lane && ownLane?.gaveUp == true
    }

    /// Whether `clipId`'s picture can never arrive because its media gave up decoding (the Grade preset tiles' host
    /// then falls back to the sample picture instead of showing "Rendering" forever). An offline clip (its media
    /// file is missing) has given up without decoding. Call on the UI thread.
    public func decodeGaveUp(clipId: String) -> Bool {
        guard let comp = compositor.composition, let e = comp.entries.first(where: { $0.clip.id == clipId }) else { return false }
        return e.kind == .offline || decodeGaveUp(lane: comp.layer(e, at: e.clip.startFrame / comp.fps).laneKey)
    }

    /// The cached tile for `key`, or nil after marking it the newest for `slot` and queueing it (`.rendering` when it
    /// is already queued).
    func cachedOrQueue(_ key: Key, slot: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        latest[slot] = key
        if let hit = images[key] {
            tick += 1; images[key] = (hit.image, tick)
            return .ready(hit.image)
        }
        return pending.insert(key).inserted ? nil : .rendering
    }
}
