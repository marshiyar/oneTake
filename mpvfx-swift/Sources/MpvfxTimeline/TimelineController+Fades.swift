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
import MpvfxShared

/// The fade handles at a clip's top corners: a press on one starts a drag that sets the clip's fade-in or fade-out.
extension TimelineController {
    /// Clips with picture or sound can fade; titles and other elements have no fade.
    static func canFade(_ kind: TimelineClipKind) -> Bool { kind != .element }

    /// The fade handle under `(x, y)`: the clip, its row, the edge it fades and the pointer's distance from the end of
    /// the ramp (so a drag keeps the grab point).
    func fadeHandleHit(x: Double, y: Double) -> (clipId: String, row: Int, edge: TrimEdge, grab: Double)? {
        guard tool == .select, x >= TimelineLayout.contentOrigin else { return nil }
        let slop = TimelineView.fadeHandleSlop
        var best: (clipId: String, row: Int, edge: TrimEdge, grab: Double)?
        var bestDistance = Double.infinity
        for (row, track) in view.tracks.enumerated() {
            for clip in track.clips.reversed() where Self.canFade(clip.kind) {
                let r = view.clipRect(track: row, clip, preview: false)
                for edge in [TrimEdge.start, .end] {
                    let px = view.fadePixels(edge == .start ? clip.fadeIn : clip.fadeOut)
                    guard let h = TimelineView.fadeHandleRect(r, edge: edge, fadePx: min(px, r.width)) else { continue }
                    let hit = CanvasRect(x: max(r.x, h.x - slop), y: max(r.y, h.y - slop),
                                         width: min(r.maxX, h.maxX + slop) - max(r.x, h.x - slop),
                                         height: min(r.maxY, h.maxY + slop) - max(r.y, h.y - slop))
                    guard hit.contains(x: x, y: y) else { continue }
                    let apex = edge == .start ? r.x + min(px, r.width) : r.maxX - min(px, r.width)
                    let distance = abs(x - h.centerX)
                    if distance < bestDistance { bestDistance = distance; best = (clip.id, row, edge, x - apex) }
                }
            }
        }
        return best
    }

    /// A press on a fade handle selects its clip and starts the drag, except on a locked track, which only selects it
    /// (the way a trim handle is refused). True when the press was on a handle.
    func fadePointerDown(x: Double, y: Double) -> Bool {
        guard let h = fadeHandleHit(x: x, y: y) else { return false }
        view.selection = [h.clipId]
        if view.selectedKeyframes.contains(where: { $0.clipId != h.clipId }) { view.selectedKeyframes = [] }
        guard !view.tracks[h.row].locked else { needsDisplay?(); return true }
        gesture = .fade(clipId: h.clipId, edge: h.edge, grab: h.grab)
        cursor = .resize
        needsDisplay?()
        return true
    }

    /// The drag: the ramp's end follows the pointer, snapped when snapping is on, in whole frames from 0 up to the room
    /// the clip has (its length less the other fade).
    func fadeMove(clipId id: String, edge: TrimEdge, grab: Double, x: Double) {
        guard let editor, let (_, c) = clip(id) else { return }
        let fps = editor.fps
        let targets = snapEnabled ? TimelineSnapping.targets(clips: snapClips, playhead: playback.currentTime, beats: view.beats.map(\.time), excluding: [id]) : []
        let s = TimelineSnapping.snap(view.time(forX: x - grab), targets, thresholdSecs: TimelineSnapping.snapPx / max(view.pixelsPerSecond, 1))
        let seconds = edge == .start ? s.time - c.start : c.end - s.time
        let frames = min(max(0, (seconds * fps).rounded()), editor.maxFadeFrames(clipId: id, edge: edge))
        let snapped = s.target != nil && abs(frames / fps - seconds) < 0.5 / fps
        view.drag = .fade(clipId: id, edge: edge, seconds: frames / fps, snapTime: snapped ? s.target?.time : nil)
        view.snapType = snapped ? s.target?.type : nil
        needsDisplay?()
    }

    func commitFade(_ drag: TimelineDragPreview) {
        guard let editor, case let .fade(id, edge, seconds, _) = drag else { return }
        editor.setClipFade(clipId: id, edge: edge, frames: (seconds * editor.fps).rounded())
    }
}
