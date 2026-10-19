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
// Silence analysis on the media engine: the clips are MOVs written by our
// MediaWriter (PNG frames + PCM), so the pause sits at a known sample.
import Foundation
import XCTest
@testable import MpvfxRuntime

final class SilenceAnalysisTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws {
        root = try makeMediaTempDir("mpvfx-silence-")
        let rate = 48_000
        // 3 s: a 440 Hz tone, silence from 1 s to 2 s, the tone again.
        let speech = (0..<(rate * 3)).map { i -> Float in
            i < rate || i >= rate * 2 ? 0.37 * Float(sin(Double(i) * 2 * .pi * 440 / Double(rate))) : 0
        }
        let black = TestMedia.solid((0, 0, 0), width: 16, height: 16)
        try TestMedia.writeMOV(root + "/speech.mov", frames: Array(repeating: black, count: 30), width: 16, height: 16, fps: 10, audio: speech)
        try TestMedia.writeMOV(root + "/mute.mov", frames: Array(repeating: black, count: 10), width: 16, height: 16, fps: 10)
        try TestMedia.movie([TestMedia.pngTrack([black, black], width: 16, height: 16), TestMedia.aacTrack()])
            .write(to: URL(fileURLWithPath: root + "/aac.mp4"))
    }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    func testFindsARealPauseAndKeepsSourceTimeOffsets() throws {
        let ranges = try analyzeProjectVideoSilence(root, .init(source: "speech.mov", sourceStart: 0.5, sourceDuration: 2),
                                                    cancellation: MediaCancellation())
        XCTAssertEqual(ranges.count, 1)
        XCTAssertGreaterThan(ranges[0].start, 1.05); XCTAssertLessThan(ranges[0].start, 1.25)
        XCTAssertGreaterThan(ranges[0].end, 1.75); XCTAssertLessThan(ranges[0].end, 1.95)
    }

    /// AAC sound is analysed like any other: TestMedia.aacTrack's sine (0.53 s, after a 1024-frame encoder delay)
    /// holds no pause.
    func testAnalysesAACSound() throws {
        let ranges = try analyzeProjectVideoSilence(root, .init(source: "aac.mp4", sourceStart: 0.05, sourceDuration: 0.45),
                                                    cancellation: MediaCancellation())
        XCTAssertEqual(ranges, [])
    }

    func testRejectsAVideoWithoutAudioAndProjectEscapingSymlinks() throws {
        XCTAssertThrowsError(try analyzeProjectVideoSilence(root, .init(source: "mute.mov", sourceStart: 0, sourceDuration: 1),
                                                            cancellation: MediaCancellation())) {
            XCTAssertTrue(String(describing: $0).contains("no audio track"), "\($0)")
        }
        let outside = root + "-outside.mov"
        try FileManager.default.copyItem(atPath: root + "/speech.mov", toPath: outside)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/escape.mov", withDestinationPath: outside)
        XCTAssertThrowsError(try analyzeProjectVideoSilence(root, .init(source: "escape.mov", sourceStart: 0, sourceDuration: 1),
                                                            cancellation: MediaCancellation())) {
            XCTAssertTrue(String(describing: $0).contains("inside this project"), "\($0)")
        }
    }
}
