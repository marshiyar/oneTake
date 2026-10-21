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
// Reads a SubRip (SRT) subtitle file into caption cues.
//
// The format, as described by the Library of Congress, "SubRip Subtitle format (SRT)", fdd000569
// (https://www.loc.gov/preservation/digital/formats/fdd/fdd000569.shtml) and by Matroska, "Subtitles", section
// "SRT Subtitles" (https://www.matroska.org/technical/subtitles.html); the dates read are in docs/IMPLEMENTATION_NOTES.md
// ("Captions (SRT)"): blocks separated by one or more blank lines, each a numeric counter, a timing line
// `HH:MM:SS,mmm --> HH:MM:SS,mmm` (the arrow is two hyphens and `>`), one or more lines of text, then a blank line.
// The format has no character-encoding standard: SubRip itself writes Windows-1252 by default and can write UTF-8 or
// UTF-16 with or without a byte order mark (LoC, "Normal rendering" and "Transparency").
//
// What this reader accepts beyond that description, and why: a dot instead of the comma before the milliseconds
// (common in files written by other tools), CRLF, LF or CR line endings, a missing counter line, a missing final
// blank line, and text after the end time on the timing line (SubRip's position coordinates, ignored). Text is read
// as UTF-8, or as UTF-16 when the file starts with a UTF-16 byte order mark; anything else (Windows-1252, UTF-16
// without a mark) is refused with the line of the first byte that is not text, because guessing a code page would
// import wrong characters silently. Every refusal is an `SRTReadError` naming the line, and nothing is returned
// until the whole file has been read, so an import never applies part of a file.
import Foundation
import MpvfxShared

public struct SRTReadError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable {
        /// The file is larger than `SRTReader.maxBytes`.
        case tooLarge
        /// The bytes are not UTF-8 (or UTF-16 after its byte order mark).
        case invalidEncoding
        /// A block does not start with a cue number or a timing line, or a cue number is not followed by one.
        case expectedTiming
        /// A start or end time is not `HH:MM:SS,mmm`.
        case invalidTimestamp
        /// The cue's times or text break a caption rule (order, overlap, duration, blank or control characters).
        case invalidCue
        /// The file holds no cue.
        case noCues
    }
    public var kind: Kind
    /// 1-based line of the file the error is about; 0 when it is about the whole file.
    public var line: Int
    public var reason: String
    public init(_ kind: Kind, line: Int, _ reason: String) { self.kind = kind; self.line = line; self.reason = reason }
    public var message: String { line > 0 ? "Line \(line): \(reason)" : reason }
    public var description: String { message }
}

public enum SRTReader {
    /// 8 MiB: about forty times the SRT of a three-hour film; a larger file is almost certainly not subtitles.
    public static let maxBytes = 8 << 20

    /// The cues of an SRT file, ids `cue-1`, `cue-2`, … in file order. Throws `SRTReadError`.
    public static func read(_ data: Data) throws -> [NativeCaptionCue] {
        guard data.count <= maxBytes else {
            throw SRTReadError(.tooLarge, line: 0, "The file is \(data.count) bytes; a subtitle file over \(maxBytes) bytes is refused")
        }
        let lines = splitLines(try decodeText(data))
        var cues: [NativeCaptionCue] = []
        var index = 0
        while let start = lines[index...].firstIndex(where: { !isBlank($0) }) {
            let (cue, next) = try readCue(lines, at: start, previous: cues.last, number: cues.count + 1)
            cues.append(cue)
            index = next
        }
        guard !cues.isEmpty else { throw SRTReadError(.noCues, line: 0, "The file holds no captions") }
        return cues
    }

    // MARK: Text decoding

