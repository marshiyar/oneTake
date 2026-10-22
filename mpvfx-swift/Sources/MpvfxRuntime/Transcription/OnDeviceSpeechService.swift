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
// The adapter logic shared by system recognizers that work on a WAV piece: what the user has allowed, whether the
// language can be recognised on this device, and how the recognizer's segments become words. The system calls are
// behind `OnDeviceSpeechBackend`, so this logic runs (and is tested) on every OS.
import Foundation

/// What the user, or a device policy, has decided about speech recognition for this app.
public enum SpeechAuthorization: Equatable, Sendable {
    case notDetermined, denied, restricted, authorized
}

/// One recognised word as a system recognizer reports it: seconds from the start of the piece.
public struct SpeechSegment: Equatable, Sendable {
    public var text: String
    public var timestamp: Double
    public var duration: Double
    public var confidence: Double?
    public init(text: String, timestamp: Double, duration: Double, confidence: Double? = nil) {
        self.text = text; self.timestamp = timestamp; self.duration = duration; self.confidence = confidence
    }
}

/// The system calls an on-device adapter needs. An implementation MUST keep audio on the device: it never builds a
/// request that may use a network service (the caller checks `supportsOnDevice` first).
public protocol OnDeviceSpeechBackend: Sendable {
    func authorization() -> SpeechAuthorization
    /// Asks the user once; returns the answer.
    func requestAuthorization() async -> SpeechAuthorization
    /// The languages that have a recognizer and recognise on the device.
    func onDeviceLocales() -> [String]
    /// Whether a recognizer exists for the language at all.
    func hasRecognizer(locale: String) -> Bool
    func supportsOnDevice(locale: String) -> Bool
    /// Final segments of the WAV file at `path`; cancelling `cancel` stops the recognition.
    func recognise(path: String, locale: String, cancel: MediaCancellation) async throws -> [SpeechSegment]
}

/// Where the user allows speech recognition on macOS.
public let macSpeechSettingPath = "System Settings > Privacy & Security > Speech Recognition"

/// Segments to words, in milliseconds from the piece start plus `pieceStartMs`. Blank segments are left out. A
/// time that is not finite or is negative is an `invalidResult`, never passed on.
public func recognisedWords(from segments: [SpeechSegment], pieceStartMs: Int = 0) throws -> [RecognisedWord] {
    var words: [RecognisedWord] = []
    for (n, segment) in segments.enumerated() {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        guard segment.timestamp.isFinite, segment.duration.isFinite, segment.timestamp >= 0, segment.duration >= 0,
              segment.timestamp < 1e9, segment.duration < 1e9 else {
            throw TranscriptionError.invalidResult("segment \(n + 1) has the time \(segment.timestamp) s for \(segment.duration) s")
        }
        let start = Int((segment.timestamp * 1000).rounded())
        let end = Int(((segment.timestamp + segment.duration) * 1000).rounded())
        words.append(RecognisedWord(text: text, startMs: pieceStartMs + start, endMs: pieceStartMs + end, confidence: segment.confidence))
    }
    return words
}

/// The availability each authorization status and language gives.
public func speechAvailability(authorization: SpeechAuthorization, hasRecognizer: Bool, supportsOnDevice: Bool,
                               locale: String, settingPath: String) -> TranscriptionAvailability {
    switch authorization {
    case .denied: return .unavailable(.permissionDenied(settingPath: settingPath))
    case .restricted: return .unavailable(.restricted)
    case .notDetermined, .authorized: break
    }
    return hasRecognizer && supportsOnDevice ? .available : .unavailable(.noOnDeviceModelForLanguage(locale))
}

/// A `SpeechPieceRecognizer` over a backend. Permission is asked the first time a piece is recognised, never at launch.
public final class OnDeviceSpeechService: SpeechPieceRecognizer, @unchecked Sendable {
    private let backend: OnDeviceSpeechBackend
    private let settingPath: String

    public init(backend: OnDeviceSpeechBackend, settingPath: String) { self.backend = backend; self.settingPath = settingPath }

    public func availability(locale: String) -> TranscriptionAvailability {
        speechAvailability(authorization: backend.authorization(), hasRecognizer: backend.hasRecognizer(locale: locale),
                           supportsOnDevice: backend.supportsOnDevice(locale: locale), locale: locale, settingPath: settingPath)
    }

    public func supportedLocales() -> [String] { backend.onDeviceLocales() }

    public func recognise(_ piece: TranscriptionPiece, locale: String, cancel: MediaCancellation) async throws -> [RecognisedWord] {
        if backend.authorization() == .notDetermined { _ = await backend.requestAuthorization() }
        // Checked again after the question, and right before recognising: no request is built unless it stays on the device.
        if case .unavailable(let reason) = availability(locale: locale) { throw TranscriptionError.unavailable(reason) }
        if cancel.isCancelled { throw TranscriptionError.cancelled }
        let segments = try await backend.recognise(path: piece.path, locale: locale, cancel: cancel)
        return try recognisedWords(from: segments)
    }
}
