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
// The sequence's caption track (`sequence.captions` in `project.json`): timed cues of text, their validation, and the
// rules a cue must meet so an SRT export of it reads back into the same cue.
//
// Times are integer milliseconds from the start of the sequence (a timescale of 1000 ticks per second), the unit SRT
// stores (`HH:MM:SS,mmm`), so an SRT import keeps its exact times instead of rounding them to frames.
import Foundation

/// The caption track of a sequence: cues in start order that never overlap.
public struct NativeCaptionTrack: Codable, Equatable, Sendable {
    public var id: String
    public var cues: [NativeCaptionCue]
    public init(id: String, cues: [NativeCaptionCue]) { self.id = id; self.cues = cues }
}

/// One caption: `text` shown from `startMs` up to (not including) `endMs`; `\n` breaks a line.
public struct NativeCaptionCue: Codable, Equatable, Hashable, Sendable {
    public var id: String
    /// Milliseconds from the start of the sequence.
    public var startMs: Int
    /// Milliseconds from the start of the sequence; always after `startMs`.
    public var endMs: Int
    public var text: String
    /// When each word of `text` is spoken, in the same milliseconds as the cue; absent when the cue has no word
    /// times (an SRT import has none). Omitted from the file when absent, so a project without them is unchanged.
    public var words: [NativeCaptionWord]? = nil
    public init(id: String, startMs: Int, endMs: Int, text: String, words: [NativeCaptionWord]? = nil) {
        self.id = id; self.startMs = startMs; self.endMs = endMs; self.text = text; self.words = words
    }
}

/// One spoken word of a cue: `text` heard from `start` to `end`, milliseconds from the start of the sequence.
public struct NativeCaptionWord: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var start: Int
    public var end: Int
    public init(text: String, start: Int, end: Int) { self.text = text; self.start = start; self.end = end }
}

/// Why a cue's word times are not valid, or nil: the words join with single spaces to the cue text, each lies inside
/// the cue with `start <= end`, and each starts at or after the end of the one before it.
public func nativeCaptionWordsProblem(_ cue: NativeCaptionCue) -> String? {
    guard let words = cue.words else { return nil }
    if words.isEmpty { return "Caption word times must hold at least one word" }
    if words.map(\.text).joined(separator: " ") != cue.text { return "Caption word times must spell the cue text word for word" }
    var previousEnd = cue.startMs
    for (n, word) in words.enumerated() {
        if word.end < word.start { return "Caption word \(n + 1) ends before it starts" }
        if word.start < previousEnd { return "Caption word \(n + 1) starts before the cue or overlaps the word before it" }
        if word.end > cue.endMs { return "Caption word \(n + 1) ends after the cue ends" }
        previousEnd = word.end
    }
    return nil
}

/// The track id an SRT import gives a sequence that has no caption track yet.
public let NATIVE_CAPTION_TRACK_DEFAULT_ID = "captions:main"

/// The latest time a cue may use: 999:59:59,999, the largest SRT time with at most three hour digits.
public let NATIVE_CAPTION_MAX_MILLISECONDS = 999 * 3_600_000 + 59 * 60_000 + 59 * 1000 + 999

/// Why a cue cannot follow `previous` (nil when it is the first cue), or nil when it can.
public func nativeCaptionTimingProblem(_ cue: NativeCaptionCue, after previous: NativeCaptionCue?) -> String? {
    if cue.endMs <= cue.startMs {
        return "Caption cue must end after it starts (it starts at \(cue.startMs) ms and ends at \(cue.endMs) ms)"
    }
    guard let previous else { return nil }
    if cue.startMs < previous.startMs {
        return "Caption cues must be in start order (this cue starts at \(cue.startMs) ms, before the previous cue at \(previous.startMs) ms)"
    }
    if cue.startMs < previous.endMs {
        return "Caption cue overlaps the previous cue (it starts at \(cue.startMs) ms, before the previous cue ends at \(previous.endMs) ms)"
    }
    return nil
}

/// Why one line of caption text cannot be stored, or nil when it can. A line must hold something other than spaces
/// (a blank line ends an SRT cue) and must not hold `-->` (an SRT reader takes it for a timing line), U+FFFD (what
/// an invalid UTF-8 sequence decodes to) or a control character other than a tab.
public func nativeCaptionLineProblem<S: StringProtocol>(_ line: S) -> String? {
    if line.unicodeScalars.allSatisfy({ $0 == " " || $0 == "\t" }) { return "Caption text must not hold a blank line" }
    if line.contains("-->") { return "Caption text must not hold \"-->\" (it marks an SRT timing line)" }
    if line.unicodeScalars.contains("\u{FFFD}") {
        return "Caption text holds U+FFFD, the replacement for invalid UTF-8; fix the text and save it as UTF-8"
    }
    if line.unicodeScalars.contains(where: isRefusedCaptionScalar) { return "Caption text must not hold control characters" }
    return nil
}

