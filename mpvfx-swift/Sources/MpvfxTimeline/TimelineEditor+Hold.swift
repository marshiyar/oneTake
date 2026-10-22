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

/// Hold frame (⇧H insert, ⌥⇧H overwrite): the frame of a video clip under the playhead held for a length, as one
/// undo step (`planNativeTimelineHold`).
public extension TimelineEditor {
    /// The default hold length (Settings), in seconds.
    static let defaultHoldSeconds = 2.0

    /// `seconds` as whole frames at the project rate, rounded half to even (a duration), at least one frame; nil
    /// when `seconds` is not a positive finite number.
    func holdFrames(seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return max(1, (seconds * fps).rounded(.toNearestOrEven))
    }

    /// The clip whose frame ⇧H holds at timeline `frame`: a selected video clip under the playhead, else the video
    /// clip drawn on top there. Nil when no video clip is under the playhead.
    func holdTarget(atFrame frame: Double, selection: Set<String>) -> NativeProjectClipAddress? {
        let video = Set(document.assets.filter { $0.kind == .video }.map(\.id))
        let layers = nativeTrackStackingLayers(document.sequence.tracks)
        var under: [(address: NativeProjectClipAddress, layer: Double)] = []
        for (i, track) in document.sequence.tracks.enumerated() {
            for c in track.clips where video.contains(c.assetId) && c.startFrame <= frame && frame < c.startFrame + c.durationFrames {
                under.append((.init(sequenceId: sequenceId, trackId: track.id, clipId: c.id), layers[i]))
            }
        }
        if let chosen = under.first(where: { selection.contains($0.address.clipId) }) { return chosen.address }
        return under.max(by: { $0.layer < $1.layer })?.address
    }

    /// Holds the frame of `clipId` under timeline `frame` for `lengthFrames`: inserted (the rest of the track moves
    /// later) or, with `overwrite`, over what follows. Refused on a locked track. Returns the hold clip's id; nil when
    /// refused, with `lastFailure` saying why.
    @discardableResult
    func holdFrame(clipId: String, atFrame frame: Double, lengthFrames: Double, overwrite: Bool) -> String? {
        guard let a = address(clipId: clipId) else {
            lastFailure = .init(code: .missingClip, message: "Clip \(clipId) is not in the project"); return nil
        }
        guard !isTrackLocked(a.trackId) else { lastFailure = .init(code: .documentMismatch, message: "Track is locked"); return nil }
        let request = NativeTimelineHoldRequest(address: a, frame: frame, lengthFrames: lengthFrames, mode: overwrite ? .overwrite : .insert)
        let before = document
        do {
            switch try planNativeTimelineHold(document, request, engine: engine) {
            case .failure(let f):
                lastFailure = .init(code: .documentMismatch, message: f.message); return nil
            case .success(let plan):
                withHistory(overwrite ? "Overwrite with hold frame" : "Hold frame") {
                    replaceDocument(plan.document, inverse: .restoreDocument(before))
                }
                lastFailure = nil
                return plan.holdClipId
            }
        } catch {
            // Only a non-validation engine error reaches here (rejections return .failure above).
            lastFailure = .init(code: .documentMismatch, message: "The hold frame could not be added."); return nil
        }
    }
}
