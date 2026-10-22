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
}
