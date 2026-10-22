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
// The speech synthesis test double: instead of a voice it writes a sine tone whose length follows the text length
// and the rate, and whose frequency follows the pitch, so tests on every OS drive the whole narration path (validate,
// speak to a temporary WAV, publish into the project, place the clip) without a system voice.
import Foundation

public struct StubSpeechSynthesisService: SpeechSynthesisService {
    /// Seconds of tone per character at rate 1.
    public static let secondsPerCharacter = 0.05
    public var installedVoices: [SystemVoice]
    public var unavailableReason: SynthesisUnavailableReason?

    public init(voices: [SystemVoice] = [SystemVoice(id: "stub.voice.a", name: "Stub A", locale: "en-US")],
                unavailableReason: SynthesisUnavailableReason? = nil) {
        installedVoices = voices; self.unavailableReason = unavailableReason
    }

    public func availability() -> SynthesisAvailability {
        if let unavailableReason { return .unavailable(unavailableReason) }
        return installedVoices.isEmpty ? .unavailable(.noVoices) : .available
    }

    public func voices() -> [SystemVoice] { unavailableReason == nil ? installedVoices : [] }

    /// Sample frames at 48 kHz the stub writes for `request`: text length × `secondsPerCharacter` ÷ rate.
    public static func samples(for request: SynthesisRequest) -> Int {
        Int((Double(request.text.count) * secondsPerCharacter / request.rate * Double(NarrationWAV.sampleRate)).rounded(.down))
    }

    public func synthesize(_ request: SynthesisRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void,
                           cancel: SynthesisCancellation) async throws -> SynthesisResult {
        if case .unavailable(let reason) = availability() { throw SynthesisError.unavailable(reason) }
        try validateSynthesisRequest(request)
        guard installedVoices.contains(where: { $0.id == request.voiceId }) else {
            throw SynthesisError.unavailable(.voiceMissing(id: request.voiceId, name: ""))
        }
        progress(0)
        let count = Self.samples(for: request)
        let hz = 220 * pow(2, request.pitch / 12)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            if i % 48_000 == 0 && cancel.isCancelled { throw SynthesisError.cancelled }
            samples[i] = Int16((0.25 * 32767 * sin(2 * Double.pi * hz * Double(i) / Double(NarrationWAV.sampleRate))).rounded())
        }
        if cancel.isCancelled { throw SynthesisError.cancelled }
        try NarrationWAV.write(samples, to: url)
        progress(1)
        return SynthesisResult(durationFrames48k: count)
    }
}
