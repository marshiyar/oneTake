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
// Narration from text: the speech synthesis interface every system voice adapter implements. A service turns text
// into a 48 kHz 16-bit PCM WAV with one of the voices installed on the machine; it has no network path, and it never
// runs at playback or export time (the WAV it wrote is the clip's sound). Rate and pitch are in the app's own scale
// (`NativeNarrationScale`); each adapter maps them onto its OS range and refuses, with the voice's range, a value the
// voice cannot reach instead of clamping it.
import Foundation
import MpvfxShared

/// One voice installed on the machine.
public struct SystemVoice: Equatable, Sendable {
    public var id: String
    public var name: String
    /// BCP 47 language tag, e.g. `en-GB`.
    public var locale: String
    /// The OS's own quality label (e.g. "enhanced"), when it gives one.
    public var quality: String?
    public init(id: String, name: String, locale: String, quality: String? = nil) {
        self.id = id; self.name = name; self.locale = locale; self.quality = quality
    }
}

public enum SynthesisUnavailableReason: Equatable, Sendable, CustomStringConvertible {
    /// The OS gives apps no built-in voice service (Linux today).
    case platformHasNoSystemVoices
    /// The voice service exists but no voice is installed.
    case noVoices
    /// The narration's voice is not installed on this machine (a project opened elsewhere).
    case voiceMissing(id: String, name: String)

    public var description: String {
        switch self {
        case .platformHasNoSystemVoices:
            return "Narration from text needs the system's built-in voices, which this system does not provide to apps."
        case .noVoices:
            return "Narration from text needs a system voice, and none is installed. Add a voice in the system settings."
        case .voiceMissing(_, let name):
            let shown = name.isEmpty ? "The voice this narration was spoken with" : "The voice \"\(name)\""
            return "\(shown) is not installed on this computer. The clip still plays; choose another voice to speak it again."
        }
    }
}

public enum SynthesisAvailability: Equatable, Sendable {
    case available
    case unavailable(SynthesisUnavailableReason)
}

/// What to speak, in the app's scale (`NativeNarrationScale`).
public struct SynthesisRequest: Equatable, Sendable {
    public var text: String
    public var voiceId: String
    /// 0.5…2.0; 1.0 is the voice's normal speed.
    public var rate: Double
    /// −12…+12 semitone-like steps; 0 is the voice's normal pitch.
    public var pitch: Double
    public init(text: String, voiceId: String, rate: Double = NativeNarrationScale.defaultRate,
                pitch: Double = NativeNarrationScale.defaultPitch) {
        self.text = text; self.voiceId = voiceId; self.rate = rate; self.pitch = pitch
    }
    public init(_ narration: NativeClipNarration) {
        self.init(text: narration.text, voiceId: narration.voiceId, rate: narration.effectiveRate, pitch: narration.effectivePitch)
    }
}

public struct SynthesisResult: Equatable, Sendable {
    /// Length of the written WAV in sample frames at 48 kHz.
    public var durationFrames48k: Int
    public init(durationFrames48k: Int) { self.durationFrames48k = durationFrames48k }
}

public enum SynthesisError: Error, Equatable, CustomStringConvertible {
    case unavailable(SynthesisUnavailableReason)
    case textEmpty
    case textTooLong(limit: Int)
    /// `rate` or `pitch` outside what the app scale or the voice allows; `range` is the allowed range in the app scale.
    case parameterOutOfRange(name: String, value: Double, range: ClosedRange<Double>)
    case cancelled
    case writeFailed(path: String, underlying: String)
    case synthesizerFailed(code: Int, message: String)

    public var description: String {
        switch self {
        case .unavailable(let reason): return reason.description
        case .textEmpty: return "Type the text to speak first."
        case .textTooLong(let limit): return "Narration text can be at most \(limit) characters per clip. Split it into several clips."
        case .parameterOutOfRange(let name, let value, let range):
            return "The \(name) \(jsNumberString(value)) is outside what this voice can do (\(jsNumberString(range.lowerBound)) to \(jsNumberString(range.upperBound)))."
        case .cancelled: return "Narration was cancelled."
        case .writeFailed(let path, let underlying): return "The narration audio could not be written to \(path): \(underlying)"
        case .synthesizerFailed(let code, let message): return "The system voice failed (\(code)): \(message)"
        }
    }
}

/// Cooperative cancellation shared with the media jobs (`MediaCancellation`).
public typealias SynthesisCancellation = MediaCancellation

public protocol SpeechSynthesisService: Sendable {
    func availability() -> SynthesisAvailability
    func voices() -> [SystemVoice]
    /// Writes the spoken `request` to `url` as a 48 kHz 16-bit PCM WAV. `progress` gets 0…1. A cancel throws
    /// `SynthesisError.cancelled`; every failure is a `SynthesisError`.
    func synthesize(_ request: SynthesisRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void,
                    cancel: SynthesisCancellation) async throws -> SynthesisResult
}

/// The checks every service applies before speaking, in the app scale: text present and within the limit, rate and
/// pitch finite and inside `NativeNarrationScale`. Adapters add their voice's narrower range on top.
public func validateSynthesisRequest(_ request: SynthesisRequest) throws {
    if request.text.allSatisfy({ $0.isWhitespace }) { throw SynthesisError.textEmpty }
    if request.text.count > NativeNarrationScale.textLimit { throw SynthesisError.textTooLong(limit: NativeNarrationScale.textLimit) }
    for (name, value, range) in [("rate", request.rate, NativeNarrationScale.rateRange), ("pitch", request.pitch, NativeNarrationScale.pitchRange)]
    where !(value.isFinite && range.contains(value)) {
        throw SynthesisError.parameterOutOfRange(name: name, value: value, range: range)
    }
}

/// A service that can never speak, for a platform without built-in voices: every call reports `reason`.
public struct UnavailableSpeechSynthesisService: SpeechSynthesisService {
    public let reason: SynthesisUnavailableReason
    public init(reason: SynthesisUnavailableReason) { self.reason = reason }
    public func availability() -> SynthesisAvailability { .unavailable(reason) }
    public func voices() -> [SystemVoice] { [] }
    public func synthesize(_ request: SynthesisRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void,
                           cancel: SynthesisCancellation) async throws -> SynthesisResult {
        throw SynthesisError.unavailable(reason)
    }
}

/// The machine's speech synthesis service. Linux has no built-in voice service an app can render to a file without a
/// new library (owner decision on #263), so it reports `platformHasNoSystemVoices`.
public func defaultSpeechSynthesisService() -> SpeechSynthesisService {
    // TODO(#350): the macOS system voices adapter; TODO(#351): the Windows one. Until they land every OS reports the
    // service as unavailable, and existing narration clips still play and export from their WAV.
    UnavailableSpeechSynthesisService(reason: .platformHasNoSystemVoices)
}
