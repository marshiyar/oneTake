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
// Video thumbnail frames on the media
// engine: the clips are written by our MediaWriter (and a hand-built rotated MOV), and the returned JPEG frames are
// decoded back to check their pixels.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxRuntime

final class VideoFramesTests: XCTestCase {
    private var root = ""
    private let red: (UInt8, UInt8, UInt8) = (255, 0, 0), blue: (UInt8, UInt8, UInt8) = (0, 0, 255)
    override func setUpWithError() throws {
        root = try makeMediaTempDir("native-frames-")
        // 1 s at 10 fps: red for the first half, blue for the second.
        let frames = (0..<10).map { TestMedia.solid($0 < 5 ? red : blue, width: 64, height: 32) }
        try TestMedia.writeMOV(root + "/clip.mov", frames: frames, width: 64, height: 32, fps: 10)
    }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    private func decoded(_ frame: String) throws -> (rgba: [UInt8], width: Int, height: Int) {
        let jpeg = try XCTUnwrap(Data(base64Encoded: frame))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        return try ImageCodec.decode(jpeg)
    }
    private func assertColour(_ c: (Double, Double, Double), _ rgb: (UInt8, UInt8, UInt8), _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for (got, want) in [(c.0, rgb.0), (c.1, rgb.1), (c.2, rgb.2)] {
            XCTAssertEqual(got, Double(want), accuracy: 24, "\(what): \(c)", file: file, line: line)
        }
    }

    func testDecodesRealMediaFramesAsJPEGsOfTheRequestedSize() throws {
        let result = try decodeNativeVideoFrames(root, .init(source: "clip.mov", sourceStart: 0, sourceRangeDuration: 1, frameCount: 2, width: 120, height: 80),
                                                 cancellation: MediaCancellation())
        XCTAssertEqual(result.aspect, 2); XCTAssertEqual(result.width, 120); XCTAssertEqual(result.height, 60)
        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        XCTAssertEqual(result.frames.count, 2)
        let first = try decoded(result.frames[0]), last = try decoded(result.frames[1])
        XCTAssertEqual(first.width, 120); XCTAssertEqual(first.height, 60)
        assertColour(TestMedia.mean(first.rgba, width: 120, x: 10..<110, y: 10..<50), red, "first frame")
        assertColour(TestMedia.mean(last.rgba, width: 120, x: 10..<110, y: 10..<50), blue, "last frame")
    }

    /// A track turned 90° clockwise: the stored left (red) half is shown on top, and the strip is portrait.
    func testThumbnailsAreDrawnUpright() throws {
        let stored = TestMedia.split(red, blue, width: 40, height: 20)
        let movie = TestMedia.movie([TestMedia.pngTrack([stored, stored], width: 40, height: 20, rotation: 90)], quicktime: true)
        try movie.write(to: URL(fileURLWithPath: root + "/turned.mov"))
        let result = try decodeNativeVideoFrames(root, .init(source: "turned.mov", frameCount: 1, width: 120, height: 80), cancellation: MediaCancellation())
        XCTAssertEqual(result.aspect, 0.5); XCTAssertEqual(result.width, 40); XCTAssertEqual(result.height, 80)
        let frame = try decoded(result.frames[0])
        assertColour(TestMedia.mean(frame.rgba, width: 40, x: 8..<32, y: 6..<30), red, "top")
        assertColour(TestMedia.mean(frame.rgba, width: 40, x: 8..<32, y: 50..<74), blue, "bottom")
    }

    func testRefusesAVideoTheEngineCannotDecodeWithItsReason() throws {
        try TestMedia.movie([TestMedia.opaqueVideoTrack("vp09")]).write(to: URL(fileURLWithPath: root + "/vp9.mp4"))
        XCTAssertThrowsError(try decodeNativeVideoFrames(root, .init(source: "vp9.mp4", frameCount: 1, width: 120, height: 80),
                                                         cancellation: MediaCancellation())) {
            XCTAssertEqual(($0 as? MediaToolError)?.message, "This video format is not supported yet: vp9 in mp4.")
        }
    }

    /// HEVC (an iPhone-style portrait MOV, display rotation 90°): thumbnails decode upright, portrait.
    func testDecodesHEVCThumbnailsUpright() throws {
        try FileManager.default.copyItem(atPath: engineFixture("hevc/hvc1_rot90.mov"), toPath: root + "/phone.mov")
        let result = try decodeNativeVideoFrames(root, .init(source: "phone.mov", sourceStart: 0, sourceRangeDuration: 1, frameCount: 3, width: 120, height: 80),
                                                 cancellation: MediaCancellation())
        XCTAssertEqual(result.frames.count, 3)
        XCTAssertEqual(result.aspect, 90.0 / 160.0, accuracy: 1e-9)
        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        let first = try decoded(result.frames[0])
        XCTAssertEqual(first.width, result.width); XCTAssertEqual(first.height, result.height)
        XCTAssertGreaterThan(first.height, first.width)
    }

    func testBlocksMediaPathsOutsideTheOwningProject() throws {
        let outside = root + "-outside.mov"
        try FileManager.default.copyItem(atPath: root + "/clip.mov", toPath: outside)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/outside.mov", withDestinationPath: outside)
        XCTAssertThrowsError(try decodeNativeVideoFrames(root, .init(source: "outside.mov", frameCount: 1, width: 120, height: 80),
                                                         cancellation: MediaCancellation())) {
            XCTAssertTrue(String(describing: $0).contains("inside this project"), "\($0)")
        }
    }

    func testCancelsBeforeDecoding() {
        let abort = MediaCancellation(); abort.cancel()
        XCTAssertThrowsError(try decodeNativeVideoFrames(root, .init(source: "clip.mov", frameCount: 1, width: 120, height: 80),
                                                         cancellation: abort)) {
            XCTAssertTrue($0 is MediaAbortError, "\($0)")
        }
    }
}
