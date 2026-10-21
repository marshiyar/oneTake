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
import MpvfxShared
@testable import MpvfxRuntime

final class ClipInfoReadTests: XCTestCase {
    private func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "clipinfo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// A 0.1 s mono 8 kHz 16-bit PCM WAV.
    private func wav() -> Data {
        let samples = 800, dataBytes = samples * 2
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
        func u16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xff) } }
        var b = Array("RIFF".utf8) + u32(36 + dataBytes) + Array("WAVEfmt ".utf8) + u32(16) + u16(1) + u16(1)
        b += u32(8000) + u32(16000) + u16(2) + u16(16) + Array("data".utf8) + u32(dataBytes)
        return Data(b + [UInt8](repeating: 0, count: dataBytes))
    }

    func testAMissingFileIsOfflineWithItsResolvedPath() throws {
        let dir = try tempDir()
        let info = try readProjectClipInfo(dir, "media/gone.mp4")
        XCTAssertTrue(info.offline)
        XCTAssertTrue(info.path.hasSuffix("/media/gone.mp4"))
        XCTAssertNil(info.container)
    }

    func testAnAudioFileReportsItsStreamsAndSize() throws {
        let dir = try tempDir()
        let data = wav()
        try data.write(to: URL(fileURLWithPath: dir + "/tone.wav"))
        let info = try readProjectClipInfo(dir, "tone.wav")
        XCTAssertFalse(info.offline)
        XCTAssertEqual(info.fileSize, Int64(data.count))
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 8000)
        XCTAssertNil(info.videoCodec)
        XCTAssertNotNil(info.container)
    }

    func testHostileSourcesThrowTypedErrors() throws {
        let dir = try tempDir()
        XCTAssertThrowsError(try readProjectClipInfo(dir, ""))
        XCTAssertThrowsError(try readProjectClipInfo(dir, "a\0b"))
        XCTAssertThrowsError(try readProjectClipInfo(dir, dir), "a folder is not a media file")
    }
}
