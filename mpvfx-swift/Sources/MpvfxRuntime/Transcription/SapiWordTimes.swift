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
// Windows speech to captions: turning the desktop recognizer's phrase values into words. Pure arithmetic with no
// Windows call, so it runs and is tested on every OS.
import Foundation

/// One phrase element as SAPI reports it: its display text, the time from the phrase start and its length, both in
/// 100-nanosecond units.
public struct SapiPhraseWord: Equatable, Sendable {
    public var text: String
    public var offset100ns: Int64
    public var duration100ns: Int64
    public init(text: String, offset100ns: Int64, duration100ns: Int64) {
        self.text = text; self.offset100ns = offset100ns; self.duration100ns = duration100ns
    }
}

/// Words in milliseconds from the start of the WAV piece. `phraseStart100ns` is the phrase's position in the stream.
/// Blank texts are left out; a negative time is an `invalidResult`.
public func recognisedWords(fromSapi words: [SapiPhraseWord], phraseStart100ns: Int64) throws -> [RecognisedWord] {
    var out: [RecognisedWord] = []
    for (n, word) in words.enumerated() {
        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let (start, overflow) = phraseStart100ns.addingReportingOverflow(word.offset100ns)
        let (end, overflow2) = start.addingReportingOverflow(word.duration100ns)
        guard !overflow, !overflow2, phraseStart100ns >= 0, word.offset100ns >= 0, word.duration100ns >= 0 else {
            throw TranscriptionError.invalidResult("recognised word \(n + 1) has a negative or oversized time")
        }
        out.append(RecognisedWord(text: text, startMs: Int(roundedMilliseconds(start)), endMs: Int(roundedMilliseconds(end))))
    }
    return out
}

/// 100-nanosecond units to milliseconds, half up.
func roundedMilliseconds(_ units: Int64) -> Int64 { (units + 5_000) / 10_000 }

/// The PCM bytes per second of the 16 kHz, 16-bit, mono WAV pieces the hand-off writes.
public let sapiPieceBytesPerSecond: UInt32 = 32_000
