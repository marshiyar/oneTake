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
// Narration from text: the record an audio clip made from typed text keeps (`clip.narration`), so the text can be
// edited and spoken again. The clip plays its WAV asset like any other audio clip; the record is read only when the
// narration is spoken again, never at playback or export time, so a machine without the voice plays the project the
// same way. A record whose `v` this version does not read is kept byte for byte, plays from its WAV, and turns
// speaking again off (`unreadNarrationNotice`).
import Foundation

/// The app's own narration scale, shared by every system voice adapter (each maps it onto its OS range).
public enum NativeNarrationScale {
    /// The record version this editor reads and writes.
    public static let version = 1
    /// Characters per narration clip (Swift `Character`s, what a person counts as letters).
    public static let textLimit = 20_000
    /// 1.0 is the voice's normal speed.
    public static let rateRange: ClosedRange<Double> = 0.5...2.0
    public static let defaultRate = 1.0
    /// Semitone-like steps around the voice's normal pitch (0).
    public static let pitchRange: ClosedRange<Double> = -12...12
    public static let defaultPitch = 0.0
}

/// A narration record this version reads (`v` 1).
public struct NativeClipNarration: Codable, Equatable, Sendable {
    public var text: String
    /// The system voice's identifier on the machine that spoke it.
    public var voiceId: String
    /// The voice's display name, shown when the voice is missing on another machine.
    public var voiceName: String
    /// nil is `NativeNarrationScale.defaultRate`; the default is never stored.
    public var rate: Double?
    /// nil is `NativeNarrationScale.defaultPitch`; the default is never stored.
    public var pitch: Double?
    /// Input key order and unknown keys of the record.
    public var spread = NativeSpreadKeys()
    static let known = ["v", "text", "voiceId", "voiceName", "rate", "pitch"]

    /// A record holding `rate` and `pitch` only when they differ from the defaults (absent stays absent).
    public init(text: String, voiceId: String, voiceName: String, rate: Double = NativeNarrationScale.defaultRate,
                pitch: Double = NativeNarrationScale.defaultPitch) {
        self.text = text; self.voiceId = voiceId; self.voiceName = voiceName
        self.rate = rate == NativeNarrationScale.defaultRate ? nil : rate
        self.pitch = pitch == NativeNarrationScale.defaultPitch ? nil : pitch
    }

    public var effectiveRate: Double { rate ?? NativeNarrationScale.defaultRate }
    public var effectivePitch: Double { pitch ?? NativeNarrationScale.defaultPitch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        text = try c.req(String.self, "text"); voiceId = try c.req(String.self, "voiceId")
        voiceName = try c.req(String.self, "voiceName")
        rate = try c.opt(Double.self, "rate"); pitch = try c.opt(Double.self, "pitch")
        spread = try decodeSpread(decoder, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k {
            case "v": try c.put(Double(NativeNarrationScale.version), k)
            case "text": try c.put(text, k)
            case "voiceId": try c.put(voiceId, k)
            case "voiceName": try c.put(voiceName, k)
            case "rate": try c.put(rate, k)
            default: try c.put(pitch, k)
            }
        }
    }
}

/// `clip.narration` as stored: a record this version reads, or one from a later version kept unchanged.
public enum NativeClipNarrationRecord: Codable, Equatable, Sendable {
    case current(NativeClipNarration)
    /// A record whose `v` is not `NativeNarrationScale.version`: written back exactly as read.
    case unread(NativeJSONValue)

    /// The narration this version can speak again; nil for an unread record.
    public var narration: NativeClipNarration? {
        if case .current(let n) = self { return n }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let raw = try NativeJSONValue(from: decoder)
        if raw["v"]?.numberValue == Double(NativeNarrationScale.version) {
            self = .current(try raw.decode(NativeClipNarration.self))
        } else {
            self = .unread(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .current(let n): try n.encode(to: encoder)
        case .unread(let raw): try raw.encode(to: encoder)
        }
    }
}

public extension NativeProjectDocument {
    /// Clips whose narration record comes from a later version (kept, played from the WAV, not spoken again).
    var unreadNarrationCount: Int {
        sequence.tracks.reduce(0) { n, track in
            n + track.clips.filter { if case .unread? = $0.narration { return true }; return false }.count
        }
    }

    /// The one notice shown on open when the document holds unread narration records; nil when it has none.
    var unreadNarrationNotice: String? {
        let n = unreadNarrationCount
        guard n > 0 else { return nil }
        return n == 1
            ? "1 narration clip from a newer version of the editor plays from its audio file; it cannot be spoken again here."
            : "\(n) narration clips from a newer version of the editor play from their audio files; they cannot be spoken again here."
    }
}

/// `clip.narration`: an object with a whole positive `v`. A `v` 1 record needs non-empty text within the limit, a
/// voice id, a voice name, and `rate` / `pitch` (when present) finite and inside the app scale; nothing is clamped.
/// A record with another `v` is kept unread. Only a clip of an audio asset can carry narration.
func validateNativeClipNarration(_ value: NativeJSONValue?, assetKind: String?, _ path: String,
                                 _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let value else { return }
    guard value.isRecord else { return pushIssue(&issues, .invalidNarration, path, "Narration must be an object") }
    if let assetKind, assetKind != "audio" {
        pushIssue(&issues, .invalidNarration, path, "Only a clip of an audio asset can carry narration")
    }
    guard let v = value["v"]?.numberValue, v.isFinite, v >= 1, v == v.rounded() else {
        return pushIssue(&issues, .invalidNarration, "\(path).v", "Narration version must be a whole number of at least 1")
    }
    guard v == Double(NativeNarrationScale.version) else { return }
    validateNarrationText(value["text"], "\(path).text", &issues)
    if !isNonEmptyString(value["voiceId"]) {
        pushIssue(&issues, .invalidNarration, "\(path).voiceId", "Narration voice ID must be a non-empty string")
    }
    if value["voiceName"]?.stringValue == nil {
        pushIssue(&issues, .invalidNarration, "\(path).voiceName", "Narration voice name must be a string")
    }
    for (key, range, label) in [("rate", NativeNarrationScale.rateRange, "rate"), ("pitch", NativeNarrationScale.pitchRange, "pitch")] {
        guard let raw = value[key] else { continue }
        if raw.numberValue.map({ $0.isFinite && range.contains($0) }) != true {
            pushIssue(&issues, .invalidNarration, "\(path).\(key)",
                      "Narration \(label) must be a finite number from \(jsNumberString(range.lowerBound)) to \(jsNumberString(range.upperBound))")
        }
    }
}

private func validateNarrationText(_ value: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let text = value?.stringValue else {
        return pushIssue(&issues, .invalidNarration, path, "Narration text must be a string")
    }
    if jsTrimmedIsEmpty(text) { pushIssue(&issues, .invalidNarration, path, "Narration text must not be empty") }
    if text.count > NativeNarrationScale.textLimit {
        pushIssue(&issues, .invalidNarration, path, "Narration text must be at most \(NativeNarrationScale.textLimit) characters")
    }
}
