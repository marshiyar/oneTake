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
// Hand-placed beat marks retained in the original media time.
import Foundation
import MpvfxShared

public extension TimelineController {
    /// Sample the audio clock at the key/button event, even between video refreshes.
    var beatEventTime: Double {
        if playback.wantsExternalClock, let time = playback.externalClock?(), time.isFinite { return time }
        return playback.currentTime
    }
    var selectedBeatClipId: String? {
        guard view.selection.count == 1, let id = view.selection.first, let (_, c) = clip(id), c.kind == .audio else { return nil }
        return id
    }
    var canAddSelectedBeat: Bool {
        guard let id = selectedBeatClipId else { return false }
        return editor?.canAddBeat(clipId: id, at: beatEventTime) == true
    }
    @discardableResult func addSelectedBeat() -> Bool {
        guard let id = selectedBeatClipId else { return false }
        return editor?.addBeat(clipId: id, at: beatEventTime) == true
    }
    @discardableResult func jumpBeat(forward: Bool) -> Bool {
        let time = beatEventTime
        let times = view.beats.map(\.time).sorted()
        let next = forward ? times.first { $0 > time + 1e-6 } : times.last { $0 < time - 1e-6 }
        guard let next else { return false }
        playback.seek(next); syncFromPlayback(); return true
    }
}

extension TimelineController {
    func beatPointerDown(x: Double, y: Double, alt: Bool) -> Bool {
        guard let editor else { return false }
        for (row, track) in view.tracks.enumerated() where !track.locked {
            for clip in track.clips where clip.kind == .audio {
                let rect = view.clipRect(track: row, clip)
                guard y >= rect.y, y <= rect.maxY else { continue }
                guard let (_, model) = editor.clip(clip.id),
                      let beat = model.visibleBeatFrames.min(by: { abs(view.x(for: $0.timeline / editor.fps) - x) < abs(view.x(for: $1.timeline / editor.fps) - x) }),
                      abs(view.x(for: beat.timeline / editor.fps) - x) <= 5 else { continue }
                if alt { _ = editor.editBeat(clipId: clip.id, sourceFrame: beat.source, to: nil) }
                else { beatDrag = (clip.id, beat.source, beat.timeline / editor.fps); view.selection = [clip.id] }
                needsDisplay?(); return true
            }
        }
        return false
    }
}