/// Why a cue's whole text cannot be stored, or nil when it can (every `\n`-separated line passes `nativeCaptionLineProblem`).
public func nativeCaptionTextProblem(_ text: String) -> String? {
    if text.isEmpty { return "Caption text must not be empty" }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if let problem = nativeCaptionLineProblem(line) { return problem }
    }
    return nil
}

private func isRefusedCaptionScalar(_ s: Unicode.Scalar) -> Bool {
    (s.value < 0x20 && s != "\t") || (s.value >= 0x7F && s.value < 0xA0)
}

/// Validation of `sequence.captions` (NativeProjectDocumentValidation): an object with an id and an array of cues.
func validateNativeCaptionTrack(_ raw: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let raw else { return }
    guard raw.isRecord else { return pushIssue(&issues, .invalidCaption, path, "Caption track must be an object") }
    _ = requireId(raw["id"], "\(path).id", &issues)
    guard let cues = raw["cues"]?.arrayValue else {
        return pushIssue(&issues, .invalidCaption, "\(path).cues", "Caption cues must be an array")
    }
    var ids = Set<String>()
    var previous: NativeCaptionCue?
    for (index, cue) in cues.enumerated() {
        let cuePath = "\(path).cues[\(index)]"
        guard cue.isRecord else { pushIssue(&issues, .invalidCaption, cuePath, "Caption cue must be an object"); continue }
        _ = requireId(cue["id"], "\(cuePath).id", &issues)
        collectDuplicateId(&ids, cue["id"], "\(cuePath).id", &issues)
        validateCaptionText(cue["text"], "\(cuePath).text", &issues)
        guard let timed = captionCueTimes(cue, cuePath, &issues) else { continue }
        if let problem = nativeCaptionTimingProblem(timed, after: previous) { pushIssue(&issues, .invalidCaption, cuePath, problem) }
        validateCaptionWords(cue, timed, cuePath, &issues)
        previous = timed
    }
}

private func validateCaptionText(_ raw: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let text = raw?.stringValue else { return pushIssue(&issues, .invalidCaption, path, "Caption text must be a string") }
    if let problem = nativeCaptionTextProblem(text) { pushIssue(&issues, .invalidCaption, path, problem) }
}

/// The cue's start and end as a timing-only cue, or nil (with an issue per bad field) when either is not a whole
/// number of milliseconds within 0…NATIVE_CAPTION_MAX_MILLISECONDS.
private func captionCueTimes(_ cue: NativeJSONValue, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) -> NativeCaptionCue? {
    var times: [Int] = []
    for name in ["startMs", "endMs"] {
        if let n = cue[name]?.numberValue, isNonNegativeInteger(cue[name]), n <= Double(NATIVE_CAPTION_MAX_MILLISECONDS) {
            times.append(Int(n))
        } else {
            pushIssue(&issues, .invalidCaption, "\(path).\(name)",
                      "\(name) must be a whole number of milliseconds from 0 to \(NATIVE_CAPTION_MAX_MILLISECONDS)")
        }
    }
    guard times.count == 2 else { return nil }
    return NativeCaptionCue(id: "", startMs: times[0], endMs: times[1], text: "")
}

/// The cue's `words`, when present: an array of `{ text, start, end }` that passes `nativeCaptionWordsProblem`.
private func validateCaptionWords(_ cue: NativeJSONValue, _ times: NativeCaptionCue, _ path: String,
                                  _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let raw = cue["words"] else { return }
    guard let list = raw.arrayValue else { return pushIssue(&issues, .invalidCaption, "\(path).words", "Caption words must be an array") }
    var words: [NativeCaptionWord] = []
    for (index, item) in list.enumerated() {
        let at = "\(path).words[\(index)]"
        guard item.isRecord, let text = item["text"]?.stringValue else {
            pushIssue(&issues, .invalidCaption, at, "A caption word must be an object with a text string"); continue
        }
        guard isNonNegativeInteger(item["start"]), isNonNegativeInteger(item["end"]),
              let start = item["start"]?.numberValue, let end = item["end"]?.numberValue else {
            pushIssue(&issues, .invalidCaption, at, "A caption word's start and end must be whole milliseconds"); continue
        }
        words.append(NativeCaptionWord(text: text, start: Int(start), end: Int(end)))
    }
    guard words.count == list.count else { return }
    var checked = times
    checked.text = cue["text"]?.stringValue ?? ""
    checked.words = words
    if let problem = nativeCaptionWordsProblem(checked) { pushIssue(&issues, .invalidCaption, "\(path).words", problem) }
}
