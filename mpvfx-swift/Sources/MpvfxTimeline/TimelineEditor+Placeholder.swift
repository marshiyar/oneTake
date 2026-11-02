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
    func markPlaceholder(clipId: String) -> Bool { markPlaceholders(clipIds: [clipId]) }

    /// Takes the placeholder marker off a clip, keeping its media. One undo step.
    @discardableResult
    func clearPlaceholder(clipId: String) -> Bool { clearPlaceholders(clipIds: [clipId]) }

    /// Marks every eligible clip of `clipIds` in one undo step, numbered in timeline order (start frame, then track).
    /// Clips that cannot be placeholders are left out; `lastFailure` names the first of them when nothing changes.
    @discardableResult
    func markPlaceholders(clipIds: [String]) -> Bool {
        lastFailure = nil
        var d = document
        var taken = Set(d.unfilledPlaceholderNumbers)
        var firstFailure: NativeProjectClipFailure?
        var eligible: [(track: Int, clip: Int)] = []
        for id in clipIds {
            guard let at = location(of: id, in: d) else {
                firstFailure = firstFailure ?? .init(code: .missingClip, message: "The clip is no longer available"); continue
            }
            let track = d.sequence.tracks[at.track], clip = track.clips[at.clip]
            if track.locked == true { firstFailure = firstFailure ?? .init(code: .documentMismatch, message: "Track is locked"); continue }
            if clip.placeholder != nil {
                firstFailure = firstFailure ?? .init(code: .documentMismatch, message: "This clip is already a placeholder"); continue
            }
            guard let kind = d.assets.first(where: { $0.id == clip.assetId })?.kind, kind != .element else {
                firstFailure = firstFailure ?? .init(code: .incompatibleDestination, message: "Only a clip of video, sound or a picture can be a placeholder"); continue
            }
            eligible.append(at)
        }
        eligible.sort { (d.sequence.tracks[$0.track].clips[$0.clip].startFrame, $0.track, $0.clip)
                      < (d.sequence.tracks[$1.track].clips[$1.clip].startFrame, $1.track, $1.clip) }
        for at in eligible {
            var number = 1
            while taken.contains(number) { number += 1 }
            taken.insert(number)
            d.sequence.tracks[at.track].clips[at.clip].placeholder = NativeClipPlaceholder(index: number)
        }
        guard !eligible.isEmpty else { lastFailure = firstFailure; return false }
        return commit(d, "Mark as placeholder")
    }

    /// Unmarks every marked clip of `clipIds` in one undo step. A placeholder written by a newer version is left alone.
    @discardableResult
    func clearPlaceholders(clipIds: [String]) -> Bool {
        lastFailure = nil
        var d = document
        var changed = false
        for id in clipIds {
            guard let at = location(of: id, in: d) else {
                lastFailure = lastFailure ?? .init(code: .missingClip, message: "The clip is no longer available"); continue
            }
            if d.sequence.tracks[at.track].locked == true {
                lastFailure = lastFailure ?? .init(code: .documentMismatch, message: "Track is locked"); continue
            }
            guard d.sequence.tracks[at.track].clips[at.clip].placeholder?.isCurrentVersion == true else { continue }
            d.sequence.tracks[at.track].clips[at.clip].placeholder = nil
            changed = true
        }
        return changed && commit(d, "Unmark placeholder")
    }

    private func location(of clipId: String, in d: NativeProjectDocument) -> (track: Int, clip: Int)? {
        for (ti, track) in d.sequence.tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == clipId }) { return (ti, ci) }
        }
        return nil
    }
}
