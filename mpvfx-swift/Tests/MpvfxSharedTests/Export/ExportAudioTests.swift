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
import XCTest
@testable import MpvfxShared

/// Export audio: sizes and the audio each format carries (the codecs are the media engine's).
final class ExportAudioTests: XCTestCase {
    /// MP4 carries FLAC, MOV 16-bit LPCM, both 48 kHz stereo (formats.md).
    func testMuxesAudioPerFormat() {
        XCTAssertEqual(EXPORT_FORMAT_CAPABILITIES.map(\.1.audio.codec), ["flac", "opus", "pcm_s16le"])
        XCTAssertEqual(EXPORT_FORMAT_CAPABILITIES.map(\.1.audio.encoder), ["mpvfx-flac", nil, "mpvfx-pcm"])
        XCTAssertEqual(Set(EXPORT_FORMAT_CAPABILITIES.map { [$0.1.audio.sampleRateHz, $0.1.audio.channels] }), [[48_000, 2]])
    }
    func testDoesNotRequireAnAudioTrackToExportVideo() {
        for (_, cap) in EXPORT_FORMAT_CAPABILITIES { XCTAssertTrue(cap.audio.optional) }
    }
}
