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
// Windows speech to captions: the desktop speech recognizer of the Speech API (SAPI 5), in this process, reading the
// WAV piece from disk (Sources/CMpvfxWin32/speech_recognize.cpp). The audio never leaves the computer. A system
// without an installed recognizer for the language reads as unavailable, never as a failure.
#if os(Windows)
import CMpvfxWin32
import Foundation

/// Where Windows keeps its speech recognizers.
public let windowsSpeechSettingPath = "Settings > Time & language > Speech"

public final class WindowsSpeechTranscriptionService: SpeechPieceRecognizer, @unchecked Sendable {
    public init() {}

    private static func lcid(_ locale: String) -> UInt32? {
        var id: UInt32 = 0
        let hr = locale.utf16CString.withUnsafeBufferPointer { name in
            name.baseAddress!.withMemoryRebound(to: UInt16.self, capacity: name.count) { mpvfx_speech_locale_lcid($0, &id) }
        }
        return hr >= 0 ? id : nil
    }

    public func availability(locale: String) -> TranscriptionAvailability {
        var installed: Int32 = 0
        guard let id = Self.lcid(locale), mpvfx_speech_recognizer_installed(id, &installed) >= 0, installed != 0 else {
            return .unavailable(.recognizerNotInstalled(locale))
        }
        return .available
    }

    public func supportedLocales() -> [String] {
        final class Collector { var names: [String] = [] }
        let collector = Collector()
        let hr = mpvfx_speech_languages({ context, name in
            guard let context, let name else { return }
            Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().names.append(String(decoding: UnsafeBufferPointer(start: name, count: wcslen16(name)), as: UTF16.self))
        }, Unmanaged.passUnretained(collector).toOpaque())
        return hr >= 0 ? Array(Set(collector.names)).sorted() : []
    }

    public func recognise(_ piece: TranscriptionPiece, locale: String, cancel: MediaCancellation) async throws -> [RecognisedWord] {
        guard let id = Self.lcid(locale) else { throw TranscriptionError.unavailable(.recognizerNotInstalled(locale)) }
        return try await withCheckedThrowingContinuation { (resume: CheckedContinuation<[RecognisedWord], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                resume.resume(with: Result { try Self.recogniseBlocking(path: piece.path, lcid: id, cancel: cancel) })
            }
        }
    }

    private final class Run {
        var words: [SapiPhraseWord] = []
        let cancel: MediaCancellation
        init(cancel: MediaCancellation) { self.cancel = cancel }
    }

    private static func recogniseBlocking(path: String, lcid: UInt32, cancel: MediaCancellation) throws -> [RecognisedWord] {
        let run = Run(cancel: cancel)
        let hr: Int32 = path.utf16CString.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: UInt16.self, capacity: p.count) { wide in
                mpvfx_speech_recognize(wide, lcid, sapiPieceBytesPerSecond, { context, text, length, start, duration in
                    guard let context, let text else { return }
                    let run = Unmanaged<Run>.fromOpaque(context).takeUnretainedValue()
                    run.words.append(SapiPhraseWord(text: String(decoding: UnsafeBufferPointer(start: text, count: Int(length)), as: UTF16.self),
                                                    offset100ns: start, duration100ns: duration))
                }, Unmanaged.passUnretained(run).toOpaque(), { context in
                    guard let context else { return 0 }
                    return Unmanaged<Run>.fromOpaque(context).takeUnretainedValue().cancel.isCancelled ? 1 : 0
                }, Unmanaged.passUnretained(run).toOpaque())
            }
        }
        if cancel.isCancelled || hr == Int32(bitPattern: 0x80004004) { throw TranscriptionError.cancelled }
        guard hr >= 0 else {
            throw TranscriptionError.recognizerFailed(code: Int(hr), message: "HRESULT 0x" + String(UInt32(bitPattern: hr), radix: 16, uppercase: true))
        }
        // Each phrase carries its own stream position, already added in the C layer, so the offsets here are absolute.
        return try recognisedWords(fromSapi: run.words, phraseStart100ns: 0)
    }
}

private func wcslen16(_ p: UnsafePointer<UInt16>) -> Int { var n = 0; while p[n] != 0 { n += 1 }; return n }

/// The Windows service: the in-process desktop recognizer.
public func makeWindowsSpeechTranscriptionService() -> TranscriptionService { WindowsSpeechTranscriptionService() }
#endif
