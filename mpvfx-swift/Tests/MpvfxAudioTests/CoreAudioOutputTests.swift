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
#if os(macOS)
import Foundation
import XCTest
@testable import MpvfxAudio

/// Settings > Audio output on macOS: the devices with output channels (none on a runner without audio hardware), with
/// unique, non-empty UIDs and names.
final class CoreAudioOutputTests: XCTestCase {
    func testDevicesListAndAMissingDeviceFallsBackToTheDefault() throws {
        let devices = CoreAudioOutput.devices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count, "UIDs are unique")
        XCTAssertFalse(devices.contains { $0.id.isEmpty || $0.name.isEmpty })
        XCTAssertEqual(AudioOutputDevices.list().map(\.id), devices.map(\.id))
        XCTAssertTrue(devices.allSatisfy { CoreAudioOutput.deviceID(uid: $0.id) != nil }, "every listed UID resolves")

        // A chosen device that is gone plays on the default one, as the system would: start succeeds or fails exactly
        // as it does with no choice (no audio hardware on a CI runner).
        func starts(_ out: CoreAudioOutput) -> Bool {
            defer { out.stop() }
            do { try out.start(); return true } catch AudioOutputError.unavailable { return false } catch { XCTFail("\(error)"); return false }
        }
        let out = CoreAudioOutput()
        out.device = "mpvfx-no-such-device"
        XCTAssertEqual(out.device, "mpvfx-no-such-device")
        XCTAssertEqual(starts(out), starts(CoreAudioOutput()))
        XCTAssertEqual(out.device, "mpvfx-no-such-device", "the choice is kept for when it is back")
    }
}
#endif
