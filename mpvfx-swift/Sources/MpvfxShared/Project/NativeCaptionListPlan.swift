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
// Edits the caption list makes (docs/TIMELINE.md "Caption list"): nudge an end of a cue by frames, split a cue at the text
// caret and the playhead, join a cue with the next, find and replace across every cue, and the reading-rate check. Like the
// plans in NativeCaptionEditPlan.swift each is a pure function from a track to the edited track that passes the same rules
// as `validateNativeCaptionTrack`.
import Foundation

/// Moves one end of a cue by `frames` frames (negative: earlier), clamped like a trim: against the neighbours and the
/// one-frame minimum.
public func planCaptionNudge(_ track: NativeCaptionTrack, cueId: String, edge: NativeCaptionEdge, byFrames frames: Int,
                             frameRate: Double) throws -> NativeCaptionTrack {
    guard let cue = track.cues.first(where: { $0.id == cueId }) else { throw NativeCaptionEditError.unknownCue(cueId) }
    let deltaMs = Int((Double(frames) * 1000 / max(frameRate, 1e-9)).rounded())
    let from = edge == .start ? cue.startMs : cue.endMs
    return try planCaptionTrim(track, cueId: cueId, edge: edge, toMs: from + deltaMs, frameRate: frameRate)
}

/// Splits a cue in two at `atMs` (the playhead) and at `caret` (a character offset in its text). The first cue keeps the text
/// before the caret and runs from the cue's start to `atMs`; the second takes the text after it and runs from `atMs` to the
/// cue's end, so the two stay contiguous. Spaces and line breaks at the cut are dropped. The second cue is `cue:split-N`
/// and also takes the first's position override. Word times stay on whichever cue still spells its words, else go.
/// Throws `.noRoom` when either half would be under one frame, and `.nothingToSplit` when the caret leaves a side empty.
public func planCaptionSplit(_ track: NativeCaptionTrack, cueId: String, atMs: Int, caret: Int, frameRate: Double) throws
    -> (track: NativeCaptionTrack, newCueId: String) {
    guard let i = track.cues.firstIndex(where: { $0.id == cueId }) else { throw NativeCaptionEditError.unknownCue(cueId) }
    let cue = track.cues[i]
    let minimum = nativeCaptionMinimumDurationMs(frameRate: frameRate)
    guard atMs - cue.startMs >= minimum, cue.endMs - atMs >= minimum else { throw NativeCaptionEditError.noRoom }
    let characters = Array(cue.text)
    let cut = min(max(caret, 0), characters.count)
    let trimSet = CharacterSet(charactersIn: " \t\n")
    let before = String(characters[..<cut]).trimmingCharacters(in: trimSet)
    let after = String(characters[cut...]).trimmingCharacters(in: trimSet)
    guard !before.isEmpty, !after.isEmpty else { throw NativeCaptionEditError.nothingToSplit }
    for part in [before, after] { if let problem = nativeCaptionTextProblem(part) { throw NativeCaptionEditError.invalidText(problem) } }

    var first = NativeCaptionCue(id: cue.id, startMs: cue.startMs, endMs: atMs, text: before, position: cue.position)
    var second = NativeCaptionCue(id: nextCaptionCueId(track, prefix: "cue:split-"), startMs: atMs, endMs: cue.endMs, text: after,
                                  position: cue.position)
    if let words = cue.words {
        let early = words.filter { $0.end <= atMs }, late = words.filter { $0.start >= atMs }
        first.words = early; second.words = late
        if nativeCaptionWordsProblem(first) != nil { first.words = nil }
        if nativeCaptionWordsProblem(second) != nil { second.words = nil }
    }
    var out = track
    out.cues[i] = first
    out.cues.insert(second, at: i + 1)
    return (out, second.id)
}

