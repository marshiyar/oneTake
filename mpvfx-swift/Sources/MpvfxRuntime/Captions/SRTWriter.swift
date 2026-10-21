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
// Writes caption cues as a SubRip (SRT) file (format sources in the header of SRTReader.swift): a counter from 1,
// `HH:MM:SS,mmm --> HH:MM:SS,mmm`, the text lines, and a blank line after every cue, including the last.
//
// Decisions: UTF-8 without a byte order mark and CRLF line endings. SubRip is a Windows program and CRLF is its own
// line ending; every reader that takes LF also takes CRLF, and SRTReader reads both. A comma before the milliseconds,
// as in the format's own description. The hours have at least two digits (three above 99 hours).
import Foundation
import MpvfxShared

public enum SRTWriter {
    /// The SRT text of `cues`, which must already pass `validateCues` (a validated document's cues do).
    public static func text(_ cues: [NativeCaptionCue]) -> String {
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\r\n\(timestamp(cue.startMs)) --> \(timestamp(cue.endMs))\r\n"
            out += cue.text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\r\n")
            out += "\r\n\r\n"
        }
        return out
    }

    /// `HH:MM:SS,mmm` of a non-negative millisecond count.
    public static func timestamp(_ ms: Int) -> String {
        let hours = ms / 3_600_000, minutes = ms / 60_000 % 60, seconds = ms / 1000 % 60, millis = ms % 1000
        return pad(hours, 2) + ":" + pad(minutes, 2) + ":" + pad(seconds, 2) + "," + pad(millis, 3)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// Throws `CaptionExportError(.invalidCaptions)` for the first cue SRT cannot carry so that it reads back the same.
    public static func validateCues(_ cues: [NativeCaptionCue]) throws {
        var previous: NativeCaptionCue?
        for (index, cue) in cues.enumerated() {
            let problem = cue.endMs > NATIVE_CAPTION_MAX_MILLISECONDS || cue.startMs < 0
                ? "Caption times must be from 0 to \(NATIVE_CAPTION_MAX_MILLISECONDS) ms"
                : nativeCaptionTimingProblem(cue, after: previous) ?? nativeCaptionTextProblem(cue.text)
            if let problem { throw CaptionExportError(.invalidCaptions, "Caption \(index + 1): \(problem)") }
            previous = cue
        }
    }

    /// Writes `cues` as SRT at `path` through the durable write path (temporary file in the same folder, fsync,
    /// rename over `path`, directory fsync), so `path` holds either its old bytes or the whole new file.
    public static func write(_ cues: [NativeCaptionCue], to path: String, durableWrite: DurableWrite) throws {
        try validateCues(cues)
        // A bare name with no separator of either OS, so it is valid in the target's folder on Windows too.
        let tempName = ".captions-\(UUID().uuidString.lowercased()).srt.tmp"
        try durableWrite.write(Data(text(cues).utf8), to: path, tempName: tempName, preserveMode: true, beforeRename: {})
    }
}

public struct CaptionExportError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable {
        /// The document has no caption track, or its track has no cue.
        case noCaptions
        /// A cue breaks a caption rule (the document validator refuses such a document, so only hand-built cues reach this).
        case invalidCaptions
    }
    public var kind: Kind
    public var message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var description: String { message }
}
