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
// Edits to the caption track made from the timeline's caption lane: move a cue, trim one edge, retype the text, add a
// cue at the playhead. Each is a pure function from a track to the edited track. A move or trim clamps to what the
// neighbours and the one-frame minimum allow instead of failing, so a drag past a neighbour stops against it, and every
// result passes the same rules as `validateNativeCaptionTrack` (start order, no overlap, text, word times).
import Foundation

/// Why a caption edit cannot be made.
public enum NativeCaptionEditError: Error, Equatable, Sendable {
    case noCaptionTrack
    case unknownCue(String)
    case invalidText(String)
    /// No gap at the requested time can hold a cue of at least one frame.
    case noRoom
}

/// Which end of a cue a trim moves.
public enum NativeCaptionEdge: Sendable { case start, end }

/// The length a cue or a new cue may not go under: one frame of the sequence, rounded up to whole milliseconds.
public func nativeCaptionMinimumDurationMs(frameRate: Double) -> Int {
    guard frameRate.isFinite, frameRate > 0 else { return 1 }
    return max(1, Int((1000.0 / frameRate).rounded(.up)))
}

/// The length of a cue added at the playhead when the gap after it is long enough.
public let NATIVE_CAPTION_NEW_CUE_MS = 2000

/// The text of a cue added at the playhead, to be retyped.
public let NATIVE_CAPTION_NEW_CUE_TEXT = "Caption"

/// Moves a cue to start at `startMs`, keeping its length. The start clamps so the cue stays after the cue before it, before
/// the cue after it, and inside 0…NATIVE_CAPTION_MAX_MILLISECONDS. Word times move with the cue.
public func planCaptionMove(_ track: NativeCaptionTrack, cueId: String, toStartMs startMs: Int) throws -> NativeCaptionTrack {
    let i = try captionCueIndex(track, cueId)
    var cue = track.cues[i]
    let length = cue.endMs - cue.startMs
    let lower = i > 0 ? track.cues[i - 1].endMs : 0
    let upper = (i + 1 < track.cues.count ? track.cues[i + 1].startMs : NATIVE_CAPTION_MAX_MILLISECONDS) - length
    let start = min(max(startMs, lower), max(lower, upper))
    let delta = start - cue.startMs
    cue.startMs = start
    cue.endMs = start + length
    if let words = cue.words { cue.words = words.map { NativeCaptionWord(text: $0.text, start: $0.start + delta, end: $0.end + delta) } }
    var out = track
    out.cues[i] = cue
    return out
}

/// Moves one edge of a cue to `ms`. The start edge clamps between the end of the cue before and one frame short of the
/// cue's end; the end edge between one frame after its start and the start of the cue after. Word times stay when every
/// word still lies inside the cue and are dropped when the trim cuts into one (the cue text is unchanged).
public func planCaptionTrim(_ track: NativeCaptionTrack, cueId: String, edge: NativeCaptionEdge, toMs ms: Int,
                            frameRate: Double) throws -> NativeCaptionTrack {
    let i = try captionCueIndex(track, cueId)
    var cue = track.cues[i]
    let minimum = nativeCaptionMinimumDurationMs(frameRate: frameRate)
    switch edge {
    case .start:
        let lower = i > 0 ? track.cues[i - 1].endMs : 0
        let upper = max(lower, cue.endMs - minimum)
        cue.startMs = min(max(ms, lower), upper)
    case .end:
        let lower = cue.startMs + minimum
        let upper = max(lower, i + 1 < track.cues.count ? track.cues[i + 1].startMs : NATIVE_CAPTION_MAX_MILLISECONDS)
        cue.endMs = min(max(ms, lower), upper)
    }
    if nativeCaptionWordsProblem(cue) != nil { cue.words = nil }
    var out = track
    out.cues[i] = cue
    return out
}

/// Replaces a cue's text. Line endings normalise to `\n`. Word times are dropped unless they still spell the new text.
public func planCaptionRetext(_ track: NativeCaptionTrack, cueId: String, text: String) throws -> NativeCaptionTrack {
    let i = try captionCueIndex(track, cueId)
    let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if let problem = nativeCaptionTextProblem(normalised) { throw NativeCaptionEditError.invalidText(problem) }
    var cue = track.cues[i]
    cue.text = normalised
    if nativeCaptionWordsProblem(cue) != nil { cue.words = nil }
    var out = track
    out.cues[i] = cue
    return out
}

/// Adds a cue starting at `startMs`: 2 s long, or as long as the gap to the next cue when that is shorter. A track is
/// created when there is none. Throws `.noRoom` when `startMs` falls inside a cue or the gap holds less than one frame.
/// Returns the edited track and the new cue's id (`cue:manual-N`, the first N not used in the track).
public func planCaptionAdd(_ track: NativeCaptionTrack?, atMs startMs: Int, frameRate: Double) throws
    -> (track: NativeCaptionTrack, cueId: String) {
    var out = track ?? NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: [])
    guard startMs >= 0, startMs < NATIVE_CAPTION_MAX_MILLISECONDS else { throw NativeCaptionEditError.noRoom }
    if out.cues.contains(where: { $0.startMs <= startMs && startMs < $0.endMs }) { throw NativeCaptionEditError.noRoom }
    let next = out.cues.first { $0.startMs >= startMs }
    let end = min(startMs + NATIVE_CAPTION_NEW_CUE_MS, next?.startMs ?? NATIVE_CAPTION_MAX_MILLISECONDS, NATIVE_CAPTION_MAX_MILLISECONDS)
    guard end - startMs >= nativeCaptionMinimumDurationMs(frameRate: frameRate) else { throw NativeCaptionEditError.noRoom }
    let used = Set(out.cues.map(\.id))
    var n = 1
    while used.contains("cue:manual-\(n)") { n += 1 }
    let id = "cue:manual-\(n)"
    let index = out.cues.firstIndex { $0.startMs >= startMs } ?? out.cues.count
    out.cues.insert(NativeCaptionCue(id: id, startMs: startMs, endMs: end, text: NATIVE_CAPTION_NEW_CUE_TEXT), at: index)
    return (out, id)
}

private func captionCueIndex(_ track: NativeCaptionTrack, _ cueId: String) throws -> Int {
    guard let i = track.cues.firstIndex(where: { $0.id == cueId }) else { throw NativeCaptionEditError.unknownCue(cueId) }
    return i
}
