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
// Speech to captions, Windows adapter (#344): the value conversion and the source rules run on every OS; the
// recognizer itself only on Windows, where the runner's installed recognizers decide which branch is asserted.
import Foundation
import XCTest
@testable import MpvfxRuntime
#if os(Windows)
import CMpvfxWin32
#endif

final class WindowsSpeechTests: XCTestCase {
    // A1: phrase offsets (100 ns units) and the phrase's stream position become milliseconds.
    func testPhraseElementOffsetsBecomeMilliseconds() throws {
        let phraseStart = Int64(2_500_000) // 250 ms into the piece
        let words = try recognisedWords(fromSapi: [
            SapiPhraseWord(text: "hello", offset100ns: 0, duration100ns: 3_000_000),
            SapiPhraseWord(text: " ", offset100ns: 3_000_000, duration100ns: 10),
            SapiPhraseWord(text: "world", offset100ns: 3_004_999, duration100ns: 4_000_000),
        ], phraseStart100ns: phraseStart)
        XCTAssertEqual(words, [RecognisedWord(text: "hello", startMs: 250, endMs: 550),
                               RecognisedWord(text: "world", startMs: 550, endMs: 950)])
        XCTAssertThrowsError(try recognisedWords(fromSapi: [SapiPhraseWord(text: "x", offset100ns: -1, duration100ns: 1)], phraseStart100ns: 0))
        XCTAssertThrowsError(try recognisedWords(fromSapi: [SapiPhraseWord(text: "x", offset100ns: Int64.max, duration100ns: 5)], phraseStart100ns: 1))
        XCTAssertEqual(sapiPieceBytesPerSecond, 16_000 * 2, "16 kHz, 16-bit, mono")
    }

    // A5: the adapter uses only the in-process recognizer and never the network-backed speech APIs.
    func testTheAdapterSourcesNameNoNetworkSpeechApi() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = [sources.appendingPathComponent("CMpvfxWin32/speech_recognize.cpp"),
                     sources.appendingPathComponent("MpvfxRuntime/Transcription/WindowsSpeechTranscriptionService.swift")]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["Windows.Media.SpeechRecognition", "SpSharedRecognizer", "SpeechRecognizer.CompileConstraints", "WebSearch", "SPTOPIC"] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) names \(banned)")
            }
        }
        let cpp = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(cpp.contains("SpInprocRecognizer"))
        XCTAssertTrue(cpp.contains("LoadDictation(nullptr, SPLO_STATIC)"))
        XCTAssertTrue(cpp.contains("BindToFile"))
    }

    #if os(Windows)
    // A2: with no recognizer for the language the answer is recognizerNotInstalled and no object is left held.
    func testAvailabilityIsAnswerFromTheInstalledRecognizersAndLeaksNothing() {
        let service = WindowsSpeechTranscriptionService()
        let availability = service.availability(locale: "en-US")
        if service.supportedLocales().contains(where: { $0.hasPrefix("en") }) {
            XCTAssertEqual(availability, .available)
        } else {
            XCTAssertEqual(availability, .unavailable(.recognizerNotInstalled("en-US")))
        }
        XCTAssertEqual(service.availability(locale: "zz-ZZ-nonsense"), .unavailable(.recognizerNotInstalled("zz-ZZ-nonsense")))
        XCTAssertEqual(mpvfx_speech_live_objects(), 0)
    }

    // A4: a cancelled recognition returns cancelled and releases every COM object (the C seam counts them).
    func testACancelledRecognitionReleasesEveryObject() async throws {
        let root = try makeMediaTempDir("mpvfx-sapi-")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try TestMedia.wav([Float](repeating: 0.1, count: 16_000), rate: 16_000, channels: 1).write(to: URL(fileURLWithPath: root + "/p.wav"))
        let cancel = MediaCancellation()
        cancel.cancel()
        let piece = TranscriptionPiece(index: 0, path: root + "/p.wav", firstSample: 0, sampleCount: 16_000, sampleRate: 16_000, startMs: 0, endMs: 1000)
        do { _ = try await WindowsSpeechTranscriptionService().recognise(piece, locale: "en-US", cancel: cancel); XCTFail("recognised") }
        catch TranscriptionError.cancelled {} catch TranscriptionError.unavailable(_) {}
        XCTAssertEqual(mpvfx_speech_live_objects(), 0)
    }
    #endif
}
