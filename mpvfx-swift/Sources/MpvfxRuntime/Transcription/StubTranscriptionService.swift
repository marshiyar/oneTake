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
// The test double of a transcription service: the real hand-off (decode, pieces in the project, cleanup) with a
// scripted recognizer instead of the system's. Tests of the service and of the command built on it use it.
import Foundation

public final class StubTranscriptionService: SpeechPieceRecognizer, @unchecked Sendable {
    /// What the stub does with one piece.
    public enum PieceScript: Sendable {
        /// Return these words, times in milliseconds from the piece's first sample.
        case words([RecognisedWord])
        /// Fail as the system recognizer would.
        case fail(code: Int, message: String)
        /// Throw this error from the recognizer.
        case throwing(TranscriptionError)
        /// Wait until the job is cancelled.
        case stall
    }

    /// One piece as the stub received it: the piece, the WAV bytes on disk at that moment, and whether the call came
    /// on the main thread.
    public struct Received: Sendable {
        public var piece: TranscriptionPiece
        public var wav: Data
        public var onMainThread: Bool
    }

    private let reported: TranscriptionAvailability
    private let locales: [String]
    private let script: @Sendable (TranscriptionPiece) -> PieceScript
    private let onPiece: @Sendable (TranscriptionPiece) -> Void
    private let lock = NSLock()
    private var receivedPieces: [Received] = []

    /// `script` decides each piece (by default no words); `onPiece` runs as a piece arrives, before the script.
    public init(availability: TranscriptionAvailability = .available, locales: [String] = ["en-US"],
                script: @escaping @Sendable (TranscriptionPiece) -> PieceScript = { _ in .words([]) },
                onPiece: @escaping @Sendable (TranscriptionPiece) -> Void = { _ in }) {
        reported = availability; self.locales = locales; self.script = script; self.onPiece = onPiece
    }

    /// Every piece received so far, in order.
    public var received: [Received] { lock.lock(); defer { lock.unlock() }; return receivedPieces }

    private func append(_ record: Received) { lock.lock(); defer { lock.unlock() }; receivedPieces.append(record) }

    public func availability(locale: String) -> TranscriptionAvailability { reported }
    public func supportedLocales() -> [String] { locales }

    public func recognise(_ piece: TranscriptionPiece, locale: String, cancel: MediaCancellation) async throws -> [RecognisedWord] {
        let wav = try Data(contentsOf: URL(fileURLWithPath: piece.path))
        let record = Received(piece: piece, wav: wav, onMainThread: Thread.isMainThread)
        append(record)
        onPiece(piece)
        switch script(piece) {
        case .words(let words): return words
        case .fail(let code, let message): throw TranscriptionError.recognizerFailed(code: code, message: message)
        case .throwing(let error): throw error
        case .stall:
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
                cancel.onCancel { resume.resume(throwing: TranscriptionError.cancelled) }
            }
            return []
        }
    }
}