    static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) { return try decodeUTF16(bytes.dropFirst(2), bigEndian: false) }
        if bytes.starts(with: [0xFE, 0xFF]) { return try decodeUTF16(bytes.dropFirst(2), bigEndian: true) }
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        return try decodeStrict(body.makeIterator(), UTF8(), what: "UTF-8")
    }

    private static func decodeUTF16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) throws -> String {
        guard bytes.count % 2 == 0 else {
            throw SRTReadError(.invalidEncoding, line: 0, "The file starts with a UTF-16 byte order mark but has an odd number of bytes")
        }
        let units = stride(from: bytes.startIndex, to: bytes.endIndex, by: 2).map { i -> UInt16 in
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            return bigEndian ? a << 8 | b : b << 8 | a
        }
        return try decodeStrict(units.makeIterator(), UTF16(), what: "UTF-16")
    }

    /// Decodes every scalar, refusing an invalid sequence and NUL (a UTF-16 file without its byte order mark reads as
    /// UTF-8 full of NULs) with the line they are on.
    private static func decodeStrict<I: IteratorProtocol, C: UnicodeCodec>(_ input: I, _ codec: C, what: String) throws -> String
    where I.Element == C.CodeUnit {
        var iterator = input, decoder = codec, scalars = String.UnicodeScalarView(), line = 1
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let s) where s.value == 0:
                throw SRTReadError(.invalidEncoding, line: line, "The file holds a NUL character; save it as UTF-8 text and import it again")
            case .scalarValue(let s):
                if s == "\n" { line += 1 }
                scalars.append(s)
            case .emptyInput:
                return String(scalars)
            case .error:
                throw SRTReadError(.invalidEncoding, line: line, "The file is not \(what) text; save it as UTF-8 and import it again")
            }
        }
    }

    /// Lines split at CRLF, LF or CR (only those: U+2028 and other separators stay inside a line, as the writer
    /// writes them). A trailing line break does not add a line; a byte order mark decoded as U+FEFF is dropped.
    static func splitLines(_ text: String) -> [Substring] {
        let scalars = text.unicodeScalars
        var lines: [Substring] = []
        var start = scalars.startIndex, i = scalars.startIndex
        while i < scalars.endIndex {
            guard let next = lineBreakEnd(scalars, at: i) else { i = scalars.index(after: i); continue }
            lines.append(Substring(scalars[start..<i]))
            start = next; i = next
        }
        if start < scalars.endIndex { lines.append(Substring(scalars[start...])) }
        if let first = lines.first, first.unicodeScalars.first == "\u{FEFF}" { lines[0] = Substring(first.unicodeScalars.dropFirst()) }
        return lines
    }

    /// The index after the line break at `i` (CRLF counts as one), or nil when `i` is not a line break.
    private static func lineBreakEnd(_ scalars: String.UnicodeScalarView, at i: String.Index) -> String.Index? {
        let after = scalars.index(after: i)
        switch scalars[i] {
        case "\n": return after
        case "\r": return after < scalars.endIndex && scalars[after] == "\n" ? scalars.index(after: after) : after
        default: return nil
        }
    }

    // MARK: Blocks

    static func isBlank(_ line: Substring) -> Bool { line.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" } }

    /// One cue from the block starting at `start`; returns it and the index of the line after its text.
    private static func readCue(_ lines: [Substring], at start: Int, previous: NativeCaptionCue?, number: Int) throws -> (NativeCaptionCue, Int) {
        let timingIndex = try timingLineIndex(lines, blockStart: start)
        let (startMs, endMs) = try parseTimingLine(lines[timingIndex], line: timingIndex + 1)
        var end = timingIndex + 1
        while end < lines.count, !isBlank(lines[end]) {
            if let problem = nativeCaptionLineProblem(lines[end]) {
                throw SRTReadError(.invalidCue, line: end + 1, textProblemHint(problem, lines[end]))
            }
            end += 1
        }
        guard end > timingIndex + 1 else { throw SRTReadError(.invalidCue, line: timingIndex + 1, "The cue has no text") }
        let text = lines[(timingIndex + 1)..<end].joined(separator: "\n")
        let cue = NativeCaptionCue(id: "cue-\(number)", startMs: startMs, endMs: endMs, text: text)
        if let problem = nativeCaptionTimingProblem(cue, after: previous) { throw SRTReadError(.invalidCue, line: timingIndex + 1, problem) }
        return (cue, end)
    }

    private static func textProblemHint(_ problem: String, _ line: Substring) -> String {
        line.contains("-->") ? "A timing line inside a cue's text: is a blank line missing before it?" : problem
    }

    /// The index of the block's timing line: the first line, or the second after a cue number.
    private static func timingLineIndex(_ lines: [Substring], blockStart: Int) throws -> Int {
        let first = lines[blockStart]
        if first.contains("-->") { return blockStart }
        let counter = first.trimmingCharacters(in: .whitespaces)
        guard !counter.isEmpty, counter.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
            throw SRTReadError(.expectedTiming, line: blockStart + 1,
                               "Expected a cue number or a timing line such as 00:00:01,000 --> 00:00:02,500")
        }
        let next = blockStart + 1
        guard next < lines.count, lines[next].contains("-->") else {
            throw SRTReadError(.expectedTiming, line: next + 1, "Cue number \(counter) must be followed by its timing line (start --> end)")
        }
        return next
    }

    /// `start --> end [position]`, both `H:MM:SS,mmm` (one to three hour digits, comma or dot).
    static func parseTimingLine(_ text: Substring, line: Int) throws -> (Int, Int) {
        guard let arrow = text.range(of: "-->") else {
            throw SRTReadError(.expectedTiming, line: line, "Expected a timing line such as 00:00:01,000 --> 00:00:02,500")
        }
        let left = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = text[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endText = right.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let start = parseTimestamp(left) else { throw badTimestamp("start", left, line) }
        guard let end = parseTimestamp(endText) else { throw badTimestamp("end", endText, line) }
        return (start, end)
    }

    private static func badTimestamp(_ which: String, _ text: String, _ line: Int) -> SRTReadError {
        SRTReadError(.invalidTimestamp, line: line, "The \(which) time \"\(text.prefix(40))\" is not HH:MM:SS,mmm (minutes and seconds below 60)")
    }

    /// Milliseconds of `H:MM:SS,mmm` or `H:MM:SS.mmm`, or nil.
    static func parseTimestamp(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let seconds = splitSeconds(parts[2]) else { return nil }
        guard let h = digits(parts[0], 1...3), let m = digits(parts[1], 2...2), m < 60,
              let s = digits(seconds.0, 2...2), s < 60, let ms = digits(seconds.1, 3...3) else { return nil }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    private static func splitSeconds(_ text: Substring) -> (Substring, Substring)? {
        guard let mark = text.firstIndex(where: { $0 == "," || $0 == "." }) else { return nil }
        return (text[..<mark], text[text.index(after: mark)...])
    }

    /// The value of `text` when it is only ASCII digits and its length is in `count`.
    private static func digits(_ text: Substring, _ count: ClosedRange<Int>) -> Int? {
        guard count.contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return text.utf8.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }
}
