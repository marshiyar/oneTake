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
import MpvfxCanvas
import MpvfxShared

extension TimelineController {
    /// Sample the audio clock at the key/button event, even between video refreshes.
    public var beatEventTime: Double {
        if playback.wantsExternalClock, let time: Double = playback.externalClock?(), time.isFinite {
            return time
        }
        return playback.currentTime
    }
    /// The sole selected audio clip; other selection shapes cannot author beats.
    public var selectedBeatClipId: String? {
        guard view.selection.count == 1, let identifier = view.selection.first, let (_, model) = clip(identifier),
            model.kind == .audio
        else {
            return nil
        }
        return identifier
    }
    /// Whether the selected audio clip can accept a mark at the current audio-clock time.
    public var canAddSelectedBeat: Bool {
        guard let id = selectedBeatClipId else {
            return false
        }
        return editor?.canAddBeat(clipId: id, at: beatEventTime) == true
    }

    /// Persist one tapped mark on the selected audio clip.
    @discardableResult
    public func addSelectedBeat() -> Bool {
        guard let id = selectedBeatClipId else {
            return false
        }
        return editor?.addBeat(clipId: id, at: beatEventTime) == true
    }
    /// Seek to the strictly previous or next visible beat.
    @discardableResult
    public func jumpBeat(forward: Bool) -> Bool {
        let time: Double = beatEventTime
        let times: [Double] = view.beats.map(\.time).sorted()
        let next =
            forward
            ? times.first { $0 > time + Self.beatNavigationEpsilon }
            : times.last { $0 < time - Self.beatNavigationEpsilon }
        guard let next else {
            return false
        }
        playback.seek(next)
        syncFromPlayback()
        return true
    }
}

extension TimelineController {
    /// Seconds: ignore numerical noise when choosing a strictly previous/next mark.
    private static let beatNavigationEpsilon: Double = 1e-6
    /// View pixels: pointer tolerance for a two-pixel beat marker.
    private static let beatHitRadiusPixels: Double = 5.0

    internal func beatSnapTimes(excluding clipIds: Set<String>) -> [Double] {
        view.beats.filter { beat in
            guard let clipId = beat.clipId else {
                return true
            }
            return !clipIds.contains(clipId)
        }.map(\.time)
    }

    internal func beatPointerDown(x pointerX: Double, y pointerY: Double, alt: Bool) -> Bool {
        guard let editor else {
            return false
        }
        for (row, track) in view.tracks.enumerated() where !track.locked {
            for clip in track.clips where clip.kind == .audio {
                let rect: CanvasRect = view.clipRect(track: row, clip)
                guard pointerY >= rect.y, pointerY <= rect.maxY else {
                    continue
                }
                guard let (_, model) = editor.clip(clip.id),
                    let beat = model.visibleBeatFrames.min(by: {
                        abs(view.x(for: $0.timeline / editor.fps) - pointerX)
                            < abs(view.x(for: $1.timeline / editor.fps) - pointerX)
                    }),
                    abs(view.x(for: beat.timeline / editor.fps) - pointerX) <= Self.beatHitRadiusPixels
                else {
                    continue
                }
                if alt {
                    _ = editor.editBeat(clipId: clip.id, sourceFrame: beat.source, to: nil)
                } else {
                    beatDrag = (clip.id, beat.source, beat.timeline / editor.fps)
                    view.selection = [clip.id]
                    if view.selectedKeyframes.contains(where: { $0.clipId != clip.id }) {
                        view.selectedKeyframes = []
                    }
                }
                needsDisplay?()
                return true
            }
        }
        return false
    }
}
