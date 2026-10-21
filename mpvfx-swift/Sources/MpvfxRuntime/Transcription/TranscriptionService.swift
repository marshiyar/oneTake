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
// The transcription service interface and the one job every on-device recognizer runs through: refuse when
// unavailable, hand the clip's sound over as WAV pieces inside the project, recognise piece by piece, check the
// words, put them on one source time line, and remove the pieces whatever happens.
import Foundation

public protocol TranscriptionService: Sendable {
    func availability(locale: String) -> TranscriptionAvailability
    func supportedLocales() -> [String]
    /// Runs off the calling thread. `progress` reports pieces done out of the total; `cancel` stops the job between
    /// pieces and inside one (the recognizer's own cancel), ending it with `TranscriptionError.cancelled`.
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void,
                    cancel: MediaCancellation) async throws -> Transcript
}

/// One piece of a request's sound: 16-bit mono PCM WAV at `sampleRate`, at most 50 s, inside the job's private
/// folder. `firstSample` counts from the request's `sourceStart`; `startMs` / `endMs` are its source-media span.
public struct TranscriptionPiece: Equatable, Sendable {
    public var index: Int
    public var path: String
    public var firstSample: Int
    public var sampleCount: Int
    public var sampleRate: Int
    public var startMs: Int
    public var endMs: Int
    public var durationMs: Int { endMs - startMs }
}

/// What an on-device adapter (macOS, Windows) implements: availability, and the words of one WAV piece with times
/// in milliseconds from the piece's first sample. Conforming gives it `transcribe` through `TranscriptionJob`.
public protocol SpeechPieceRecognizer: TranscriptionService {
    func recognise(_ piece: TranscriptionPiece, locale: String, cancel: MediaCancellation) async throws -> [RecognisedWord]
}

extension SpeechPieceRecognizer {
    public func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void,
                           cancel: MediaCancellation) async throws -> Transcript {
        try await TranscriptionJob(request: request, recognizer: self, progress: progress, cancel: cancel).run()
    }
}

/// The service of a system without an on-device recognizer: always unavailable, and a request is refused before
/// any audio is read.
public struct UnavailableTranscriptionService: TranscriptionService {
    public let reason: TranscriptionUnavailableReason
    public init(reason: TranscriptionUnavailableReason) { self.reason = reason }
    public func availability(locale: String) -> TranscriptionAvailability { .unavailable(reason) }
    public func supportedLocales() -> [String] { [] }
    public func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void,
                           cancel: MediaCancellation) async throws -> Transcript {
        throw TranscriptionError.unavailable(reason)
    }
}

/// This system's service: the Speech framework's on-device recognizer on macOS. Linux has no on-device speech
/// recognition, and Windows reports the same until its adapter lands (TODO(#344) the Windows desktop recognizer).
public func defaultTranscriptionService() -> TranscriptionService {
    #if os(macOS)
    return makeMacSpeechTranscriptionService()
    #else
    return UnavailableTranscriptionService(reason: .platformHasNoOnDeviceRecognizer)
    #endif
}

/// One run of `transcribe` for a piece recognizer. `removeFolder` deletes the job's temporary folder; tests replace
/// it to make the removal fail.
struct TranscriptionJob<Recognizer: SpeechPieceRecognizer> {
    var request: TranscriptionRequest
    var recognizer: Recognizer
    var progress: @Sendable (TranscriptionProgress) -> Void
    var cancel: MediaCancellation
    var removeFolder: @Sendable (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }

    func run() async throws -> Transcript {
        try await withTaskCancellationHandler {
            try await runUncancelled()
        } onCancel: { [cancel] in cancel.cancel() }
    }

    private func runUncancelled() async throws -> Transcript {
        if cancel.isCancelled { throw TranscriptionError.cancelled }
        try TranscriptionAudioHandoff.validate(request)
        if case .unavailable(let reason) = recognizer.availability(locale: request.locale) {
            throw TranscriptionError.unavailable(reason)
        }
        let folder = try TranscriptionAudioHandoff.makeFolder(projectRoot: request.projectRoot)
        let outcome: Result<[RecognisedWord], Error>
        do { outcome = .success(try await recogniseAll(in: folder)) } catch { outcome = .failure(error) }
        let removal: Error?
        do { try removeFolder(folder); removal = nil } catch { removal = error }
        let words = try outcome.get()
        if removal != nil { throw TranscriptionError.temporaryFilesNotRemoved(folder) }
        guard !words.isEmpty else { throw TranscriptionError.noSpeechFound(request.clipName) }
        return Transcript(words: words, locale: request.locale)
    }

    private func recogniseAll(in folder: String) async throws -> [RecognisedWord] {
        let pieces = try await TranscriptionAudioHandoff.writePiecesOffThread(request, folder: folder, cancel: cancel)
        progress(TranscriptionProgress(piecesDone: 0, piecesTotal: pieces.count))
        var words: [RecognisedWord] = []
        for piece in pieces {
            if cancel.isCancelled { throw TranscriptionError.cancelled }
            let heard: [RecognisedWord]
            do { heard = try await recognizer.recognise(piece, locale: request.locale, cancel: cancel) }
            catch { throw cancel.isCancelled ? TranscriptionError.cancelled : recognizerError(error) }
            if cancel.isCancelled { throw TranscriptionError.cancelled }
            words += try placeOnSourceTimeLine(heard, piece: piece, after: words.last?.endMs ?? Int.min)
            progress(TranscriptionProgress(piecesDone: piece.index + 1, piecesTotal: pieces.count))
        }
        return words
    }
}

/// A recognizer's error as a `TranscriptionError`: its own typed errors pass through, an abort is a cancel, and
/// anything else is a recognizer failure with the error's text.
func recognizerError(_ error: Error) -> TranscriptionError {
    if let typed = error as? TranscriptionError { return typed }
    if error is MediaAbortError || error is CancellationError { return .cancelled }
    let ns = error as NSError
    return .recognizerFailed(code: ns.code, message: String(describing: error))
}

/// `heard` (times from the piece's first sample) moved to source milliseconds, after checking every word: text not
/// blank, 0 <= start <= end <= the piece's length, confidence in 0 ... 1, and each word starting at or after the end
/// of the one before (`previousEnd`, carried across pieces). Any violation refuses the whole result.
func placeOnSourceTimeLine(_ heard: [RecognisedWord], piece: TranscriptionPiece, after previousEnd: Int) throws -> [RecognisedWord] {
    var placed: [RecognisedWord] = []
    placed.reserveCapacity(heard.count)
    var lastEnd = previousEnd
    for (n, word) in heard.enumerated() {
        let at = "word \(n + 1) of piece \(piece.index + 1)"
        if word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TranscriptionError.invalidResult("\(at) is blank") }
        if word.endMs < word.startMs { throw TranscriptionError.invalidResult("\(at) ends before it starts") }
        if word.startMs < 0 || word.endMs > piece.durationMs {
            throw TranscriptionError.invalidResult("\(at) lies outside the piece's \(piece.durationMs) ms")
        }
        if let c = word.confidence, !(c.isFinite && c >= 0 && c <= 1) {
            throw TranscriptionError.invalidResult("\(at) has confidence \(c), outside 0 to 1")
        }
        let moved = RecognisedWord(text: word.text, startMs: piece.startMs + word.startMs, endMs: piece.startMs + word.endMs,
                                   confidence: word.confidence)
        if moved.startMs < lastEnd { throw TranscriptionError.invalidResult("\(at) overlaps or precedes the word before it") }
        lastEnd = moved.endMs
        placed.append(moved)
    }
    return placed
}