/// Joins a cue with the one after it: the text of both (a single space between) over the span from the first's start to the
/// second's end, so no gap is left. The first cue keeps its id and position. Word times are kept when both cues have them.
public func planCaptionJoin(_ track: NativeCaptionTrack, cueId: String) throws -> NativeCaptionTrack {
    guard let i = track.cues.firstIndex(where: { $0.id == cueId }) else { throw NativeCaptionEditError.unknownCue(cueId) }
    guard i + 1 < track.cues.count else { throw NativeCaptionEditError.noNextCue }
    let a = track.cues[i], b = track.cues[i + 1]
    var joined = NativeCaptionCue(id: a.id, startMs: a.startMs, endMs: b.endMs, text: a.text + " " + b.text, position: a.position)
    if let wa = a.words, let wb = b.words { joined.words = wa + wb; if nativeCaptionWordsProblem(joined) != nil { joined.words = nil } }
    if let problem = nativeCaptionTextProblem(joined.text) { throw NativeCaptionEditError.invalidText(problem) }
    var out = track
    out.cues[i] = joined
    out.cues.remove(at: i + 1)
    return out
}

/// What a find-and-replace did.
public struct NativeCaptionReplaceResult: Equatable, Sendable {
    public var track: NativeCaptionTrack
    /// Cues whose text changed.
    public var cuesChanged: Int
    /// Matches replaced.
    public var replacements: Int
    /// Cues left alone because the result could not be stored (an empty text, or a `-->`).
    public var skipped: [String]
}

/// The cues containing `find`, with how many times: the matches the list highlights. An empty `find` matches nothing.
public func findCaptionMatches(_ track: NativeCaptionTrack, find: String, caseSensitive: Bool) -> [(cueId: String, count: Int)] {
    guard !find.isEmpty else { return [] }
    return track.cues.compactMap { cue in
        let n = captionMatchCount(in: cue.text, find: find, caseSensitive: caseSensitive)
        return n > 0 ? (cue.id, n) : nil
    }
}

/// Replaces every `find` in every cue with `replace` in one result. A cue whose new text is not storable is skipped and
/// named in `skipped`. Word times are dropped from a cue whose text changed unless they still spell it.
public func planCaptionReplaceAll(_ track: NativeCaptionTrack, find: String, replace: String, caseSensitive: Bool) -> NativeCaptionReplaceResult {
    var result = NativeCaptionReplaceResult(track: track, cuesChanged: 0, replacements: 0, skipped: [])
    guard !find.isEmpty else { return result }
    let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    for (i, cue) in track.cues.enumerated() {
        let n = captionMatchCount(in: cue.text, find: find, caseSensitive: caseSensitive)
        guard n > 0 else { continue }
        let text = cue.text.replacingOccurrences(of: find, with: replace, options: options)
        if text == cue.text { continue }
        if nativeCaptionTextProblem(text) != nil { result.skipped.append(cue.id); continue }
        var changed = cue
        changed.text = text
        if nativeCaptionWordsProblem(changed) != nil { changed.words = nil }
        result.track.cues[i] = changed
        result.cuesChanged += 1; result.replacements += n
    }
    return result
}

private func captionMatchCount(in text: String, find: String, caseSensitive: Bool) -> Int {
    let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    var count = 0
    var range = text.startIndex..<text.endIndex
    while let found = text.range(of: find, options: options, range: range) {
        count += 1
        range = found.upperBound..<text.endIndex
    }
    return count
}

/// The reading rate of a cue in characters per second: its characters, not counting line breaks, over its length.
public func nativeCaptionReadingRate(_ cue: NativeCaptionCue) -> Double {
    let seconds = Double(cue.endMs - cue.startMs) / 1000
    guard seconds > 0 else { return .infinity }
    return Double(cue.text.filter { $0 != "\n" }.count) / seconds
}

/// The reading-rate limit a new project starts with (characters per second), and the range the setting allows. The limit is
/// the editor's choice, not a standard.
public let NATIVE_CAPTION_READING_RATE_DEFAULT = 17
public let NATIVE_CAPTION_READING_RATE_RANGE = 5...40

/// True when the cue is read faster than `limit` characters per second.
public func nativeCaptionExceedsReadingRate(_ cue: NativeCaptionCue, limit: Int) -> Bool {
    nativeCaptionReadingRate(cue) > Double(limit)
}
