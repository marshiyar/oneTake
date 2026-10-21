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
#if os(Windows)
import Foundation
import XCTest
@testable import MpvfxAudio

/// The WASAPI sink on the machine's default render endpoint. With one it plays the 440 Hz tone through
/// WASAPIOutput and checks the clock and flush; on a machine with no audio endpoint (a hosted CI runner) it asserts
/// start() fails cleanly with `.unavailable` and a write is refused. It does not skip either way. The tone content
/// itself is asserted headlessly in ToneCaptureTests.
final class WASAPIOutputTests: XCTestCase {
    func testToneOrCleanUnavailable() throws {
        let out = WASAPIOutput()
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

    /// Settings > Audio output: the active endpoints (none on a hosted runner) with unique, non-empty ids and names.
    func testDevicesListAndAMissingEndpointPlaysOnTheDefault() throws {
        let devices = WASAPIOutput.devices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count, "ids are unique")
        XCTAssertFalse(devices.contains { $0.id.isEmpty || $0.name.isEmpty })
        XCTAssertEqual(AudioOutputDevices.list().map(\.id), devices.map(\.id))

        // A chosen endpoint that is gone plays on the default one, as the system would: start succeeds or fails exactly
        // as it does with no choice (no audio hardware on a CI runner).
        func starts(_ out: WASAPIOutput) -> Bool {
            defer { out.stop() }
            do { try out.start(); return true } catch AudioOutputError.unavailable { return false } catch { XCTFail("\(error)"); return false }
        }
        let out = WASAPIOutput()
        out.device = "{0.0.0.00000000}.{mpvfx-no-such-endpoint}"
        XCTAssertEqual(out.device, "{0.0.0.00000000}.{mpvfx-no-such-endpoint}")
        XCTAssertEqual(starts(out), starts(WASAPIOutput()))
        XCTAssertEqual(out.device, "{0.0.0.00000000}.{mpvfx-no-such-endpoint}", "the choice is kept for when it is back")
    }
}
#endif
