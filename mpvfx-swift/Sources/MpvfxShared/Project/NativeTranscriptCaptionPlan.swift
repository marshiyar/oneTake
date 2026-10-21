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
// The plan that turns recognised words into caption cues: source-media times to sequence times through the clip's
// start, trim and speed, then grouping into cues that read well, written into the caption track as one new document
// (so the caller makes it one undo step).
import Foundation

/// One recognised word, in milliseconds of the clip's source media. The shape of the runtime's `RecognisedWord`,
/// copied here so this module keeps no dependency on the runtime.
public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public init(text: String, startMs: Int, endMs: Int) { self.text = text; self.startMs = startMs; self.endMs = endMs }
}

/// What to do with cues already in the clip's range.
public enum TranscriptCaptionOverlap: Equatable, Sendable {
    /// Remove the cues lying inside the clip's range, then add the new ones.
    case replaceRange
    /// Keep every existing cue; refuse when a new cue would overlap one.
    case keepExisting
}

/// The grouping rules, named so they are changed in one place. They are this feature's choice, picked so a cue fits
/// the two-line wrap of the caption look at typical sizes.
public enum TranscriptCaptionRules {
    /// A pause between two words at least this long starts a new cue.
    public static let pauseBreakMs = 600
    /// A cue that already holds this many words ends after a word that ends a sentence.
    public static let sentenceBreakMinWords = 3
    public static let maxCharacters = 84
    public static let maxCueMs = 6000
    /// A cue shows at least this long, extended into the gap that follows it and never over the next cue.
    public static let minCueMs = 700
}

public enum TranscriptCaptionPlanError: Error, Equatable, CustomStringConvertible, Sendable {
    case clipNotFound(String)
    case clipHasSpeedRamp(String)
    case invalidClipTiming(String)
    case wordsOutOfOrder(Int)
    /// A new cue would overlap the existing cue with this id, which starts at `startMs`.
    case overlapsExistingCue(id: String, startMs: Int)
    case invalidResult(String)

    public var description: String {
        switch self {
        case .clipNotFound(let id): return "The clip \(id) is not in the project, so its speech cannot be added as captions."
        case .clipHasSpeedRamp: return "This clip has a speed ramp, which captions from speech do not support yet."
        case .invalidClipTiming(let why): return "The clip's timing cannot carry captions: \(why)."
        case .wordsOutOfOrder(let n): return "Recognised word \(n + 1) starts before the word before it ends, so no captions were made."
        case .overlapsExistingCue(_, let ms):
            return "Existing captions overlap the new ones at \(ms) ms. Choose to replace the captions in this range, or remove them first."
        case .invalidResult(let why): return "The captions made from speech are not valid (\(why)), so none were added."
        }
    }
}

public struct TranscriptCaptionPlan: Equatable, Sendable {
    public var document: NativeProjectDocument
    public var cuesAdded: Int
    public var cuesReplaced: Int
    /// Words left out: outside the clip's trimmed range, or empty once cleaned.
    public var wordsDropped: Int
    /// Words whose text was changed to meet the caption text rules (new lines, `-->`, control characters).
    public var wordsCleaned: Int
}

/// Adds the cues for `words` (source milliseconds of `clipId`'s media) to the document's caption track, creating it
/// when absent. The input document is not changed; the result holds the new one.
public func planTranscriptCaptions(_ document: NativeProjectDocument, clipId: String, words: [TranscriptWord],
                                   overlap: TranscriptCaptionOverlap) throws -> TranscriptCaptionPlan {
    guard let clip = document.sequence.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipId }) else {
        throw TranscriptCaptionPlanError.clipNotFound(clipId)
    }
    let mapping = try TranscriptClipMapping(clip: clip, frameRate: document.frameRate)
    var dropped = 0, cleaned = 0
    var mapped: [NativeCaptionWord] = []
    var previousEnd = Int.min
    for (n, word) in words.enumerated() {
        if word.endMs < word.startMs || word.startMs < previousEnd { throw TranscriptCaptionPlanError.wordsOutOfOrder(n) }
        previousEnd = word.endMs
        guard mapping.contains(word) else { dropped += 1; continue }
        let (text, changed) = cleanedCaptionWord(word.text)
        guard !text.isEmpty else { dropped += 1; continue }
        if changed { cleaned += 1 }
        mapped.append(NativeCaptionWord(text: text, start: mapping.sequenceMs(word.startMs), end: mapping.sequenceMs(word.endMs)))
    }
    let cues = groupIntoCues(mapped)
    var track = document.sequence.captions ?? NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: [])
    var replaced = 0
    if overlap == .replaceRange {
        let before = track.cues.count
        track.cues.removeAll { $0.startMs >= mapping.rangeStartMs && $0.endMs <= mapping.rangeEndMs }
        replaced = before - track.cues.count
    }
    if let hit = firstOverlap(of: cues, in: track.cues) {
        throw TranscriptCaptionPlanError.overlapsExistingCue(id: hit.id, startMs: hit.startMs)
    }
    track.cues = (track.cues + assignIds(cues, avoiding: track.cues)).sorted { $0.startMs < $1.startMs }
    var next = document
    next.sequence.captions = track
    if let problem = captionTrackProblem(track) { throw TranscriptCaptionPlanError.invalidResult(problem) }
    return TranscriptCaptionPlan(document: next, cuesAdded: cues.count, cuesReplaced: replaced, wordsDropped: dropped, wordsCleaned: cleaned)
}

