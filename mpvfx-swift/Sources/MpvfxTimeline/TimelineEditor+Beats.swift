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
// Beat marks (hand-placed and analysed) retained in the original media time.
import Foundation
import MpvfxShared

extension TimelineEditor {
    /// Whether a source-frame mark can be added at this composition time.
    public func canAddBeat(clipId: String, at time: Double) -> Bool {
        guard let clip = editableBeatClip(clipId), let source = beatSourceFrame(clip, at: time) else {
            return false
        }
        return !(clip.beats?.allFrames ?? []).contains(source)
    }

    /// Add a mark through the document's validated, undoable audio edit path.
    @discardableResult
    public func addBeat(clipId: String, at time: Double) -> Bool {
        guard let clip = editableBeatClip(clipId), let source = beatSourceFrame(clip, at: time) else {
            return false
        }
        var beats: NativeClipBeats = clip.beats ?? NativeClipBeats(frames: [])
        let frames: [Double] = beats.frames
        guard !beats.allFrames.contains(source) else {
            return false
        }
        beats.frames = (frames + [source]).sorted()
        return storeBeats(beats, clipId: clipId, label: "Add beat")
    }

    /// Move a source-frame mark, or delete it when the composition time is absent. A mark found by analysis can be
    /// deleted, or moved, which makes it a hand-placed mark (a later analysis leaves it alone).
    @discardableResult
    public func editBeat(clipId: String, sourceFrame: Double, to time: Double?) -> Bool {
        guard let clip = editableBeatClip(clipId), var beats = clip.beats,
            beats.allFrames.contains(sourceFrame)
        else {
            return false
        }
        beats.frames = beats.frames.filter { $0 != sourceFrame }
        if var analysis = beats.analysis, let index = analysis.frames.firstIndex(of: sourceFrame) {
            analysis.frames.remove(at: index)
            if analysis.strengths.indices.contains(index) { analysis.strengths.remove(at: index) }
            beats.analysis = analysis
        }
        guard let time else {
            return storeBeats(beats, clipId: clipId, label: "Delete beat")
        }
        guard let target = beatSourceFrame(clip, at: time), target != sourceFrame,
            !(clip.beats?.allFrames ?? []).contains(target)
        else {
            return false
        }
        beats.frames = (beats.frames + [target]).sorted()
        return storeBeats(beats, clipId: clipId, label: "Move beat")
    }

    /// What an analysis of `clipId` needs to read: the audio file's project path and the slice of the media the clip
    /// plays, in seconds of the source. Nil for a clip that cannot hold beats (not audio, locked, or an unreadable
    /// beat version or speed ramp) or whose asset has no file.
    public func beatAnalysisSource(clipId: String) -> TimelineBeatAnalysisSource? {
        guard let clip = editableBeatClip(clipId),
            let asset = document.assets.first(where: { $0.id == clip.assetId }), let source = asset.source, !source.isEmpty
        else {
            return nil
        }
        let rate: Double = clip.playbackRate.map { $0.numerator / $0.denominator } ?? 1
        let start: Double = clip.sourceInFrame + (clip.sourceInFraction.map { $0.numerator / $0.denominator } ?? 0)
        return TimelineBeatAnalysisSource(
            clipId: clipId, assetSource: source, startSeconds: start / fps,
            durationSeconds: clip.durationFrames * rate / fps)
    }

    /// Replaces the clip's analysed marks with `marks` (seconds from the start of the media, with a 0...1 strength),
    /// leaving hand-placed marks alone, as one undo step. Marks that fall on the same frame keep the stronger one;
    /// marks past the end of the media are dropped. No marks clears the analysed ones. True when the marks are stored or
    /// already were (that adds no undo step); false when the clip cannot hold beats or a setting is out of range.
    @discardableResult
    public func replaceAnalysisBeats(
        clipId: String, marks: [(seconds: Double, strength: Double)], sensitivity: Double, every: Int
    ) -> Bool {
        guard let clip = editableBeatClip(clipId), sensitivity.isFinite, (0...1).contains(sensitivity),
            NativeBeatAnalysis.everyChoices.contains(Double(every)),
            let length = document.assets.first(where: { $0.id == clip.assetId })?.durationFrames
        else {
            return false
        }
        var byFrame: [Double: Double] = [:]
        for mark in marks where mark.seconds.isFinite && mark.seconds >= 0 {
            let frame: Double = (mark.seconds * fps).rounded()
            guard frame < length else {
                continue
            }
            let strength: Double = mark.strength.isFinite ? min(1, max(0, mark.strength)) : 0
            byFrame[frame] = max(byFrame[frame] ?? 0, strength)
        }
        var beats: NativeClipBeats = clip.beats ?? NativeClipBeats(frames: [])
        let frames: [Double] = byFrame.keys.sorted()
        beats.analysis = frames.isEmpty
            ? nil
            : NativeBeatAnalysis(
                frames: frames, strengths: frames.map { byFrame[$0] ?? 0 }, sensitivity: sensitivity, every: Double(every))
        if beats.analysis == clip.beats?.analysis {
            return true
        }
        return storeBeats(beats, clipId: clipId, label: "Find beats")
    }
}

/// The part of a clip's audio an analysis reads. A result is applied only if the clip still reads the same slice of the
/// same file, so a trim made while the analysis ran is never overwritten by it.
public struct TimelineBeatAnalysisSource: Equatable, Sendable {
    public var clipId: String
    /// The asset's `source`, relative to the project folder.
    public var assetSource: String
    public var startSeconds: Double
    public var durationSeconds: Double
}

extension TimelineEditor {
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
            clip.beats = !beats.frames.isEmpty || beats.analysis != nil ? beats : nil
        }
    }
}
