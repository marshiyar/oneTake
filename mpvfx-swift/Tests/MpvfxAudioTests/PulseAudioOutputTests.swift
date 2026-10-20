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
#if canImport(CPulse)
import Foundation
import XCTest
@testable import MpvfxAudio

/// Compiled only when libpulse-dev is installed. Optional real-device check: with a reachable PulseAudio
/// (or pipewire-pulse) server it plays the 440 Hz tone through PulseAudioOutput. Without one it asserts
/// start() fails cleanly with `.unavailable` and write is refused; it does not skip. The tone content itself
/// is asserted headlessly in ToneCaptureTests.
final class PulseAudioOutputTests: XCTestCase {
    func testToneOrCleanUnavailable() throws {
        let out = PulseAudioOutput(appName: "MpVFX-tests")
        do { try out.start() } catch AudioOutputError.unavailable(let why) {
            XCTAssertFalse(why.isEmpty)
            XCTAssertThrowsError(try out.write([0, 0])) { XCTAssertEqual($0 as? AudioOutputError, .unavailable("not started")) }
            return
        }
        let n = try ToneCheck.play(into: out)
        XCTAssertLessThanOrEqual(out.framesPlayed, n)
        out.flush(); XCTAssertEqual(out.framesPlayed, 0)
        out.stop()
    }

    /// Settings > Audio output: the sinks, or nothing (no server) within the timeout; a chosen sink that does not exist
    /// fails to start cleanly instead of playing elsewhere.
    func testDevicesAnswerWithinTheTimeoutAndAMissingSinkIsUnavailable() throws {
        let start = Date()
        let devices = PulseAudioOutput.devices(timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count, "ids are unique")
        XCTAssertFalse(devices.contains { $0.id.isEmpty || $0.name.isEmpty })
        XCTAssertEqual(AudioOutputDevices.list().map(\.id), PulseAudioOutput.devices().map(\.id))

        let out = PulseAudioOutput(appName: "MpVFX-tests")
        out.device = "mpvfx-no-such-sink"
        XCTAssertEqual(out.device, "mpvfx-no-such-sink")
        XCTAssertThrowsError(try out.start()) { error in
            guard case AudioOutputError.unavailable = error else { return XCTFail("\(error)") }
        }
        out.stop()
    }
}
#endif
