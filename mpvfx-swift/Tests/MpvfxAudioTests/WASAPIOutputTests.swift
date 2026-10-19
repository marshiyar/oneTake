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
}
#endif
