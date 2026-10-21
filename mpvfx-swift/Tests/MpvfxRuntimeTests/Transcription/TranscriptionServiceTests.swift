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
// Speech to captions, step 1 (#341): the transcription service's hand-off, pieces, cleanup, availability and typed
// errors, driven through the stub recognizer. Fixtures are WAV files from TestMedia.wav: tone bursts and silences
// at known seconds, so every cut and every sample count is predictable.
import Foundation
import XCTest
@testable import MpvfxRuntime

final class TranscriptionServiceTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeMediaTempDir("mpvfx-transcribe-") }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    // MARK: fixtures

    /// `seconds` of mono audio at `rate`: a 440 Hz tone where `loud(second)` is true, else silence.
    private func writeWAV(_ name: String, seconds: Int, rate: Int, loud: (Double) -> Bool) throws {
        let samples = (0..<(seconds * rate)).map { i -> Float in
            let t = Double(i) / Double(rate)
            return loud(t) ? 0.5 * Float(sin(2 * .pi * 440 * t)) : 0
        }
        try TestMedia.wav(samples, rate: rate, channels: 1).write(to: URL(fileURLWithPath: root + "/" + name))
    }

    /// 3 minutes at 16 kHz, repeating 4 s of tone then 2 s of silence: a pause lies in every 5 s window.
    private func writeBursts() throws {
        try writeWAV("bursts.wav", seconds: 180, rate: 16_000) { $0.truncatingRemainder(dividingBy: 6) < 4 }
    }

    private func request(_ source: String, start: Double = 0, duration: Double, locale: String = "en-US") -> TranscriptionRequest {
        TranscriptionRequest(projectRoot: root, clip: TranscriptionClip(source: source, sourceStart: start, sourceDuration: duration,
                                                                         name: "Interview"), locale: locale)
    }

    /// Runs the job to its end on a background task, returning the transcript or the error.
    private func run(_ service: TranscriptionService, _ request: TranscriptionRequest, cancel: MediaCancellation = MediaCancellation(),
                     progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }) async -> Result<Transcript, Error> {
        do { return .success(try await service.transcribe(request, progress: progress, cancel: cancel)) }
        catch { return .failure(error) }
    }

    private func expectError(_ result: Result<Transcript, Error>, _ expected: TranscriptionError,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let transcript): XCTFail("expected \(expected), got \(transcript)", file: file, line: line)
        case .failure(let error): XCTAssertEqual(error as? TranscriptionError, expected, "\(error)", file: file, line: line)
        }
    }

    /// The `transcribe-*` folders left in the project.
    private func leftoverFolders() throws -> [String] {
        let tmp = root + "/.studio-render-tmp"
        guard FileManager.default.fileExists(atPath: tmp) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: tmp).filter { $0.hasPrefix("transcribe-") }
    }

    /// The WAV fields a recognizer relies on: channels, rate, bits and the sample count of `data`.
    private func wavFormat(_ wav: Data) -> (channels: Int, rate: Int, bits: Int, samples: Int) {
        let b = [UInt8](wav)
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        XCTAssertEqual(String(decoding: b[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: b[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(u32(40) + 44, b.count)
        return (u16(22), u32(24), u16(34), u32(40) / 2)
    }

    // MARK: A1 pieces at pauses, one time line

    func testA1ThreeMinutesSplitIntoPiecesOfAtMost50sCutInsidePausesOnOneTimeLine() async throws {
        try writeBursts()
        let word = RecognisedWord(text: "hello", startMs: 100, endMs: 400, confidence: 0.9)
        let stub = StubTranscriptionService(script: { _ in .words([word]) })
        let reported = ProgressLog()
        let transcript = try await run(stub, request("bursts.wav", duration: 180), progress: { reported.add($0) }).get()
        let pieces = stub.received.map(\.piece)
        XCTAssertEqual(pieces.count, 4)
        for (n, piece) in pieces.enumerated() {
            XCTAssertLessThanOrEqual(piece.sampleCount, 50 * 16_000, "piece \(n) is longer than 50 s")
            XCTAssertEqual(piece.firstSample, n == 0 ? 0 : pieces[n - 1].firstSample + pieces[n - 1].sampleCount, "pieces are contiguous")
            XCTAssertEqual(piece.startMs, n == 0 ? 0 : pieces[n - 1].endMs)
        }
        XCTAssertEqual(pieces.map(\.sampleCount).reduce(0, +), 180 * 16_000)
        // Every boundary falls inside a pause (4 ... 6 s of each 6 s period); with 1 s of tone either side of each
        // pause the middle of the pause is the cut: 47 s, 95 s, 143 s.
        for piece in pieces.dropFirst() {
            let seconds = Double(piece.firstSample) / 16_000
            XCTAssertGreaterThan(seconds.truncatingRemainder(dividingBy: 6), 4, "cut at \(seconds) s is not in a pause")
            XCTAssertEqual(seconds, (seconds / 6).rounded(.down) * 6 + 5, accuracy: 0.05)
        }
        XCTAssertEqual(transcript.words.map(\.startMs), pieces.map { $0.startMs + 100 })
        XCTAssertEqual(transcript.words.map(\.endMs), pieces.map { $0.startMs + 400 })
        XCTAssertEqual(transcript.words.map(\.startMs), [100, 47_100, 95_100, 143_100])
        XCTAssertEqual(transcript.locale, "en-US")
        XCTAssertEqual(reported.values.last, TranscriptionProgress(piecesDone: 4, piecesTotal: 4))
        XCTAssertEqual(reported.values.first, TranscriptionProgress(piecesDone: 0, piecesTotal: 4))
        XCTAssertEqual(try leftoverFolders(), [], "the pieces are removed when the job ends")
    }

    /// Without any pause the pieces are exactly 50 s, cut at the quietest 10 ms of the last 5 s.
    func testA1WithoutAPauseNearTheLimitAPieceIsCutWithinItsLast5s() async throws {
        try writeWAV("tone.wav", seconds: 120, rate: 16_000) { _ in true }
        let stub = StubTranscriptionService(script: { _ in .words([RecognisedWord(text: "a", startMs: 0, endMs: 10)]) })
        _ = try await run(stub, request("tone.wav", duration: 120)).get()
        let pieces = stub.received.map(\.piece)
        XCTAssertEqual(pieces.count, 3)
        for piece in pieces.dropLast() {
            XCTAssertLessThanOrEqual(piece.sampleCount, 50 * 16_000)
            XCTAssertGreaterThan(piece.sampleCount, 45 * 16_000)
        }
        XCTAssertEqual(pieces.map(\.sampleCount).reduce(0, +), 120 * 16_000)
    }

    // MARK: A2 the trimmed range, exactly

    func testA2AClipTrimmedTo10sTo40sHandsOverExactlyThatRange() async throws {
        // 48 kHz: silence to 10 s, tone 10 ... 40 s, silence after; the engine resamples to 16 kHz mono.
        try writeWAV("trimmed.wav", seconds: 45, rate: 48_000) { $0 >= 10 && $0 < 40 }
        let stub = StubTranscriptionService(script: { _ in .words([RecognisedWord(text: "x", startMs: 0, endMs: 1)]) })
        _ = try await run(stub, request("trimmed.wav", start: 10, duration: 30)).get()
        let received = stub.received
        XCTAssertEqual(received.count, 1)
        let format = wavFormat(received[0].wav)
        XCTAssertEqual(format.channels, 1); XCTAssertEqual(format.rate, 16_000); XCTAssertEqual(format.bits, 16)
        XCTAssertEqual(format.samples, 30 * 16_000, "exactly 30 s at 16 kHz")
        XCTAssertEqual(received[0].piece.sampleCount, 30 * 16_000)
        XCTAssertEqual(received[0].piece.startMs, 10_000)
        XCTAssertEqual(received[0].piece.endMs, 40_000)
        // The range is the tone: loud from its first 50 ms to its last.
        XCTAssertGreaterThan(rms(received[0].wav, samples: 100..<900), 0.2)
        XCTAssertGreaterThan(rms(received[0].wav, samples: (format.samples - 900)..<(format.samples - 100)), 0.2)
    }

    private func rms(_ wav: Data, samples: Range<Int>) -> Double {
        let b = [UInt8](wav)
        var sum = 0.0
        for i in samples {
            let v = Double(Int16(bitPattern: UInt16(b[44 + 2 * i]) | UInt16(b[45 + 2 * i]) << 8)) / 32_767
            sum += v * v
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    // MARK: A3 cancel inside piece 2

    func testA3CancelDuringPiece2StopsTheJobAsCancelledAndLeavesNoTemporaryFile() async throws {
        try writeWAV("long.wav", seconds: 120, rate: 16_000) { _ in true }
        let (entered, signal) = AsyncStream<Int>.makeStream()
        let stub = StubTranscriptionService(script: { $0.index == 1 ? .stall : .words([RecognisedWord(text: "a", startMs: 0, endMs: 5)]) },
                                            onPiece: { signal.yield($0.index) })
        let cancel = MediaCancellation()
        let job = Task { await run(stub, request("long.wav", duration: 120), cancel: cancel) }
        for await index in entered where index == 1 { break }
        XCTAssertEqual(try leftoverFolders().count, 1, "piece 2 is on disk while it is recognised")
        cancel.cancel()
        expectError(await job.value, .cancelled)
        XCTAssertEqual(stub.received.count, 2, "piece 3 is never started")
        XCTAssertEqual(try leftoverFolders(), [])
        XCTAssertEqual(TranscriptionError.cancelled.message, "Transcription was cancelled.")
    }

    func testCancellingTheSwiftTaskCancelsTheJob() async throws {
        try writeWAV("long.wav", seconds: 60, rate: 16_000) { _ in true }
        let (entered, signal) = AsyncStream<Int>.makeStream()
        let stub = StubTranscriptionService(script: { _ in .stall }, onPiece: { signal.yield($0.index) })
        let job = Task { await run(stub, request("long.wav", duration: 60)) }
        for await _ in entered { break }
        job.cancel()
        expectError(await job.value, .cancelled)
        XCTAssertEqual(try leftoverFolders(), [])
    }

    // MARK: A4 every reason and every error, with its message

    func testA4EachUnavailableReasonRefusesBeforeAnyAudioIsReadWithItsMessage() async throws {
        try writeBursts()
        let cases: [(TranscriptionUnavailableReason, String)] = [
            (.platformHasNoOnDeviceRecognizer,
             "Speech to captions needs the system's on-device speech recognition, which this system does not provide."),
            (.noOnDeviceModelForLanguage("fr-FR"), "French (France)"),
            (.permissionDenied(settingPath: "Privacy > Speech Recognition"), "Allow it in Privacy > Speech Recognition"),
            (.restricted, "turned off on this computer by a policy"),
            (.recognizerNotInstalled("de-DE"), "No speech recognizer for German (Germany) is installed"),
        ]
        for (reason, text) in cases {
            let stub = StubTranscriptionService(availability: .unavailable(reason))
            XCTAssertEqual(stub.availability(locale: "en-US"), .unavailable(reason))
            let result = await run(stub, request("bursts.wav", duration: 10))
            expectError(result, .unavailable(reason))
            XCTAssertTrue(reason.message.contains(text), reason.message)
            XCTAssertEqual(TranscriptionError.unavailable(reason).message, reason.message)
            XCTAssertEqual(stub.received.count, 0, "no audio is handed over")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.studio-render-tmp"), "nothing is written")
        }
    }

    func testA4MediaUnreadableForAMissingFileANonMediaFileAndAFileOutsideTheProject() async throws {
        try Data("not a sound".utf8).write(to: URL(fileURLWithPath: root + "/notes.wav"))
        let outside = root + "-outside.wav"
        try TestMedia.wav(TestMedia.tone(seconds: 1, rate: 16_000), rate: 16_000, channels: 1).write(to: URL(fileURLWithPath: outside))
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/escape.wav", withDestinationPath: outside)
        for name in ["missing.wav", "notes.wav", "escape.wav", "../outside.wav"] {
            let stub = StubTranscriptionService()
            expectError(await run(stub, request(name, duration: 1)), .mediaUnreadable(PosixPath.basename(name)))
            XCTAssertEqual(stub.received.count, 0)
        }
        XCTAssertEqual(TranscriptionError.mediaUnreadable("notes.wav").message,
                       "“notes.wav” cannot be read, so its speech cannot be transcribed. Check that the file is still in the project and plays.")
        XCTAssertEqual(try leftoverFolders(), [])
    }

    func testA4NoSpeechFoundWhenNoWordIsHeardOrTheClipHasNoSound() async throws {
        try writeBursts()
        let silent = StubTranscriptionService(script: { _ in .words([]) })
        expectError(await run(silent, request("bursts.wav", duration: 20)), .noSpeechFound("Interview"))
        XCTAssertEqual(silent.received.count, 1)
        let black = TestMedia.solid((0, 0, 0), width: 16, height: 16)
        try TestMedia.writeMOV(root + "/mute.mov", frames: Array(repeating: black, count: 10), width: 16, height: 16)
        expectError(await run(StubTranscriptionService(), request("mute.mov", duration: 1)), .noSpeechFound("Interview"))
        XCTAssertEqual(TranscriptionError.noSpeechFound("Interview").message, "No speech was found in “Interview”.")
        XCTAssertEqual(try leftoverFolders(), [])
    }

    func testA4RecognizerFailedCarriesTheSystemCodeAndMessage() async throws {
        try writeBursts()
        let stub = StubTranscriptionService(script: { _ in .fail(code: 203, message: "Retry") })
        expectError(await run(stub, request("bursts.wav", duration: 10)), .recognizerFailed(code: 203, message: "Retry"))
        XCTAssertEqual(TranscriptionError.recognizerFailed(code: 203, message: "Retry").message,
                       "The system's speech recognition failed (error 203): Retry")
        XCTAssertEqual(recognizerError(NSError(domain: "kAFAssistantErrorDomain", code: 1110)),
                       .recognizerFailed(code: 1110, message: String(describing: NSError(domain: "kAFAssistantErrorDomain", code: 1110))))
        XCTAssertEqual(recognizerError(CancellationError()), .cancelled)
        XCTAssertEqual(try leftoverFolders(), [])
    }

    func testA4InvalidRequestForHostileRangesAndLanguageTags() async throws {
        try writeBursts()
        let hostile: [TranscriptionRequest] = [
            request("bursts.wav", start: -1, duration: 10), request("bursts.wav", start: .nan, duration: 10),
            request("bursts.wav", start: .infinity, duration: 10), request("bursts.wav", duration: 0),
            request("bursts.wav", duration: -5), request("bursts.wav", duration: .infinity), request("bursts.wav", duration: 1e300),
            request("bursts.wav", duration: 10, locale: ""), request("bursts.wav", duration: 10, locale: "en US"),
            request("bursts.wav", duration: 10, locale: "../../etc"), request("bursts.wav", duration: 10, locale: String(repeating: "a", count: 65)),
            request("bursts.wav", start: 500, duration: 10),
        ]
        for bad in hostile {
            let stub = StubTranscriptionService()
            let result = await run(stub, bad)
            guard case .failure(let error) = result, case .invalidRequest(let detail)? = error as? TranscriptionError else {
                XCTFail("\(bad) was not refused as an invalid request: \(result)"); continue
            }
            XCTAssertEqual((error as? TranscriptionError)?.message, "This transcription request is not valid: \(detail).")
            XCTAssertEqual(stub.received.count, 0)
        }
        var missingRoot = request("bursts.wav", duration: 10); missingRoot.projectRoot = root + "/nowhere"
        guard case .failure(let error) = await run(StubTranscriptionService(), missingRoot),
              case .invalidRequest? = error as? TranscriptionError else { return XCTFail("a missing project folder is refused") }
        XCTAssertEqual(try leftoverFolders(), [])
    }

    func testA4TheTemporaryFolderMustStayInsideTheProject() async throws {
        try writeBursts()
        let outside = try makeMediaTempDir("mpvfx-transcribe-outside-")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/.studio-render-tmp", withDestinationPath: outside)
        let stub = StubTranscriptionService(script: { _ in .words([RecognisedWord(text: "a", startMs: 0, endMs: 5)]) })
        let result = await run(stub, request("bursts.wav", duration: 10))
        guard case .failure(let error) = result, case .invalidRequest? = error as? TranscriptionError else {
            return XCTFail("audio was written outside the project: \(result)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [])
        XCTAssertEqual(stub.received.count, 0)
    }

    func testA4TemporaryAudioUnwritableWhenThePieceFolderCannotBeMade() async throws {
        try writeBursts()
        // A file where the temporary folder goes: the folder cannot be made, whoever runs the test.
        try Data().write(to: URL(fileURLWithPath: root + "/.studio-render-tmp"))
        let result = await run(StubTranscriptionService(), request("bursts.wav", duration: 10))
        guard case .failure(let error) = result, case .temporaryAudioUnwritable(let detail)? = error as? TranscriptionError else {
            return XCTFail("expected temporaryAudioUnwritable, got \(result)")
        }
        XCTAssertTrue((error as? TranscriptionError)?.message.hasPrefix("The audio to transcribe cannot be written in the project folder (\(detail))") == true)
    }

    func testA4TemporaryFilesNotRemovedWhenTheCleanupFails() async throws {
        try writeBursts()
        let stub = StubTranscriptionService(script: { _ in .words([RecognisedWord(text: "a", startMs: 0, endMs: 5)]) })
        var job = TranscriptionJob(request: request("bursts.wav", duration: 10), recognizer: stub, progress: { _ in },
                                   cancel: MediaCancellation())
        job.removeFolder = { _ in throw CocoaError(.fileWriteNoPermission) }
        do {
            _ = try await job.run()
            XCTFail("a failed cleanup is reported")
        } catch let error as TranscriptionError {
            guard case .temporaryFilesNotRemoved(let folder) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(folder.contains("/.studio-render-tmp/transcribe-"), folder)
            XCTAssertEqual(error.message, "Transcription finished, but its temporary audio in \(folder) could not be removed. Delete that folder.")
        }
    }

    // MARK: A5 Linux reports no on-device recognizer

    func testA5OnLinuxTheDefaultServiceReportsNoOnDeviceRecognizer() async throws {
        let service = defaultTranscriptionService()
        #if os(Linux)
        XCTAssertEqual(service.availability(locale: "en-US"), .unavailable(.platformHasNoOnDeviceRecognizer))
        XCTAssertEqual(service.supportedLocales(), [])
        try writeBursts()
        expectError(await run(service, request("bursts.wav", duration: 10)), .unavailable(.platformHasNoOnDeviceRecognizer))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.studio-render-tmp"))
        #else
        _ = service.availability(locale: "en-US")
        #endif
    }

    // MARK: A6 impossible word times never pass

    func testA6OverlappingUnorderedOrImpossibleWordsYieldInvalidResultNeverATranscript() async throws {
        try writeBursts()
        let bad: [[RecognisedWord]] = [
            [.init(text: "one", startMs: 0, endMs: 500), .init(text: "two", startMs: 400, endMs: 900)],   // overlap
            [.init(text: "two", startMs: 600, endMs: 900), .init(text: "one", startMs: 0, endMs: 500)],   // unordered
            [.init(text: "back", startMs: 900, endMs: 100)],                                              // end before start
            [.init(text: "early", startMs: -10, endMs: 100)],
            [.init(text: "late", startMs: 0, endMs: 10_001)],                                             // past the 10 s piece
            [.init(text: "  ", startMs: 0, endMs: 100)],
            [.init(text: "sure", startMs: 0, endMs: 100, confidence: 1.5)],
            [.init(text: "nan", startMs: 0, endMs: 100, confidence: .nan)],
        ]
        for words in bad {
            let stub = StubTranscriptionService(script: { _ in .words(words) })
            let result = await run(stub, request("bursts.wav", duration: 10))
            guard case .failure(let error) = result, case .invalidResult(let detail)? = error as? TranscriptionError else {
                XCTFail("\(words) passed: \(result)"); continue
            }
            XCTAssertTrue(detail.contains("of piece 1"), detail)
            XCTAssertEqual((error as? TranscriptionError)?.message,
                           "The system's speech recognition returned words with impossible times, so none were used (\(detail)).")
        }
        // Words that touch are in order.
        let touching = StubTranscriptionService(script: { _ in .words([.init(text: "a", startMs: 0, endMs: 500), .init(text: "b", startMs: 500, endMs: 900)]) })
        let touched = try await run(touching, request("bursts.wav", duration: 10)).get()
        XCTAssertEqual(touched.words.count, 2)
        XCTAssertEqual(try leftoverFolders(), [])
    }

    func testA6AWordOfALaterPieceBeforeTheEndOfTheLastOneIsRefused() throws {
        let piece = TranscriptionPiece(index: 1, path: "", firstSample: 800_000, sampleCount: 16_000, sampleRate: 16_000,
                                       startMs: 50_000, endMs: 51_000)
        XCTAssertThrowsError(try placeOnSourceTimeLine([.init(text: "a", startMs: 0, endMs: 10)], piece: piece, after: 50_005)) {
            XCTAssertEqual($0 as? TranscriptionError, .invalidResult("word 1 of piece 2 overlaps or precedes the word before it"))
        }
        XCTAssertEqual(try placeOnSourceTimeLine([.init(text: "a", startMs: 0, endMs: 10)], piece: piece, after: 50_000),
                       [.init(text: "a", startMs: 50_000, endMs: 50_010)])
    }

    // MARK: off the calling thread

    /// Starting a job returns at once and the decode and recognition never run on the calling (main) thread, which
    /// keeps turning its run loop while the stub stalls.
    func testTheCallingThreadIsNeverBlockedWhileTheStubStalls() throws {
        XCTAssertTrue(Thread.isMainThread)
        try writeWAV("long.wav", seconds: 60, rate: 16_000) { _ in true }
        let stalled = expectation(description: "the stub stalls in piece 1")
        let stub = StubTranscriptionService(script: { _ in .stall }, onPiece: { _ in stalled.fulfill() })
        let cancel = MediaCancellation()
        let request = request("long.wav", duration: 60)
        let started = Date()
        let job = Task { () -> Result<Transcript, Error> in
            do { return .success(try await stub.transcribe(request, progress: { _ in }, cancel: cancel)) } catch { return .failure(error) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.016, "starting a job returns within one frame")
        let ticks = TickCounter()
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in ticks.tick() }
        RunLoop.main.add(timer, forMode: .default)
        wait(for: [stalled], timeout: 120)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        timer.invalidate()
        XCTAssertGreaterThan(ticks.count, 0, "the main run loop kept running during the job")
        XCTAssertEqual(stub.received.map(\.onMainThread), [false])
        cancel.cancel()
        let finished = expectation(description: "the job ends")
        let outcome = ProgressLog()
        Task { if case .failure(let e) = await job.value, e as? TranscriptionError == .cancelled { outcome.add(.init(piecesDone: 0, piecesTotal: 0)) }; finished.fulfill() }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(outcome.values.count, 1, "the stalled job ends as cancelled")
    }
}

/// Thread-safe collectors for values reported from the job's threads.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [TranscriptionProgress] = []
    func add(_ p: TranscriptionProgress) { lock.lock(); log.append(p); lock.unlock() }
    var values: [TranscriptionProgress] { lock.lock(); defer { lock.unlock() }; return log }
}

private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func tick() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
