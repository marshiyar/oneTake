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

public extension TimelineEditor {
    func canAddBeat(clipId: String, at time: Double) -> Bool {
        guard time.isFinite, !isClipLocked(clipId), let (_, c) = clip(clipId),
              document.assets.first(where: { $0.id == c.assetId })?.kind == .audio,
              c.beats?.isSupported != false, c.speedRamp?.isSupported != false, time * fps >= c.startFrame, time * fps < c.startFrame + c.durationFrames else { return false }
        let source = c.beatSourceFrame(atTimelineFrame: time * fps).rounded()
        guard let length = document.assets.first(where: { $0.id == c.assetId })?.durationFrames, source < length, c.beatTimelineFrame(sourceFrame: source) != nil else { return false }
        return !(c.beats?.frames ?? []).contains(source)
    }
    @discardableResult func addBeat(clipId: String, at time: Double) -> Bool {
        guard canAddBeat(clipId: clipId, at: time), let (_, c) = clip(clipId) else { return false }
        let source = c.beatSourceFrame(atTimelineFrame: time * fps).rounded()
        return updateAudioClip(clipId, "Add beat") { clip in
            var beats = clip.beats ?? NativeClipBeats(frames: [])
            beats.frames = ((beats.frames ?? []) + [source]).sorted(); clip.beats = beats
        }
    }
    @discardableResult func editBeat(clipId: String, sourceFrame: Double, to time: Double?) -> Bool {
        guard let (_, c) = clip(clipId), c.beats?.isSupported == true,
              var beats = c.beats, beats.isSupported, let frames = beats.frames, frames.contains(sourceFrame) else { return false }
        var replacement: Double?
        if let time {
            guard time.isFinite, time * fps >= c.startFrame, time * fps < c.startFrame + c.durationFrames else { return false }
            let target = c.beatSourceFrame(atTimelineFrame: time * fps).rounded()
            guard let length = document.assets.first(where: { $0.id == c.assetId })?.durationFrames,
                  target < length, c.beatTimelineFrame(sourceFrame: target) != nil,
                  target == sourceFrame || !frames.contains(target) else { return false }
            replacement = target
        }
        guard replacement != sourceFrame else { return false }
        var updated = frames.filter { $0 != sourceFrame }
        if let replacement { updated.append(replacement); updated.sort() }
        beats.frames = updated
        return updateAudioClip(clipId, time == nil ? "Delete beat" : "Move beat") { clip in
            clip.beats = updated.isEmpty ? nil : beats
        }
    }
}