/// Source media milliseconds to sequence milliseconds for one clip: its start, the source time it begins at and its speed.
struct TranscriptClipMapping {
    let clipStartSeconds: Double
    let sourceInSeconds: Double
    let sourceOutSeconds: Double
    let rate: Double

    init(clip: NativeProjectClip, frameRate: RationalFrameRate) throws {
        if clip.speedRamp != nil { throw TranscriptCaptionPlanError.clipHasSpeedRamp(clip.id) }
        let fps = frameRate.numerator / frameRate.denominator
        let rate = clip.playbackRate.map { $0.numerator / $0.denominator } ?? 1
        guard fps.isFinite, fps > 0, rate.isFinite, rate > 0, clip.durationFrames.isFinite, clip.durationFrames > 0,
              clip.startFrame.isFinite, clip.startFrame >= 0, clip.sourceInFrame.isFinite, clip.sourceInFrame >= 0 else {
            throw TranscriptCaptionPlanError.invalidClipTiming("its frame rate, speed, start or length is not a usable number")
        }
        let fraction = clip.sourceInFraction.map { $0.numerator / $0.denominator } ?? 0
        self.rate = rate
        clipStartSeconds = clip.startFrame / fps
        sourceInSeconds = (clip.sourceInFrame + fraction) / fps
        sourceOutSeconds = sourceInSeconds + clip.durationFrames / fps * rate
    }

    var rangeStartMs: Int { Int((clipStartSeconds * 1000).rounded()) }
    var rangeEndMs: Int { Int(((clipStartSeconds + (sourceOutSeconds - sourceInSeconds) / rate) * 1000).rounded()) }

    func contains(_ word: TranscriptWord) -> Bool {
        Double(word.startMs) / 1000 >= sourceInSeconds - 1e-9 && Double(word.endMs) / 1000 <= sourceOutSeconds + 1e-9
    }

    func sequenceMs(_ sourceMs: Int) -> Int {
        Int(((clipStartSeconds + (Double(sourceMs) / 1000 - sourceInSeconds) / rate) * 1000).rounded())
    }
}

/// The word with its text made storable (`nativeCaptionLineProblem`), and whether that changed it.
func cleanedCaptionWord(_ text: String) -> (String, Bool) {
    var out = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "-->", with: "->")
    out.unicodeScalars.removeAll { ($0.value < 0x20 && $0 != "\t" ) || ($0.value >= 0x7F && $0.value < 0xA0) || $0 == "\u{FFFD}" }
    out = out.trimmingCharacters(in: .whitespaces)
    return (out, out != text)
}

private func endsSentence(_ text: String) -> Bool {
    guard let last = text.last else { return false }
    return ".?!…".contains(last)
}

/// Words (sequence milliseconds, in order) split into cues by the `TranscriptCaptionRules`; ids are assigned later.
func groupIntoCues(_ words: [NativeCaptionWord]) -> [NativeCaptionCue] {
    var groups: [[NativeCaptionWord]] = []
    var current: [NativeCaptionWord] = []
    var length = 0
    for word in words {
        if let last = current.last {
            let grown = length + 1 + word.text.count
            let breaks = word.start - last.end >= TranscriptCaptionRules.pauseBreakMs
                || (current.count >= TranscriptCaptionRules.sentenceBreakMinWords && endsSentence(last.text))
                || grown > TranscriptCaptionRules.maxCharacters
                || word.end - current[0].start > TranscriptCaptionRules.maxCueMs
            if breaks { groups.append(current); current = []; length = 0 }
        }
        length += (current.isEmpty ? 0 : 1) + word.text.count
        current.append(word)
    }
    if !current.isEmpty { groups.append(current) }
    var cues: [NativeCaptionCue] = []
    for (n, group) in groups.enumerated() {
        let start = group[0].start
        let nextStart = n + 1 < groups.count ? groups[n + 1][0].start : Int.max
        let end = max(group[group.count - 1].end, min(start + TranscriptCaptionRules.minCueMs, nextStart))
        cues.append(NativeCaptionCue(id: "", startMs: start, endMs: max(end, start + 1),
                                     text: group.map(\.text).joined(separator: " "), words: group))
    }
    return cues
}

private func firstOverlap(of cues: [NativeCaptionCue], in existing: [NativeCaptionCue]) -> NativeCaptionCue? {
    for old in existing.sorted(by: { $0.startMs < $1.startMs }) where cues.contains(where: { $0.startMs < old.endMs && old.startMs < $0.endMs }) {
        return old
    }
    return nil
}

private func assignIds(_ cues: [NativeCaptionCue], avoiding existing: [NativeCaptionCue]) -> [NativeCaptionCue] {
    var used = Set(existing.map(\.id))
    var n = 0
    return cues.map { cue in
        var next = cue
        repeat { n += 1; next.id = "cue:speech-\(n)" } while used.contains(next.id)
        used.insert(next.id)
        return next
    }
}

private func captionTrackProblem(_ track: NativeCaptionTrack) -> String? {
    var previous: NativeCaptionCue?
    for cue in track.cues {
        if let p = nativeCaptionTimingProblem(cue, after: previous) ?? nativeCaptionTextProblem(cue.text).map({ $0 }) ?? nativeCaptionWordsProblem(cue) {
            return p
        }
        if cue.endMs > NATIVE_CAPTION_MAX_MILLISECONDS { return "a cue ends after the largest caption time" }
        previous = cue
    }
    return nil
}
