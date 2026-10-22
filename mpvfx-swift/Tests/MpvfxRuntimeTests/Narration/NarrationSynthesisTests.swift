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
// Narration from text (#349): speaking a narration with the stub service publishes an ordinary WAV into the project
// and leaves no temporary file; every unavailable reason and error is typed and carries its message.
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

final class NarrationSynthesisTests: XCTestCase {
    private var roots: [String] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(atPath: $0) }; super.tearDown() }

    /// (project folder, private temporary root) under one fresh folder.
    private func fixture() throws -> (project: String, temp: URL) {
        let root = try makeMediaTempDir("mpvfx-narration-"); roots.append(root)
        for dir in ["project", "tmp"] { try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: false) }
        return (root + "/project", URL(fileURLWithPath: root + "/tmp"))
    }

    private func narration(_ text: String = "Hello there", voiceId: String = "stub.voice.a", rate: Double = 1, pitch: Double = 0) -> NativeClipNarration {
        NativeClipNarration(text: text, voiceId: voiceId, voiceName: "Stub A", rate: rate, pitch: pitch)
    }

    private func speak(_ n: NativeClipNarration, service: SpeechSynthesisService = StubSpeechSynthesisService(),
                       cancel: SynthesisCancellation = SynthesisCancellation()) async throws -> (NarrationMedia, String, URL) {
        let (project, temp) = try fixture()
        let job = NarrationJob(service: service, narration: n, cancel: cancel, temporaryRoot: temp)
        let media = try await speakNarration(job, publish: narrationPublisher(projectRoot: project, durableWrite: TestDurableWrite()))
        return (media, project, temp)
    }

    private func assertSynthesisError(_ expected: SynthesisError, _ body: () async throws -> Void,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let e as SynthesisError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("untyped error \(error)", file: file, line: line) }
    }

    // MARK: A2

    func testA2SpeakingPublishesAWavAssetIntoTheProjectAndLeavesNoTemporaryFile() async throws {
        let (media, project, temp) = try await speak(narration(String(repeating: "a", count: 40)))
        // 40 characters × 0.05 s = 2 s at 48 kHz.
        XCTAssertEqual(media.samples48k, 96_000)
        XCTAssertEqual(media.path, "Narration/Narration.wav")
        XCTAssertEqual(media.name, "Narration.wav")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: project + "/" + media.path))
        XCTAssertEqual(bytes.count, 44 + 96_000 * 2)
        XCTAssertEqual(Array(bytes.prefix(4)), Array("RIFF".utf8))
        // The private temporary folder is gone, and the import left no staging folder in the project.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project + "/Narration"), ["Narration.wav"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project), ["Narration"])
        // The media engine reads it as an ordinary audio file of the same length.
        let described = describeImportedMedia(projectDir: project, files: [media.path])
        XCTAssertEqual(described.invalid, [])
        XCTAssertEqual(described.media.first?.kind, .audio)
        XCTAssertEqual(described.media.first?.duration ?? 0, 2, accuracy: 0.01)
        // The document plan places it from the WAV's own sample count.
        let audio = media.audio(assetId: "asset:say")
        XCTAssertEqual(audio.source, "Narration/Narration.wav"); XCTAssertEqual(audio.samples48k, 96_000)
    }

    func testA2SpeakingTwiceNeverOverwritesTheFirstWav() async throws {
        let (project, temp) = try fixture()
        let publish = narrationPublisher(projectRoot: project, durableWrite: TestDurableWrite())
        let first = try await speakNarration(NarrationJob(service: StubSpeechSynthesisService(), narration: narration(), temporaryRoot: temp), publish: publish)
        let second = try await speakNarration(NarrationJob(service: StubSpeechSynthesisService(), narration: narration("Longer text here"),
                                                           temporaryRoot: temp), publish: publish)
        XCTAssertEqual([first.path, second.path], ["Narration/Narration.wav", "Narration/Narration (2).wav"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: project + "/" + first.path)).count, 44 + first.samples48k * 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }

    func testStubLengthFollowsTextAndRate() {
        let base = StubSpeechSynthesisService.samples(for: SynthesisRequest(text: String(repeating: "a", count: 20), voiceId: "v"))
        XCTAssertEqual(base, 48_000)
        XCTAssertEqual(StubSpeechSynthesisService.samples(for: SynthesisRequest(text: String(repeating: "a", count: 20), voiceId: "v", rate: 2)), 24_000)
        XCTAssertEqual(StubSpeechSynthesisService.samples(for: SynthesisRequest(text: String(repeating: "a", count: 40), voiceId: "v", rate: 0.5)), 192_000)
    }

    // MARK: A4

    func testA4SpeakingAgainWithAVoiceThatIsNotInstalledReportsVoiceMissing() async throws {
        let recorded = NativeClipNarration(text: "Hello", voiceId: "voice.from.another.machine", voiceName: "Studio Voice")
        await assertSynthesisError(.unavailable(.voiceMissing(id: "voice.from.another.machine", name: "Studio Voice"))) {
            _ = try await self.speak(recorded)
        }
        XCTAssertEqual(SynthesisUnavailableReason.voiceMissing(id: "x", name: "Studio Voice").description,
                       "The voice \"Studio Voice\" is not installed on this computer. The clip still plays; choose another voice to speak it again.")
        XCTAssertEqual(SynthesisUnavailableReason.voiceMissing(id: "x", name: "").description,
                       "The voice this narration was spoken with is not installed on this computer. The clip still plays; choose another voice to speak it again.")
    }

    // MARK: A5

    func testA5OnLinuxTheDefaultServiceReportsPlatformHasNoSystemVoices() async throws {
        #if os(Linux)
        let service = defaultSpeechSynthesisService()
        XCTAssertEqual(service.availability(), .unavailable(.platformHasNoSystemVoices))
        XCTAssertEqual(service.voices(), [])
        await assertSynthesisError(.unavailable(.platformHasNoSystemVoices)) { _ = try await self.speak(self.narration(), service: service) }
        #endif
        XCTAssertEqual(SynthesisUnavailableReason.platformHasNoSystemVoices.description,
                       "Narration from text needs the system's built-in voices, which this system does not provide to apps.")
    }

    func testA5EveryUnavailableReasonIsReportedWithItsMessage() async throws {
        await assertSynthesisError(.unavailable(.noVoices)) { _ = try await self.speak(self.narration(), service: StubSpeechSynthesisService(voices: [])) }
        XCTAssertEqual(SynthesisUnavailableReason.noVoices.description,
                       "Narration from text needs a system voice, and none is installed. Add a voice in the system settings.")
        XCTAssertEqual(SynthesisError.unavailable(.noVoices).description, SynthesisUnavailableReason.noVoices.description)
        let off = StubSpeechSynthesisService(unavailableReason: .platformHasNoSystemVoices)
        XCTAssertEqual(off.availability(), .unavailable(.platformHasNoSystemVoices))
        await assertSynthesisError(.unavailable(.platformHasNoSystemVoices)) { _ = try await self.speak(self.narration(), service: off) }
    }

    func testA5EveryRequestErrorIsTypedWithItsMessage() async throws {
        await assertSynthesisError(.textEmpty) { _ = try await self.speak(self.narration(" \n\t")) }
        XCTAssertEqual(SynthesisError.textEmpty.description, "Type the text to speak first.")
        let long = String(repeating: "a", count: NativeNarrationScale.textLimit + 1)
        await assertSynthesisError(.textTooLong(limit: 20_000)) { _ = try await self.speak(self.narration(long)) }
        XCTAssertEqual(SynthesisError.textTooLong(limit: 20_000).description,
                       "Narration text can be at most 20000 characters per clip. Split it into several clips.")
        await assertSynthesisError(.parameterOutOfRange(name: "rate", value: 2.5, range: 0.5...2)) {
            _ = try await self.speak(self.narration(rate: 2.5))
        }
        await assertSynthesisError(.parameterOutOfRange(name: "pitch", value: -20, range: -12...12)) {
            _ = try await self.speak(self.narration(pitch: -20))
        }
        XCTAssertThrowsError(try validateSynthesisRequest(SynthesisRequest(text: "a", voiceId: "v", rate: .nan)))
        XCTAssertEqual(SynthesisError.parameterOutOfRange(name: "rate", value: 2.5, range: 0.5...2).description,
                       "The rate 2.5 is outside what this voice can do (0.5 to 2).")
        XCTAssertNoThrow(try validateSynthesisRequest(SynthesisRequest(text: String(repeating: "a", count: 20_000), voiceId: "v", rate: 2, pitch: 12)))
    }

    func testA5CancelledBeforeOrDuringSpeakingIsTypedAndLeavesNothing() async throws {
        let cancel = SynthesisCancellation(); cancel.cancel()
        let (project, temp) = try fixture()
        let job = NarrationJob(service: StubSpeechSynthesisService(), narration: narration(), cancel: cancel, temporaryRoot: temp)
        await assertSynthesisError(.cancelled) {
            _ = try await speakNarration(job, publish: narrationPublisher(projectRoot: project, durableWrite: TestDurableWrite()))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project), [])
        XCTAssertEqual(SynthesisError.cancelled.description, "Narration was cancelled.")
        // A service that reports cancellation its own way (the media jobs' abort) is still `.cancelled`.
        await assertSynthesisError(.cancelled) { _ = try await self.speak(self.narration(), service: ThrowingService(kind: .abort)) }
    }

    func testA5SynthesizerAndWriteFailuresAreTypedWithTheirMessages() async throws {
        await assertSynthesisError(.synthesizerFailed(code: -1, message: "Opaque()")) {
            _ = try await self.speak(self.narration(), service: ThrowingService(kind: .opaque))
        }
        await assertSynthesisError(.synthesizerFailed(code: 7, message: "engine busy")) {
            _ = try await self.speak(self.narration(), service: ThrowingService(kind: .busy))
        }
        XCTAssertEqual(SynthesisError.synthesizerFailed(code: 7, message: "engine busy").description, "The system voice failed (7): engine busy")
        // A service that claims audio it did not write is caught before anything reaches the project.
        let (project, temp) = try fixture()
        let job = NarrationJob(service: SilentService(), narration: narration(), temporaryRoot: temp)
        do {
            _ = try await speakNarration(job, publish: narrationPublisher(projectRoot: project, durableWrite: TestDurableWrite()))
            XCTFail("expected writeFailed")
        } catch SynthesisError.writeFailed(let path, let underlying) {
            XCTAssertTrue(path.hasSuffix("/Narration.wav"), path); XCTAssertEqual(underlying, "the voice wrote no audio file")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project), [])
        XCTAssertEqual(SynthesisError.writeFailed(path: "/p/a.wav", underlying: "disk full").description,
                       "The narration audio could not be written to /p/a.wav: disk full")
        // A publish failure is typed too, and the temporary folder is still removed.
        let empty = temp.deletingLastPathComponent().appendingPathComponent("empty.wav").path
        XCTAssertTrue(FileManager.default.createFile(atPath: empty, contents: Data()))
        await assertSynthesisError(.writeFailed(path: project + "/Narration", underlying: "Unsupported or empty media file")) {
            let failing: NarrationPublish = { _ in try await narrationPublisher(projectRoot: project, durableWrite: TestDurableWrite())(empty) }
            _ = try await speakNarration(NarrationJob(service: StubSpeechSynthesisService(), narration: self.narration(), temporaryRoot: temp), publish: failing)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }

    func testNarrationWavHeaderIsCanonical48kMono16Bit() {
        let data = NarrationWAV.encode([0, 1, -1]) ?? Data()
        XCTAssertEqual(data.count, 50)
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF"); XCTAssertEqual(u32(4), 42)
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(u32(16), 16); XCTAssertEqual(u16(20), 1); XCTAssertEqual(u16(22), 1)
        XCTAssertEqual(u32(24), 48_000); XCTAssertEqual(u32(28), 96_000); XCTAssertEqual(u16(32), 2); XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data"); XCTAssertEqual(u32(40), 6)
        XCTAssertEqual(Array(data[44...]), [0, 0, 1, 0, 0xff, 0xff])
    }
}

private struct Opaque: Error {}

/// A service with one voice whose synthesize throws: the media jobs' abort, an untyped error, or a typed failure.
private struct ThrowingService: SpeechSynthesisService {
    enum Kind { case abort, opaque, busy }
    let kind: Kind
    func availability() -> SynthesisAvailability { .available }
    func voices() -> [SystemVoice] { [SystemVoice(id: "stub.voice.a", name: "Stub A", locale: "en-US")] }
    func synthesize(_ request: SynthesisRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void,
                    cancel: SynthesisCancellation) async throws -> SynthesisResult {
        switch kind {
        case .abort: throw MediaAbortError()
        case .opaque: throw Opaque()
        case .busy: throw SynthesisError.synthesizerFailed(code: 7, message: "engine busy")
        }
    }
}

/// A service that reports audio without writing a file.
private struct SilentService: SpeechSynthesisService {
    func availability() -> SynthesisAvailability { .available }
    func voices() -> [SystemVoice] { [SystemVoice(id: "stub.voice.a", name: "Stub A", locale: "en-US")] }
    func synthesize(_ request: SynthesisRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void,
                    cancel: SynthesisCancellation) async throws -> SynthesisResult { SynthesisResult(durationFrames48k: 100) }
}
