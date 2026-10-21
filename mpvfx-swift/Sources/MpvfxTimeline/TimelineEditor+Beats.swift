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

extension TimelineEditor {
    /// Whether a source-frame mark can be added at this composition time.
    public func canAddBeat(clipId: String, at time: Double) -> Bool {
        guard let clip = editableBeatClip(clipId), let source = beatSourceFrame(clip, at: time) else {
            return false
        }
        return !(clip.beats?.frames ?? []).contains(source)
    }

    /// Add a mark through the document's validated, undoable audio edit path.
    @discardableResult
    public func addBeat(clipId: String, at time: Double) -> Bool {
        guard let clip = editableBeatClip(clipId), let source = beatSourceFrame(clip, at: time) else {
            return false
        }
        var beats: NativeClipBeats = clip.beats ?? NativeClipBeats(frames: [])
        let frames: [Double] = beats.frames
        guard !frames.contains(source) else {
            return false
        }
        beats.frames = (frames + [source]).sorted()
        return storeBeats(beats, clipId: clipId, label: "Add beat")
    }

    /// Move a source-frame mark, or delete it when the composition time is absent.
    @discardableResult
    public func editBeat(clipId: String, sourceFrame: Double, to time: Double?) -> Bool {
        guard let clip = editableBeatClip(clipId), var beats = clip.beats,
            framesContain(beats, sourceFrame: sourceFrame)
        else {
            return false
        }
        let frames: [Double] = beats.frames

        guard let time else {
            beats.frames = frames.filter { $0 != sourceFrame }
            return storeBeats(beats, clipId: clipId, label: "Delete beat")
        }
        guard let target = beatSourceFrame(clip, at: time), target != sourceFrame,
            !frames.contains(target)
        else {
            return false
        }
        beats.frames = (frames.filter { $0 != sourceFrame } + [target]).sorted()
        return storeBeats(beats, clipId: clipId, label: "Move beat")
    }
}

extension TimelineEditor {
    private func framesContain(_ beats: NativeClipBeats, sourceFrame: Double) -> Bool {
        beats.frames.contains(sourceFrame)
    }

    private func editableBeatClip(_ clipId: String) -> NativeProjectClip? {
        guard !isClipLocked(clipId), let (_, clip) = clip(clipId),
            document.assets.first(where: { $0.id == clip.assetId })?.kind == .audio,
            clip.beats?.isSupported != false, clip.speedRamp?.isSupported != false
        else {
            return nil
        }
        return clip
    }

    private func beatSourceFrame(_ clip: NativeProjectClip, at time: Double) -> Double? {
        let frame: Double = time * fps
        guard time.isFinite, frame >= clip.startFrame, frame < clip.startFrame + clip.durationFrames else {
            return nil
        }
        let source: Double = clip.beatSourceFrame(atTimelineFrame: frame).rounded()
        guard let length = document.assets.first(where: { $0.id == clip.assetId })?.durationFrames,
            source < length, clip.beatTimelineFrame(sourceFrame: source) != nil
        else {
            return nil
        }
        return source
    }

    private func storeBeats(_ beats: NativeClipBeats, clipId: String, label: String) -> Bool {
        updateAudioClip(clipId, label) { clip in
            clip.beats = !beats.frames.isEmpty ? beats : nil
        }
    }
}
