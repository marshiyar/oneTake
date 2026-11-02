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
import Foundation
import XCTest
@testable import MpvfxAudio

final class VoiceTransportTests: XCTestCase {
    func path() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).wav").path }

    func testA1CountInDoesNotCaptureAndEscapeLeavesNoFile() throws {
        let input = ScriptedAudioInput(samples: [0.5]), t = VoiceTransport(), file = path()
        try t.arm(input: input, destination: file, playhead: 2, countIn: 3, now: 10)
        XCTAssertEqual(t.state, .counting); XCTAssertEqual(t.countdown, 3)
        try t.tick(now: 12.1)
        XCTAssertEqual(t.countdown, 1)
        t.cancel()
        XCTAssertEqual(t.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (file as NSString).deletingLastPathComponent + "/." + (file as NSString).lastPathComponent + ".recording"))
    }

    func testA1SpaceKeepsCaptureAndEscapeDeletesInProgressWav() throws {
        for keep in [true, false] {
            let input = ScriptedAudioInput(samples: [Float](repeating: 0.25, count: 4_800))
            let ready = expectation(description: "captured"), file = path(), t = VoiceTransport()
            input.onRead = { n in if n == 4_800 { ready.fulfill() } }
            try t.arm(input: input, destination: file, playhead: 1, countIn: 0, now: 0)
            wait(for: [ready], timeout: 3)
            if keep {
                let result = try XCTUnwrap(t.stop())
                XCTAssertEqual(result.frames, 4_800)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file))
                try FileManager.default.removeItem(atPath: file)
            } else {
                t.cancel()
                XCTAssertFalse(FileManager.default.fileExists(atPath: file))
            }
            XCTAssertEqual(t.state, .idle)
        }
    }

    func testA2MeasuredLatencyPadsToTheSampleWithinOneMillisecond() throws {
        let input = ScriptedAudioInput(samples: [Float](repeating: 0.5, count: 4_800))
        input.latencySeconds = 0.0173
        let ready = expectation(description: "captured"), file = path(), t = VoiceTransport()
        defer { try? FileManager.default.removeItem(atPath: file) }
        input.onRead = { n in if n == 4_800 { ready.fulfill() } }
        try t.arm(input: input, destination: file, playhead: 2, countIn: 0, now: 0, fps: 30)
        wait(for: [ready], timeout: 3)
        let result = try XCTUnwrap(t.stop())
        let prefix = result.frames - 4_800
        XCTAssertEqual(t.placementSeconds + Double(prefix) / 48_000, 2.0173, accuracy: 0.001)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        XCTAssertTrue(bytes[44..<(44 + prefix * 2)].allSatisfy { $0 == 0 })
        XCTAssertTrue(bytes[(44 + prefix * 2)..<(46 + prefix * 2)].contains { $0 != 0 })
    }

    func testA4MeterAndClipIndicatorComeFromCapturedSamples() throws {
        let input = ScriptedAudioInput(samples: [1.2, -0.4]), file = path(), t = VoiceTransport()
        let ready = expectation(description: "captured")
        input.onRead = { _ in ready.fulfill() }
        defer { t.cancel() }
        try t.arm(input: input, destination: file, playhead: 0, countIn: 0, now: 0)
        wait(for: [ready], timeout: 3)
        // stop joins the recorder, including the meter update after the read callback.
        let result = try XCTUnwrap(t.stop())
        XCTAssertEqual(result.frames, 2)
        XCTAssertEqual(t.meter.peak, 1)
        XCTAssertTrue(t.meter.clipped)
        try FileManager.default.removeItem(atPath: file)
    }

    // MARK: Punch-in over the I/O range with pre-roll (#318)

    /// Polls until `done` holds; the recorder runs on its own thread.
    private func waitUntil(_ label: String, timeout: Double = 5, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(done(), label)
    }

    func testA1PunchTakeIsExactlyTheRangeAndStopsItself() throws {
        // 2.0 s to 3.5 s at 30 fps is frames 60 to 105: 45 frames, 72 000 samples at 48 kHz.
        let input = ScriptedAudioInput(samples: [Float](repeating: 0.25, count: 200_000))
        let file = path(), t = VoiceTransport()
        defer { try? FileManager.default.removeItem(atPath: file) }
        try t.arm(input: input, destination: file, playhead: 0, countIn: 0, now: 0, fps: 30,
                  punch: .init(start: 2, end: 3.5, preRoll: 0))
        XCTAssertEqual(t.state, .recording)
        waitUntil("the range fills") { t.isComplete }
        let result = try XCTUnwrap(t.stop())
        XCTAssertEqual(result.frames, 72_000)
        XCTAssertEqual(t.placementSeconds, 2)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        XCTAssertEqual(bytes.count, 44 + 72_000 * 2)
    }

    func testA1PunchRangeIsRoundedToFramesAndLatencyStaysInsideIt() throws {
        // 1.01 s to 2.02 s rounds to frames 30 to 61; latency pads the start, the end stays at frame 61.
        let input = ScriptedAudioInput(samples: [Float](repeating: 0.5, count: 200_000))
        input.latencySeconds = 0.05
        let file = path(), t = VoiceTransport()
        defer { try? FileManager.default.removeItem(atPath: file) }
        try t.arm(input: input, destination: file, playhead: 0, countIn: 0, now: 0, fps: 30,
                  punch: .init(start: 1.01, end: 2.02, preRoll: 0))
        waitUntil("the range fills") { t.isComplete }
        let result = try XCTUnwrap(t.stop())
        XCTAssertEqual(result.frames, 48_000 * 31 / 30)
        XCTAssertEqual(t.placementSeconds, 1)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        let pad = Int(0.05 * 48_000)
        XCTAssertTrue(bytes[44..<(44 + pad * 2)].allSatisfy { $0 == 0 })
        XCTAssertTrue(bytes[(44 + pad * 2)..<(46 + pad * 2)].contains { $0 != 0 })
    }

    func testA2PreRollIsPlayedButNotCaptured() throws {
        let input = ScriptedAudioInput(samples: [Float](repeating: 0.5, count: 200_000))
        var reads = 0, started = 0
        input.onRead = { _ in reads += 1 }
        let file = path(), t = VoiceTransport()
        defer { try? FileManager.default.removeItem(atPath: file); t.cancel() }
        t.onStart = { started += 1 }
        try t.arm(input: input, destination: file, playhead: 0, countIn: 2, now: 100, fps: 30,
                  punch: .init(start: 5, end: 6, preRoll: 2))
        XCTAssertEqual(t.playbackStartSeconds, 3)          // playback begins two seconds before the range
        XCTAssertEqual(t.state, .counting)
        try t.tick(now: 101.9)
        XCTAssertEqual(t.state, .counting)
        XCTAssertEqual(started, 0)
        try t.tick(now: 102)                                 // count-in over: the transport plays, nothing is captured
        XCTAssertEqual(t.state, .preRoll)
        XCTAssertEqual(started, 1)
        try t.tick(now: 103.9)
        XCTAssertEqual(t.state, .preRoll)
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (file as NSString).deletingLastPathComponent + "/." + (file as NSString).lastPathComponent + ".recording"))
        try t.tick(now: 104)                                 // the range starts: capture begins
        XCTAssertEqual(t.state, .recording)
        XCTAssertEqual(started, 1)
        waitUntil("the range fills") { t.isComplete }
        let result = try XCTUnwrap(t.stop())
        XCTAssertEqual(result.frames, 48_000)                // one second, none of the pre-roll
    }

    func testPreRollIsCountedFromWhenThePlaybackReallyStartedNotFromTheCountInDeadline() throws {
        let input = ScriptedAudioInput(samples: [Float](repeating: 0.5, count: 200_000)), file = path(), t = VoiceTransport()
        defer { try? FileManager.default.removeItem(atPath: file); t.cancel() }
        try t.arm(input: input, destination: file, playhead: 0, countIn: 1, now: 10, fps: 30, punch: .init(start: 4, end: 5, preRoll: 2))
        try t.tick(now: 11.04)                               // the poll saw the deadline 40 ms late: the transport starts here
        XCTAssertEqual(t.state, .preRoll)
        try t.tick(now: 13.03)                               // two seconds after the deadline, but not after the real start
        XCTAssertEqual(t.state, .preRoll)
        try t.tick(now: 13.04)
        XCTAssertEqual(t.state, .recording)
    }

    func testPreRollIsShortenedAtTheStartOfTheTimelineAndSpaceDuringItKeepsNothing() throws {
        let input = ScriptedAudioInput(samples: [0.5]), file = path(), t = VoiceTransport()
        try t.arm(input: input, destination: file, playhead: 0, countIn: 0, now: 0, fps: 30, punch: .init(start: 1, end: 2, preRoll: 3))
        XCTAssertEqual(t.playbackStartSeconds, 0)
        XCTAssertEqual(t.state, .preRoll)
        XCTAssertNil(try t.stop())
        XCTAssertEqual(t.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    func testPunchRangeMustHoldFrames() throws {
        let input = ScriptedAudioInput(samples: [0.5]), t = VoiceTransport()
        for (a, b) in [(2.0, 2.0), (3.0, 2.0), (1.0, 1.01)] {
            XCTAssertThrowsError(try t.arm(input: input, destination: path(), playhead: 0, countIn: 0, now: 0, fps: 30,
                                           punch: .init(start: a, end: b, preRoll: 0)))
            XCTAssertEqual(t.state, .idle)
        }
    }
}
