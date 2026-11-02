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
// Voice-over capture: the recorder writes what an input delivers into a WAV that is valid at every checkpoint and appears
// at its destination in one rename; every way a microphone can fail is a typed error with its words. The input is a
// scripted double (CI machines have no microphone); the real PulseAudio source is exercised for a clean answer.
import XCTest
import OneTakeMedia
@testable import MpvfxAudio

final class VoiceRecorderTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try WavFixtures.tempDir() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func tone(seconds: Double, rate: Int = 48_000) -> [Float] { WavFixtures.sine(330, seconds: seconds, amp: 0.5, sampleRate: rate) }
    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    /// The file as the media engine reads it: container, length, and every sample.
    func decode(_ path: String) throws -> (container: String, seconds: Double, samples: [Float]) {
        let probe = try MediaProbe.probe(path: path)
        XCTAssertEqual(probe.audio?.decodable, true, "the engine can decode \(path)")
        let reader = try AudioSampleReader(path: path, sampleRate: 48_000, channels: 1)
        var all: [Float] = []
        while true {
            let block = try reader.read(frames: 8192)
            if block.isEmpty { break }
            all += block
        }
        return (probe.container, probe.duration ?? 0, all)
    }

    func expected(_ samples: [Float]) -> [Float] { samples.map { Float(VoiceRecorder.sample($0)) / 32_768 } }

    // MARK: recording end to end

    func testARecordingEndsAsAnEngineReadableWavAtTheDestinationWithNothingLeftBehind() throws {
        let source = tone(seconds: 2)
        let input = ScriptedAudioInput(samples: source)
        let destination = dir.path + "/take1.wav"
        let recorder = VoiceRecorder(input: input, destination: destination, checkpointSeconds: 0.5)
        try recorder.start()
        var done = false
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline { done = recorder.framesRecorded >= source.count; usleep(1000) }
        XCTAssertTrue(done)
        let recording = try recorder.stop()
        XCTAssertEqual(try names(), ["take1.wav"], "the hidden .recording file became the destination")
        XCTAssertEqual(recording, VoiceRecording(path: destination, frames: 96_000, sampleRate: 48_000, channels: 1, droppedFrames: 0, failure: nil))
        XCTAssertEqual(recording.seconds, 2, accuracy: 1e-9)
        let decoded = try decode(destination)
        XCTAssertEqual(decoded.container, "wav")
        XCTAssertEqual(decoded.seconds, 2, accuracy: 0.001)
        let want = expected(source)
        XCTAssertEqual(decoded.samples.count, want.count)
        XCTAssertEqual(zip(decoded.samples, want).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1.0 / 32_768)
    }

    func testTheDestinationAppearsOnlyWhenTheRecordingIsComplete() throws {
        let input = ScriptedAudioInput(samples: tone(seconds: 1))
        let destination = dir.path + "/take.wav"
        var duringNames: [String] = []
        input.onRead = { total in if total == 48_000 { duringNames = (try? self.names()) ?? [] } }
        let recorder = VoiceRecorder(input: input, destination: destination)
        try recorder.start()
        while recorder.framesRecorded < 48_000 { usleep(1000) }
        XCTAssertEqual(duringNames, [".take.wav.recording"], "while recording only the hidden file exists")
        try recorder.stop()
        XCTAssertEqual(try names(), ["take.wav"])
    }

    // MARK: A2 interrupted recording

    /// A2: the file a killed process leaves is a valid WAV up to the last checkpoint. The image is copied while the
    /// recorder is mid-block (audio past the last checkpoint is on disk but not in the header's sizes).
    func testA2AFileKilledMidRecordingIsAValidWavUpToTheLastCheckpoint() throws {
        let source = tone(seconds: 3)
        let input = ScriptedAudioInput(samples: source)
        let temp = dir.path + "/.take.wav.recording", image = dir.path + "/image.wav"
        input.onRead = { total in
            if total == 72_000 { try? FileManager.default.copyItem(atPath: temp, toPath: image) }   // the process dies here
        }
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/take.wav", checkpointSeconds: 1)
        try recorder.start()
        while recorder.framesRecorded < 96_000 { usleep(1000) }
        try recorder.stop()
        let size = (try FileManager.default.attributesOfItem(atPath: image)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 44 + 48_000 * 2, "audio past the checkpoint is in the file")
        let decoded = try decode(image)
        XCTAssertEqual(decoded.container, "wav")
        XCTAssertEqual(decoded.samples.count, 48_000, "exactly the checkpointed second")
        XCTAssertEqual(decoded.seconds, 1, accuracy: 0.001)
        let want = expected(Array(source.prefix(48_000)))
        XCTAssertEqual(zip(decoded.samples, want).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1.0 / 32_768)
    }

    func testTheWriterCheckpointsDataBeforeSizesAndEveryCheckpointIsAValidFile() throws {
        let path = dir.path + "/w.wav"
        let writer = try WavStreamWriter(path: path, sampleRate: 48_000, channels: 1)
        let first = tone(seconds: 0.5).map(VoiceRecorder.sample)
        try writer.append(first)
        XCTAssertEqual(writer.framesCheckpointed, 0)
        XCTAssertEqual(try decodeCount(path), 0, "before any checkpoint the file is a valid empty WAV")
        try writer.checkpoint()
        XCTAssertEqual(writer.framesCheckpointed, 24_000)
        XCTAssertEqual(try decodeCount(path), 24_000)
        try writer.append(first)
        XCTAssertEqual(try decodeCount(path), 24_000, "unsynced audio is not part of the file yet")
        try writer.finish()
        XCTAssertEqual(try decodeCount(path), 48_000)
        XCTAssertThrowsError(try writer.append(first))
    }

    func decodeCount(_ path: String) throws -> Int {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let data = bytes.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let riff = bytes.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(riff, data + 36)
        if data == 0 { return 0 }
        return try decode(path).samples.count
    }

    // MARK: typed errors

    func testAPermissionRefusalIsTypedNamesSystemSettingsAndCreatesNothing() throws {
        let input = ScriptedAudioInput(samples: [])
        input.startError = .macOSPermission
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/take.wav")
        XCTAssertThrowsError(try recorder.start()) { error in
            XCTAssertEqual(error as? AudioInputError, .macOSPermission)
            XCTAssertTrue("\(error)".contains("System Settings > Privacy & Security > Microphone"), "\(error)")
        }
        XCTAssertEqual(try names(), [])
        XCTAssertFalse(recorder.isRecording)
    }

    func testEveryDeviceErrorHasWordsForThePersonRecording() {
        XCTAssertEqual("\(AudioInputError.noDevice)", "No microphone was found. Connect one and try again.")
        XCTAssertEqual("\(AudioInputError.deviceNotFound("Desk mic"))", "The microphone \"Desk mic\" is not connected.")
        XCTAssertTrue("\(AudioInputError.windowsPermission)".contains("Settings > Privacy & security > Microphone"))
        XCTAssertEqual("\(AudioInputError.unavailable("Connection refused"))", "The microphone can't be opened: Connection refused.")
        XCTAssertEqual("\(AudioInputError.deviceError("unplugged"))", "The microphone stopped working: unplugged.")
        XCTAssertEqual("\(AudioInputError.writeFailed(path: "/a/b.wav", reason: "disk full"))", "The recording can't be written to /a/b.wav: disk full.")
    }

    func testADeviceThatDisappearsMidRecordingKeepsWhatWasCapturedAndSaysWhy() throws {
        let source = tone(seconds: 1)
        let input = ScriptedAudioInput(samples: source)
        input.failure = .deviceError("the microphone was unplugged")
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/take.wav")
        try recorder.start()
        while recorder.failure == nil { usleep(1000) }
        let recording = try recorder.stop()
        XCTAssertEqual(recording.failure, .deviceError("the microphone was unplugged"))
        XCTAssertEqual(recording.frames, 48_000)
        XCTAssertEqual(try decode(recording.path).samples.count, 48_000)
        XCTAssertEqual(try names(), ["take.wav"])
    }

    func testANameThatIsTakenIsRefusedBeforeTheMicrophoneOpens() throws {
        try Data("keep me".utf8).write(to: dir.appendingPathComponent("take.wav"))
        let input = ScriptedAudioInput(samples: tone(seconds: 0.1))
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/take.wav")
        XCTAssertThrowsError(try recorder.start()) {
            guard case .writeFailed(let path, _)? = $0 as? AudioInputError else { return XCTFail("\($0)") }
            XCTAssertEqual(path, dir.path + "/take.wav")
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("take.wav")), Data("keep me".utf8))
        XCTAssertEqual(try names(), ["take.wav"])
    }

    func testAMissingFolderIsATypedWriteErrorAndTheInputIsReleased() throws {
        let input = ScriptedAudioInput(samples: tone(seconds: 0.1))
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/nope/take.wav")
        XCTAssertThrowsError(try recorder.start()) {
            guard case .writeFailed? = $0 as? AudioInputError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try input.read(frames: 10), "start failed, so the input was stopped again")
    }

    func testCancelRemovesEverythingTheRecordingWrote() throws {
        let input = ScriptedAudioInput(samples: tone(seconds: 2))
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/take.wav")
        try recorder.start()
        while recorder.framesRecorded < 4_800 { usleep(1000) }
        recorder.cancel()
        XCTAssertEqual(try names(), [])
        XCTAssertThrowsError(try recorder.stop())
    }

    func testSamplesAreClampedAndNonFiniteValuesBecomeSilence() {
        XCTAssertEqual(VoiceRecorder.sample(0), 0)
        XCTAssertEqual(VoiceRecorder.sample(1), 32_767)
        XCTAssertEqual(VoiceRecorder.sample(-1), -32_767)
        XCTAssertEqual(VoiceRecorder.sample(3), 32_767)
        XCTAssertEqual(VoiceRecorder.sample(-3), -32_767)
        XCTAssertEqual(VoiceRecorder.sample(.nan), 0)
        XCTAssertEqual(VoiceRecorder.sample(.infinity), 0)
    }

    func testAStereoInputRecordsBothChannelsInterleaved() throws {
        let left = tone(seconds: 0.5), right = left.map { -$0 }
        let interleaved = zip(left, right).flatMap { [$0, $1] }
        let input = ScriptedAudioInput(format: AudioFormat(sampleRate: 48_000, channels: 2), samples: interleaved)
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/stereo.wav")
        try recorder.start()
        while recorder.framesRecorded < left.count { usleep(1000) }
        let recording = try recorder.stop()
        XCTAssertEqual(recording.channels, 2)
        let reader = try AudioSampleReader(path: recording.path, sampleRate: 48_000, channels: 2)
        let got = try reader.read(frames: left.count)
        XCTAssertEqual(got.count, interleaved.count)
        XCTAssertEqual(got[2], Float(VoiceRecorder.sample(left[1])) / 32_768, accuracy: 1.0 / 32_768)
        XCTAssertEqual(got[3], Float(VoiceRecorder.sample(right[1])) / 32_768, accuracy: 1.0 / 32_768)
    }

    // MARK: A1 devices

    func testA1DeviceListingAnswersWithUniqueIdsAndTheRightBackendIsCompiled() {
        let started = Date()
        let devices = AudioInputDevices.list()
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count, "ids are unique")
        XCTAssertFalse(devices.contains { $0.id.isEmpty || $0.name.isEmpty })
        XCTAssertLessThanOrEqual(devices.filter(\.isDefault).count, 1)
        #if os(Linux) && canImport(CPulse)
        XCTAssertNotNil(AudioInputDevices.makeSystemInput())
        XCTAssertEqual(AudioInputDevices.makeSystemInput()?.format, AudioFormat(sampleRate: 48_000, channels: 1))
        #endif
    }

    func testTheScriptedInputRefusesReadsBeforeStartAndEndsWithAnEmptyRead() throws {
        let input = ScriptedAudioInput(samples: [0.1, 0.2, 0.3])
        XCTAssertThrowsError(try input.read(frames: 1)) { XCTAssertEqual($0 as? AudioInputError, .invalidState("the input is not started")) }
        try input.start()
        XCTAssertEqual(try input.read(frames: 2), [0.1, 0.2])
        XCTAssertEqual(try input.read(frames: 2), [0.3])
        XCTAssertEqual(try input.read(frames: 2), [])
    }

    // MARK: maxFrames

    func testAMaxFramesLimitEndsCaptureByItselfAndTheFileHoldsExactlyThatMany() throws {
        let source = Array(tone(seconds: 2).prefix(50_000))
        let input = ScriptedAudioInput(samples: source)
        var lastTotal = 0
        input.onRead = { total in lastTotal = total }
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/limit.wav")
        recorder.maxFrames = 10_000
        try recorder.start()
        var limited = false
        let deadline = Date().addingTimeInterval(20)
        while !limited, Date() < deadline { limited = recorder.reachedLimit; usleep(1000) }
        XCTAssertTrue(limited, "capture ends by itself once the file holds maxFrames")
        XCTAssertFalse(recorder.isRecording)
        let recording = try recorder.stop()
        XCTAssertTrue(recorder.reachedLimit)
        XCTAssertEqual(recording.frames, 10_000)
        XCTAssertLessThanOrEqual(lastTotal, 10_000, "the input never hands out past the limit")
        XCTAssertEqual(try names(), ["limit.wav"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: recording.path))
        XCTAssertEqual(bytes.count, 44 + 10_000 * 2)
        XCTAssertEqual(String(decoding: bytes.subdata(in: 0..<4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes.subdata(in: 8..<12), as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: bytes.subdata(in: 36..<40), as: UTF8.self), "data")
        let riff = bytes.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let dataSize = bytes.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(dataSize, 20_000, "the data size counts the 10_000 frames")
        XCTAssertEqual(riff, 36 + 20_000, "the RIFF size is the file size minus 8")
        let decoded = try decode(recording.path)
        XCTAssertEqual(decoded.samples.count, 10_000)
        let want = expected(Array(source.prefix(10_000)))
        XCTAssertEqual(zip(decoded.samples, want).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1.0 / 32_768)
    }

    func testAMaxFramesThatIsNotAMultipleOfTheBlockIsHitExactly() throws {
        let source = tone(seconds: 1)
        let input = ScriptedAudioInput(samples: source)
        var lastTotal = 0
        input.onRead = { total in lastTotal = total }
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/odd.wav")
        recorder.maxFrames = 5_000
        XCTAssertNotEqual(5_000 % VoiceRecorder.blockFrames, 0, "the premise: the limit falls inside a block")
        try recorder.start()
        let deadline = Date().addingTimeInterval(20)
        while !recorder.reachedLimit, Date() < deadline { usleep(1000) }
        XCTAssertTrue(recorder.reachedLimit)
        let recording = try recorder.stop()
        XCTAssertEqual(recording.frames, 5_000)
        XCTAssertEqual(lastTotal, 5_000, "the last block is cut to the 200 frames that were left")
        XCTAssertEqual(try names(), ["odd.wav"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: recording.path))
        XCTAssertEqual(bytes.count, 44 + 5_000 * 2)
        let decoded = try decode(recording.path)
        XCTAssertEqual(decoded.samples.count, 5_000)
        let want = expected(Array(source.prefix(5_000)))
        XCTAssertEqual(zip(decoded.samples, want).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1.0 / 32_768)
    }

    func testAMaxFramesSmallerThanTheLeadingSilenceGivesExactlyThatMuchSilence() throws {
        let input = ScriptedAudioInput(samples: tone(seconds: 1))
        var reads = 0
        input.onRead = { _ in reads += 1 }
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/lead.wav")
        recorder.leadingSilenceFrames = { 4_800 }
        recorder.maxFrames = 3_000
        try recorder.start()
        XCTAssertTrue(recorder.reachedLimit, "the leading silence alone fills the file")
        let recording = try recorder.stop()
        XCTAssertTrue(recorder.reachedLimit)
        XCTAssertEqual(recording.frames, 3_000)
        XCTAssertEqual(reads, 0, "the input is never read once the file is full")
        let decoded = try decode(recording.path)
        XCTAssertEqual(decoded.samples.count, 3_000)
        XCTAssertTrue(decoded.samples.allSatisfy { $0 == 0 }, "every sample is silence")
        XCTAssertEqual(try names(), ["lead.wav"])
    }

    func testWithoutMaxFramesTheLimitStaysOffAndTheTakeRunsUntilTheInputEndsOrStop() throws {
        let source = tone(seconds: 1)
        let input = ScriptedAudioInput(samples: source)
        let recorder = VoiceRecorder(input: input, destination: dir.path + "/open.wav")
        XCTAssertNil(recorder.maxFrames)
        try recorder.start()
        let deadline = Date().addingTimeInterval(20)
        while recorder.framesRecorded < source.count, Date() < deadline { usleep(1000) }
        XCTAssertEqual(recorder.framesRecorded, source.count, "the take runs to the end of the scripted samples")
        XCTAssertFalse(recorder.reachedLimit)
        let recording = try recorder.stop()
        XCTAssertFalse(recorder.reachedLimit)
        XCTAssertEqual(recording.frames, 48_000)
        XCTAssertEqual(try decode(recording.path).samples.count, 48_000)
        XCTAssertEqual(try names(), ["open.wav"])
    }

    func testCancelAfterTheLimitRemovesTheHiddenFileAndLeavesNoDestination() throws {
        let input = ScriptedAudioInput(samples: tone(seconds: 1))
        let destination = dir.path + "/limit.wav"
        let recorder = VoiceRecorder(input: input, destination: destination)
        recorder.maxFrames = 4_800
        try recorder.start()
        let deadline = Date().addingTimeInterval(20)
        while !recorder.reachedLimit, Date() < deadline { usleep(1000) }
        XCTAssertTrue(recorder.reachedLimit)
        XCTAssertEqual(try names(), [".limit.wav.recording"], "the hidden file holds the full take")
        recorder.cancel()
        XCTAssertEqual(try names(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
        XCTAssertThrowsError(try recorder.stop(), "the cancelled take can't be published")
    }
}

#if canImport(CPulse)
/// Real source: with a reachable PulseAudio (or pipewire-pulse) server the listing and the stream work; without one
/// `start` fails cleanly with `.unavailable` (CI runners have no microphone). It does not skip.
final class PulseAudioInputTests: XCTestCase {
    func testStartOpensTheDefaultSourceOrFailsCleanly() throws {
        let input = PulseAudioInput(appName: "MpVFX-tests")
        do { try input.start() } catch let error as AudioInputError {
            switch error {
            case .unavailable(let why): XCTAssertFalse(why.isEmpty)
            case .noDevice, .permissionDenied: break
            default: XCTFail("\(error)")
            }
            XCTAssertEqual(try input.read(frames: 10), [], "a stream that never opened reads as ended")
            return
        }
        let block = try input.read(frames: 480)
        XCTAssertEqual(block.count, 480)
        input.stop()
        XCTAssertEqual(try input.read(frames: 480), [], "a stopped stream reads as ended")
    }

    func testAChosenSourceThatIsGoneIsATypedDeviceNotFound() {
        let input = PulseAudioInput(appName: "MpVFX-tests")
        input.device = "mpvfx-no-such-source"
        XCTAssertEqual(input.device, "mpvfx-no-such-source")
        do { try input.start(); input.stop() } catch let error as AudioInputError {
            switch error {
            case .deviceNotFound(let name): XCTAssertEqual(name, "mpvfx-no-such-source")
            case .unavailable(let why): XCTAssertFalse(why.isEmpty, "no sound server on this machine")
            default: XCTFail("\(error)")
            }
        } catch { XCTFail("\(error)") }
    }
}
#endif
