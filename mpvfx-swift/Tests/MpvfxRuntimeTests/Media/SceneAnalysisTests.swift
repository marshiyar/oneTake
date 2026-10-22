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
import Foundation
import XCTest
@testable import MpvfxRuntime

final class SceneAnalysisTests: XCTestCase {
    var root = ""
    override func setUpWithError() throws {
        root = try makeMediaTempDir("mpvfx-scenes-")
        let red = TestMedia.solid((255, 0, 0), width: 16, height: 16)
        let blue = TestMedia.solid((0, 0, 255), width: 16, height: 16)
        let green = TestMedia.solid((0, 255, 0), width: 16, height: 16)
        let frames = Array(repeating: red, count: 10) + Array(repeating: blue, count: 10) + Array(repeating: green, count: 10)
        try TestMedia.writeMOV(root + "/cuts.mov", frames: frames, width: 16, height: 16, fps: 10)
    }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    func testGeneratedClipFindsKnownCutsWithinTrimAndReportsProgress() throws {
        var progress: [Double] = []
        let cuts = try analyzeProjectScenes(root, source: "cuts.mov", sourceStart: 0.5, sourceDuration: 2,
            framesPerSecond: 10, threshold: 0.3, cancellation: MediaCancellation(), onProgress: { progress.append($0) })
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[0], 1, accuracy: 0.000001)
        XCTAssertEqual(cuts[1], 2, accuracy: 0.000001)
        XCTAssertEqual(progress.first, 0); XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
    }

    func testThresholdAndUnchangingTrimDoNotManufactureCuts() throws {
        XCTAssertEqual(try analyzeProjectScenes(root, source: "cuts.mov", sourceStart: 0, sourceDuration: 3,
            framesPerSecond: 10, threshold: 0.9, cancellation: MediaCancellation()), [])
        XCTAssertEqual(try analyzeProjectScenes(root, source: "cuts.mov", sourceStart: 1.1, sourceDuration: 0.5,
            framesPerSecond: 10, threshold: 0.1, cancellation: MediaCancellation()), [])
    }

    func testCancellationBetweenFramesDiscardsPartialResult() throws {
        let cancellation = MediaCancellation()
        XCTAssertThrowsError(try analyzeProjectScenes(root, source: "cuts.mov", sourceStart: 0, sourceDuration: 3,
            framesPerSecond: 10, threshold: 0.3, cancellation: cancellation, onProgress: {
                if $0 > 0.3 { cancellation.cancel() }
            })) { XCTAssertTrue($0 is MediaAbortError) }
    }

    func testRejectsInvalidRequestsAndEscapingSource() throws {
        for threshold in [0.0, -1, 1.1, Double.nan] {
            XCTAssertThrowsError(try analyzeProjectScenes(root, source: "cuts.mov", sourceStart: 0, sourceDuration: 3,
                framesPerSecond: 10, threshold: threshold, cancellation: MediaCancellation()))
        }
        let outside = root + "-outside.mov"
        try FileManager.default.copyItem(atPath: root + "/cuts.mov", toPath: outside)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/escape.mov", withDestinationPath: outside)
        XCTAssertThrowsError(try analyzeProjectScenes(root, source: "escape.mov", sourceStart: 0, sourceDuration: 1,
            framesPerSecond: 10, threshold: 0.3, cancellation: MediaCancellation()))
    }
}
