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

public extension TimelineEditor {
    /// Swap only the source reference. Authored geometry, animation and effects remain on the clip;
    /// an untouched box follows the replacement asset's natural size. A new asset and the swap undo together.
    @discardableResult
    func replaceMedia(clipId: String, asset: NativeProjectAsset) -> Bool {
        lastFailure = nil
        guard let (track, original) = clip(clipId) else {
            lastFailure = .init(code: .missingClip, message: "The clip is no longer available"); return false
        }
        guard track.locked != true else {
            lastFailure = .init(code: .documentMismatch, message: "Track is locked"); return false
        }
        guard let previous = document.assets.first(where: { $0.id == original.assetId }),
              previous.kind != .element, asset.kind != .element,
              (previous.kind == .audio) == (asset.kind == .audio) else {
            lastFailure = .init(code: .incompatibleDestination, message: "Replace sound with sound, or a picture with a picture"); return false
        }
        guard original.assetId != asset.id else { return false }
        guard original.speedRamp?.isSupported != false, original.holdSourceFrame?.isCurrentVersion != false else {
            lastFailure = .init(code: .documentMismatch, message: "This clip uses a newer media time mapping"); return false
        }
        do {
            let missing = try replacementMissingFrames(original, asset)
            guard missing <= 0 else {
                lastFailure = .init(code: .invalidTrim, message: "Replacement media is too short: missing \(String(format: "%.0f", missing)) source frames"); return false
            }
        } catch {
            lastFailure = .init(code: .invalidTrim, message: "Replacement media time is out of range"); return false
        }
        var d = document
        if let existing = d.assets.first(where: { $0.id == asset.id }) {
            guard existing == asset else {
                lastFailure = .init(code: .documentMismatch, message: "Replacement asset changed"); return false
            }
        } else { d.assets.append(asset) }
        guard let ti = d.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let ci = d.sequence.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        d.sequence.tracks[ti].clips[ci].assetId = asset.id
        return commit(d, "Replace media")
    }

    private func replacementMissingFrames(_ clip: NativeProjectClip, _ asset: NativeProjectAsset) throws -> Double {
        guard asset.durationFrames.isFinite, asset.durationFrames > 0 else {
            throw NativeProjectClipFailure(code: .invalidTrim, message: "Invalid replacement duration")
        }
        if asset.kind == .image { return 0 } // still images can fill any timeline duration
        if let held = clip.holdSourceFrame?.sourceFrame { return max(0, held + 1 - asset.durationFrames).rounded(.up) }
        let start = NativeSourcePosition(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction)
        if let ramp = clip.speedRamp {
            return max(0, sourceFrameValue(start) + ramp.sourcePosition(atClipFrame: clip.durationFrames) - asset.durationFrames).rounded(.up)
        }
        if try sourceRangeFits(start, playbackRate: clip.playbackRate, durationFrames: clip.durationFrames,
                               sourceDurationFrames: asset.durationFrames) { return 0 }
        let end = try advanceSourcePosition(start, playbackRate: clip.playbackRate, timelineFrames: clip.durationFrames)
        return max(1, (sourceFrameValue(end) - asset.durationFrames).rounded(.up))
    }
}
