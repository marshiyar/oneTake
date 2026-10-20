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
}
#endif
