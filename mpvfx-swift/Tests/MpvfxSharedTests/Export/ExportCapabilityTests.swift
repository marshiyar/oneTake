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

// What each export format produces with the media engine (the media engine's format table "Export (encode)").
// The capability table is asserted against the engine's formats; the recorded encoder presets (the
// "engine" section of
// Fixtures/exportParity.json) are kept as recorded but no longer asserted: they describe encoders the app does not use.
final class ExportCapabilityTests: XCTestCase {
    func testFixtureProvenance() {
        XCTAssertEqual(ExportFixture.root["engineVersion"]?.stringValue, "0.8.60")
        XCTAssertEqual(ExportFixture.root["parsersVersion"]?.stringValue, "0.8.20")
        XCTAssertEqual(ExportFixture.root["node"]?.stringValue, "v20.19.2")
    }

    func testMp4IsH264FromOurEncoderWithFlacSound() {
        let cap = exportFormatCapability(.mp4)
        XCTAssertTrue(cap.supported); XCTAssertNil(cap.unsupportedMessage)
        XCTAssertEqual(cap.video, .init(codec: "h264", encoder: "native-h264", pixelFormat: "yuv420p",
                                        rateControl: "quality-preset", qualityApplies: true))
        XCTAssertEqual(cap.audio, .init(codec: "flac", encoder: "mpvfx-flac", maxBitrateKbps: 1536, sampleRateHz: 48_000,
                                        channels: 2, bitDepth: 16, optional: true))
    }

    func testMovIsPngFramesWithEightBitAlphaAndLpcmSound() {
        let cap = exportFormatCapability(.mov)
        XCTAssertTrue(cap.supported); XCTAssertEqual(cap.label, "MOV (PNG, alpha)")
        XCTAssertEqual(cap.video, .init(codec: "png", encoder: "mpvfx-png", pixelFormat: "rgba",
                                        rateControl: "lossless", qualityApplies: false))
        XCTAssertEqual(cap.audio, .init(codec: "pcm_s16le", encoder: "mpvfx-pcm", maxBitrateKbps: 1536, sampleRateHz: 48_000,
                                        channels: 2, bitDepth: 16, optional: true))
    }

    func testWebMIsRefusedWithTheFormatsMessage() {
        let cap = exportFormatCapability(.webm)
        XCTAssertFalse(cap.supported)
        XCTAssertEqual(cap.unsupportedMessage, "WebM export is not supported yet.")
        XCTAssertEqual(cap.label, "WebM (not supported yet)")
        XCTAssertEqual([cap.video.encoder, cap.audio.encoder], [nil, nil])
    }

    func testOnlyMovKeepsAlpha() {
        XCTAssertEqual(EXPORT_FORMAT_CAPABILITIES.map(\.1.alpha),
                       [.init(supported: false, bitDepth: 0), .init(supported: false, bitDepth: 0), .init(supported: true, bitDepth: 8)])
    }

    func testNoFormatExportsHdr() {
        XCTAssertEqual(EXPORT_FORMAT_CAPABILITIES.map(\.1.color.hdr), [false, false, false])
    }

    func testTagsMp4AsLimitedRangeBT709() {
        XCTAssertEqual(exportFormatCapability(.mp4).color.sdr,
                       .init(primaries: "bt709", transfer: "bt709", matrix: "bt709", range: "limited"))
    }

    func testEstimatesAudioAtThePcmRate() {
        XCTAssertEqual(estimateExportAudioSizeBytes(10, .mp4, true), 1_920_000)
        XCTAssertEqual(estimateExportAudioSizeBytes(10, .mov, true), 1_920_000)
        XCTAssertEqual(estimateExportAudioSizeBytes(10, .webm, true), 0)
        XCTAssertEqual(estimateExportAudioSizeBytes(10, .mov, false), 0)
    }

    func testEstimatesNoAudioForAnInvalidDuration() {
        XCTAssertEqual([Double.nan, .infinity, -1, 0].map { estimateExportAudioSizeBytes($0, .mp4, true) }, [0, 0, 0, 0])
    }
}
