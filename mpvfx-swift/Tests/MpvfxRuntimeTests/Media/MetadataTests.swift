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
// Media metadata: these checks probe inputs written by our own code (and committed engine
// fixtures) with the media engine.
import Foundation
import XCTest
@testable import MpvfxRuntime

final class MetadataTests: XCTestCase {
    private var dir = ""
    override func setUpWithError() throws { dir = try makeMediaTempDir("mpvfx-metadata-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir); super.tearDown() }
    private func write(_ name: String, _ data: Data) throws { try data.write(to: URL(fileURLWithPath: dir + "/" + name)) }

    func testReadsPictureSoundAndDurationOfAMOVWrittenByTheEngine() throws {
        let frames = (0..<20).map { _ in TestMedia.solid((255, 0, 0), width: 64, height: 32) }
        try TestMedia.writeMOV(dir + "/clip.mov", frames: frames, width: 64, height: 32, fps: 10, audio: TestMedia.tone(seconds: 2, rate: 48_000))
        let m = try readProjectMediaMetadata(dir, "clip.mov")
        XCTAssertTrue(m.hasVideo); XCTAssertTrue(m.hasAudio)
        XCTAssertEqual(m.duration, 2, accuracy: 0.05)
        XCTAssertEqual(m.width, 64); XCTAssertEqual(m.height, 32)
    }

    func testAudioOnlyAndStillFacts() throws {
        try write("tone.wav", TestMedia.wav(TestMedia.tone(seconds: 1.5, rate: 8000), rate: 8000, channels: 1))
        let wav = try readProjectMediaMetadata(dir, "tone.wav")
        XCTAssertEqual(wav, .init(duration: 1.5, hasVideo: false, hasAudio: true))
        try write("still.png", TestMedia.png(TestMedia.solid((0, 255, 0), width: 30, height: 12), width: 30, height: 12))
        let png = try readProjectMediaMetadata(dir, "still.png")
        XCTAssertEqual(png, .init(duration: 0, hasVideo: true, hasAudio: false, width: 30, height: 12))
        try write("still.bmp", TestMedia.bmp(TestMedia.solid((0, 0, 255), width: 7, height: 5), width: 7, height: 5))
        XCTAssertEqual(try readProjectMediaMetadata(dir, "still.bmp").width, 7)
    }

    /// A track matrix turned 90° shows the picture on its side: the natural size swaps (the H.264 fixtures
    /// rot90/rot180 are 160×90 coded) and so does a PNG track written with the same matrix.
    func testRotationTurnsTheNaturalSize() throws {
        let rot90 = try readProjectMediaMetadata(engineFixture("isobmff"), "rot90.mp4")
        XCTAssertEqual(rot90.width, 90); XCTAssertEqual(rot90.height, 160)
        let rot180 = try readProjectMediaMetadata(engineFixture("isobmff"), "rot180.mp4")
        XCTAssertEqual(rot180.width, 160); XCTAssertEqual(rot180.height, 90)
        let frame = TestMedia.solid((9, 9, 9), width: 40, height: 20)
        try write("turned.mov", TestMedia.movie([TestMedia.pngTrack([frame, frame], width: 40, height: 20, rotation: 270)], quicktime: true))
        let turned = try readProjectMediaMetadata(dir, "turned.mov")
        XCTAssertEqual(turned.width, 20); XCTAssertEqual(turned.height, 40)
        XCTAssertEqual(turned.duration, 0.2, accuracy: 0.001)
    }

    /// AAC audio decodes (formats.md v1): a video with an AAC track has picture and sound.
    func testAACAudioCountsAsSound() throws {
        let frame = TestMedia.solid((1, 2, 3), width: 16, height: 16)
        try write("aac.mp4", TestMedia.movie([TestMedia.pngTrack([frame], width: 16, height: 16), TestMedia.aacTrack()]))
        let m = try readProjectMediaMetadata(dir, "aac.mp4")
        XCTAssertTrue(m.hasVideo); XCTAssertTrue(m.hasAudio)
    }

    func testRejectsPathsOutsideTheProjectAndUnreadableFiles() throws {
        XCTAssertThrowsError(try readProjectMediaMetadata(dir, ""))
        _ = FileManager.default.createFile(atPath: dir + "/a.mp4", contents: Data("x".utf8))
        XCTAssertThrowsError(try readProjectMediaMetadata(dir + "/sub-missing", "../a.mp4"))
        // A real file outside the project (not /etc/hostname, which macOS does not have).
        let outside = dir + "-outside.mp4"
        _ = FileManager.default.createFile(atPath: outside, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: outside) }
        XCTAssertThrowsError(try readProjectMediaMetadata(dir, outside)) {
            XCTAssertEqual(($0 as? MediaToolError)?.message, "Media must be a file inside this project")
        }
        XCTAssertThrowsError(try readProjectMediaMetadata(dir, "a.mp4")) { XCTAssertTrue($0 is MediaToolError, "\($0)") }
    }
}
