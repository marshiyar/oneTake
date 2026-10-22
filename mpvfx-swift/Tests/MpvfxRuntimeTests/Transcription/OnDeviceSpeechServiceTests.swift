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
// Speech to captions, macOS adapter (#343): the adapter logic over a fake backend, so it runs on every OS. The
// Speech framework itself is checked only on macOS (the request factory).
import Foundation
import XCTest
@testable import MpvfxRuntime
#if os(macOS)
import Speech
#endif

final class OnDeviceSpeechServiceTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeMediaTempDir("mpvfx-ondevice-") }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    final class FakeBackend: OnDeviceSpeechBackend, @unchecked Sendable {
        private let lock = NSLock()
        var status: SpeechAuthorization
        var answer: SpeechAuthorization
        var recognizer = true
        var onDevice = true
        var segments: [SpeechSegment] = []
        private(set) var asked = 0
        private(set) var recognised = 0
        init(status: SpeechAuthorization = .authorized, answer: SpeechAuthorization = .authorized) { self.status = status; self.answer = answer }
        func authorization() -> SpeechAuthorization { lock.lock(); defer { lock.unlock() }; return status }
        func requestAuthorization() async -> SpeechAuthorization { bumpAsked() }
        private func bumpAsked() -> SpeechAuthorization { lock.lock(); defer { lock.unlock() }; asked += 1; status = answer; return answer }
        func onDeviceLocales() -> [String] { onDevice ? ["en-US"] : [] }
        func hasRecognizer(locale: String) -> Bool { recognizer }
        func supportsOnDevice(locale: String) -> Bool { onDevice }
        func recognise(path: String, locale: String, cancel: MediaCancellation) async throws -> [SpeechSegment] {
            bumpRecognised(); return segments
        }
        private func bumpRecognised() { lock.lock(); recognised += 1; lock.unlock() }
    }

    private func service(_ backend: FakeBackend) -> OnDeviceSpeechService { OnDeviceSpeechService(backend: backend, settingPath: macSpeechSettingPath) }

    private func piece() -> TranscriptionPiece {
        TranscriptionPiece(index: 0, path: root + "/p.wav", firstSample: 0, sampleCount: 16_000, sampleRate: 16_000, startMs: 0, endMs: 1000)
    }

    // A1: segment values (seconds) to words, with the piece offset.
    func testSegmentsBecomeWordsWithThePieceOffset() throws {
        let words = try recognisedWords(from: [SpeechSegment(text: "Hello", timestamp: 0.5, duration: 0.25, confidence: 0.9),
                                               SpeechSegment(text: " ", timestamp: 0.8, duration: 0.1),
                                               SpeechSegment(text: "world", timestamp: 0.8004, duration: 0.3)], pieceStartMs: 10_000)
        XCTAssertEqual(words, [RecognisedWord(text: "Hello", startMs: 10_500, endMs: 10_750, confidence: 0.9),
                               RecognisedWord(text: "world", startMs: 10_800, endMs: 11_100)])
        for bad in [-1.0, .nan, .infinity] {
            XCTAssertThrowsError(try recognisedWords(from: [SpeechSegment(text: "x", timestamp: bad, duration: 1)])) {
                guard case .invalidResult? = $0 as? TranscriptionError else { return XCTFail("\($0)") }
            }
        }
    }

    // A2: without on-device support no recognition is attempted.
    func testNoOnDeviceSupportIsNoModelForTheLanguageAndNothingIsRecognised() async {
        let backend = FakeBackend()
        backend.onDevice = false
        let s = service(backend)
        XCTAssertEqual(s.availability(locale: "fr-FR"), .unavailable(.noOnDeviceModelForLanguage("fr-FR")))
        XCTAssertEqual(s.supportedLocales(), [])
        do { _ = try await s.recognise(piece(), locale: "fr-FR", cancel: MediaCancellation()); XCTFail("recognised") }
        catch { XCTAssertEqual(error as? TranscriptionError, .unavailable(.noOnDeviceModelForLanguage("fr-FR"))) }
        XCTAssertEqual(backend.recognised, 0)
        backend.onDevice = true; backend.recognizer = false
        XCTAssertEqual(s.availability(locale: "xx"), .unavailable(.noOnDeviceModelForLanguage("xx")))
    }

    // A3: each authorization status maps to its availability.
    func testEachAuthorizationStatusMapsToItsAvailability() {
        let cases: [(SpeechAuthorization, TranscriptionAvailability)] = [
            (.authorized, .available), (.notDetermined, .available),
            (.denied, .unavailable(.permissionDenied(settingPath: "System Settings > Privacy & Security > Speech Recognition"))),
            (.restricted, .unavailable(.restricted)),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(service(FakeBackend(status: status)).availability(locale: "en-US"), expected, "\(status)")
        }
    }

    func testPermissionIsAskedOnFirstUseNotWhenAvailabilityIsRead() async throws {
        let backend = FakeBackend(status: .notDetermined)
        backend.segments = [SpeechSegment(text: "hi", timestamp: 0, duration: 0.2)]
        let s = service(backend)
        _ = s.availability(locale: "en-US"); _ = s.supportedLocales()
        XCTAssertEqual(backend.asked, 0, "reading availability never prompts")
        let words = try await s.recognise(piece(), locale: "en-US", cancel: MediaCancellation())
        XCTAssertEqual(words.map(\.text), ["hi"])
        XCTAssertEqual(backend.asked, 1)
        _ = try await s.recognise(piece(), locale: "en-US", cancel: MediaCancellation())
        XCTAssertEqual(backend.asked, 1, "asked once")
    }

    func testRefusingThePermissionPromptEndsUnavailableWithoutRecognising() async {
        let backend = FakeBackend(status: .notDetermined, answer: .denied)
        do { _ = try await service(backend).recognise(piece(), locale: "en-US", cancel: MediaCancellation()); XCTFail("recognised") }
        catch { XCTAssertEqual(error as? TranscriptionError, .unavailable(.permissionDenied(settingPath: macSpeechSettingPath))) }
        XCTAssertEqual(backend.recognised, 0)
    }

    func testAJobThroughTheServiceReturnsWordsOnTheSourceTimeLine() async throws {
        try TestMedia.wav([Float](repeating: 0.2, count: 16_000 * 4), rate: 16_000, channels: 1).write(to: URL(fileURLWithPath: root + "/a.wav"))
        let backend = FakeBackend()
        backend.segments = [SpeechSegment(text: "one", timestamp: 0.5, duration: 0.5), SpeechSegment(text: "two", timestamp: 1.5, duration: 0.5)]
        let request = TranscriptionRequest(projectRoot: root, clip: TranscriptionClip(source: "a.wav", sourceStart: 1, sourceDuration: 3, name: "A"), locale: "en-US")
        let transcript = try await service(backend).transcribe(request, progress: { _ in }, cancel: MediaCancellation())
        XCTAssertEqual(transcript.words.map(\.startMs), [1500, 2500])
        XCTAssertEqual(backend.recognised, 1)
    }

    // A5: the app bundle's Info.plist carries the speech usage description with our wording.
    func testThePackagingScriptWritesTheSpeechUsageDescription() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packaging/macos/package.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("<key>NSSpeechRecognitionUsageDescription</key><string>MpVFX turns the speech in your clips into captions on this Mac. Audio is not sent anywhere.</string>"))
    }

    #if os(macOS)
    // A2 on the real framework: every request is on-device and final-only.
    func testEveryRequestTheMacAdapterBuildsIsOnDeviceOnly() {
        let request = SFSpeechBackend.makeRequest(url: URL(fileURLWithPath: root + "/p.wav"))
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertFalse(request.shouldReportPartialResults)
    }
    #endif
}
