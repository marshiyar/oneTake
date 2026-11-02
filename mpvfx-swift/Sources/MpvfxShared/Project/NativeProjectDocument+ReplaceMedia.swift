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
// Swapping the media of a clip while keeping its edits, and filling a template's placeholders with it.
import Foundation

public extension NativeProjectDocument {
    /// The document with the clip's source swapped for `asset` and nothing else changed: trim length, offset, layout,
    /// grade, moves, keyframes and effects stay. A placeholder marker on the clip goes with the swap, because the slot
    /// is filled. `asset` is added to the document when it is new. Returns the document unchanged for the clip's own
    /// asset. Throws the reason when the swap is refused, with the frames missing when the media is too short.
    func replacingMedia(clipId: String, with asset: NativeProjectAsset) throws -> NativeProjectDocument {
        var located: (track: Int, clip: Int)?
        for (ti, track) in sequence.tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipId }) { located = (ti, ci); break }
        }
        guard let (ti, ci) = located else { throw NativeProjectClipFailure(code: .missingClip, message: "The clip is no longer available") }
        let original = sequence.tracks[ti].clips[ci]
        guard sequence.tracks[ti].locked != true else { throw NativeProjectClipFailure(code: .documentMismatch, message: "Track is locked") }
        guard let previous = assets.first(where: { $0.id == original.assetId }),
              previous.kind != .element, asset.kind != .element,
              (previous.kind == .audio) == (asset.kind == .audio) else {
            throw NativeProjectClipFailure(code: .incompatibleDestination, message: "Replace sound with sound, or a picture with a picture")
        }
        guard original.assetId != asset.id else { return self }
        guard original.speedRamp?.isSupported != false, original.holdSourceFrame?.isCurrentVersion != false else {
            throw NativeProjectClipFailure(code: .documentMismatch, message: "This clip uses a newer media time mapping")
        }
        do {
            let missing = try nativeReplacementMissingFrames(original, asset)
            guard missing <= 0 else {
                throw NativeProjectClipFailure(code: .invalidTrim, message: "Replacement media is too short: missing \(String(format: "%.0f", missing)) source frames")
            }
        } catch let failure as NativeProjectClipFailure {
            throw failure
        } catch {
            throw NativeProjectClipFailure(code: .invalidTrim, message: "Replacement media time is out of range")
        }
        var d = self
        if let existing = d.assets.first(where: { $0.id == asset.id }) {
            guard existing == asset else { throw NativeProjectClipFailure(code: .documentMismatch, message: "Replacement asset changed") }
        } else { d.assets.append(asset) }
        d.sequence.tracks[ti].clips[ci].assetId = asset.id
        if d.sequence.tracks[ti].clips[ci].staticParameters?.isEmpty == true {
            d.sequence.tracks[ti].clips[ci].staticParameters = nil
        }
        if d.sequence.tracks[ti].clips[ci].placeholder?.isCurrentVersion == true { d.sequence.tracks[ti].clips[ci].placeholder = nil }
        return d
    }

    /// The document with each placeholder in `fills` (placeholder number to media) filled by `replacingMedia`, and the
    /// assets only those placeholders used removed. Placeholders without media stay. All or nothing: the first refused
    /// swap throws and no part of the document changes. A number that names no placeholder throws.
    func fillingPlaceholders(_ fills: [Int: NativeProjectAsset]) throws -> NativeProjectDocument {
        var d = self
        var replaced = Set<String>()
        for number in fills.keys.sorted() {
            guard let clipId = d.sequence.tracks.flatMap(\.clips).first(where: { $0.placeholder?.number == number })?.id,
                  let asset = fills[number] else {
                throw NativeProjectClipFailure(code: .missingClip, message: "There is no placeholder \(number)")
            }
            if let previous = d.sequence.tracks.flatMap(\.clips).first(where: { $0.id == clipId })?.assetId { replaced.insert(previous) }
            d = try d.replacingMedia(clipId: clipId, with: asset)
        }
        let used = Set(d.sequence.tracks.flatMap(\.clips).map(\.assetId))
        d.assets.removeAll { replaced.contains($0.id) && !used.contains($0.id) }
        return d
    }
}

/// Source frames a clip needs beyond the end of `asset`; zero or less when `asset` is long enough.
func nativeReplacementMissingFrames(_ clip: NativeProjectClip, _ asset: NativeProjectAsset) throws -> Double {
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
