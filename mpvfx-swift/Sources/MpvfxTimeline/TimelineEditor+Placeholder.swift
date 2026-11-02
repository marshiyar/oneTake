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
    /// Marks a media clip as a placeholder: a slot a project template fills with media. It takes the lowest free
    /// number. One undo step. Text, shapes and generated pictures are not media and are refused.
    @discardableResult
    func markPlaceholder(clipId: String) -> Bool {
        lastFailure = nil
        guard let (track, clip) = clip(clipId) else {
            lastFailure = .init(code: .missingClip, message: "The clip is no longer available"); return false
        }
        guard track.locked != true else { lastFailure = .init(code: .documentMismatch, message: "Track is locked"); return false }
        guard clip.placeholder == nil else {
            lastFailure = .init(code: .documentMismatch, message: "This clip is already a placeholder"); return false
        }
        guard let kind = document.assets.first(where: { $0.id == clip.assetId })?.kind, kind != .element else {
            lastFailure = .init(code: .incompatibleDestination, message: "Only a clip of video, sound or a picture can be a placeholder"); return false
        }
        let taken = Set(document.unfilledPlaceholderNumbers)
        var number = 1
        while taken.contains(number) { number += 1 }
        var d = document
        guard let ti = d.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let ci = d.sequence.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        d.sequence.tracks[ti].clips[ci].placeholder = NativeClipPlaceholder(index: number)
        return commit(d, "Mark as placeholder")
    }

    /// Takes the placeholder marker off a clip, keeping its media. One undo step.
    @discardableResult
    func clearPlaceholder(clipId: String) -> Bool {
        lastFailure = nil
        guard let (track, clip) = clip(clipId) else {
            lastFailure = .init(code: .missingClip, message: "The clip is no longer available"); return false
        }
        guard track.locked != true else { lastFailure = .init(code: .documentMismatch, message: "Track is locked"); return false }
        guard clip.placeholder?.isCurrentVersion == true else { return false }
        var d = document
        guard let ti = d.sequence.tracks.firstIndex(where: { $0.id == track.id }),
              let ci = d.sequence.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        d.sequence.tracks[ti].clips[ci].placeholder = nil
        return commit(d, "Unmark placeholder")
    }
}
