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
@testable import MpvfxPlayer
import MpvfxCanvas

final class PreviewDecodeBudgetTests: XCTestCase {
    let size = PreviewDecodeSize(width: 64, height: 36)
    let frameBytes = 64 * 36 * 4
    // Binary-exact frame times keep this cache regression independent of media timestamp rounding.
    let video = TestMedia.PatternVideo(width: 64, height: 36, fps: 8, seconds: 4)
    var dir: URL!
    var source: String!

    override func setUpWithError() throws {
        dir = try TestMedia.scratch("decode-budget")
        source = try video.write(to: dir.appendingPathComponent("pattern.mov").path)
    }

    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func lane(budget: Int) -> PreviewDecodeLane {
        let layer = PreviewLayer(clipId: "clip", source: source, kind: .video, start: 0, end: 4,
                                 sourceIn: 0, startFrame: 0, endFrame: 32,
                                 box: CanvasRect(x: 0, y: 0, width: 64, height: 36))
        return PreviewDecodeLane(layer: layer, fps: 8, cache: PreviewFrameCache(budgetBytes: budget, pressure: nil))
    }

    /// Exercise the production steps a fixed number of times: the unfixed pump must never hang the test process.
    func assertBounded(reverse: Bool, budget: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let lane = lane(budget: budget)
        defer { stop(lane) }
        let wanted = reverse ? 20 : 0
        lane.want = wanted // no queued work; the steps below run synchronously
        var idle = false
        var cached: [[Int]] = []
        for _ in 0..<16 {
            let worked = reverse ? lane.stepReverse(want: wanted, behind: 8, size: size)
                                 : lane.stepVideo(want: wanted, ahead: max(2, budget / frameBytes + 1), size: size)
            cached.append(lane.cache.cachedFrames(lane: lane.key, from: 0, to: 31))
            if !worked { idle = true; break }
        }
        if !idle { print("BUDGET LOOP reverse=\(reverse) budget=\(budget) cache=\(cached)") }
        XCTAssertTrue(idle, "budget \(budget): decoding must finish, not refill evicted frames forever", file: file, line: line)
        let image = lane.cache.frame(lane: lane.key, frame: wanted)
        XCTAssertNotNil(image, "keep the current frame", file: file, line: line)
        if let image { XCTAssertTrue(image.rgba == video.frame(wanted), "exact pixels at frame \(wanted)", file: file, line: line) }
        XCTAssertLessThanOrEqual(lane.framesDecoded, max(1, budget / frameBytes), file: file, line: line)
    }

    func testForwardDecodingFitsSmallBudgetsAndKeepsCurrentFrame() throws {
        for budget in [frameBytes / 2, frameBytes, frameBytes * 2, frameBytes * 3, frameBytes * 5] {
            try assertBounded(reverse: false, budget: budget)
        }
    }

    func testReverseDecodingFitsSmallBudgetsAndKeepsCurrentFrame() throws {
        for budget in [frameBytes / 2, frameBytes, frameBytes * 2, frameBytes * 3, frameBytes * 5] {
            try assertBounded(reverse: true, budget: budget)
        }
    }

    /// A queue barrier with a deadline also covers the actual pump. stop() interrupts a cycling pump on failure.
    func drain(_ lane: PreviewDecodeLane) throws {
        let done = DispatchSemaphore(value: 0)
        lane.queue.async { done.signal() }
        if done.wait(timeout: .now() + 5) != .success {
            lane.stop()
            XCTFail("preview pump did not become idle within five seconds")
            throw CocoaError(.userCancelled)
        }
    }

    func stop(_ lane: PreviewDecodeLane) {
        lane.stop()
        let done = DispatchSemaphore(value: 0)
        lane.queue.async { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "stopped decoder must release its queue")
    }

    func testRepeatedPlaybackRequestsAndPausedScrubbingWithOneFrameCache() throws {
        let lane = lane(budget: frameBytes)
        defer { stop(lane) }
        for (frame, ahead, behind) in [(0, 12, 0), (20, 0, 8), (3, 0, 0), (25, 0, 0), (1, 0, 0)] {
            lane.request(frame: frame, ahead: ahead, behind: behind, size: size)
            try drain(lane)
            XCTAssertTrue(try XCTUnwrap(lane.cache.frame(lane: lane.key, frame: frame)).rgba == video.frame(frame), "exact pixels at frame \(frame)")
            let decoded = lane.framesDecoded
            for _ in 0..<3 {
                lane.request(frame: frame, ahead: ahead, behind: behind, size: size)
                try drain(lane)
            }
            XCTAssertEqual(lane.framesDecoded, decoded, "an unchanged request must reuse the useful frame")
        }
    }

    func testReusedLargerFramesAlsoRespectTheBudget() throws {
        for reverse in [false, true] {
            let lane = lane(budget: frameBytes * 2)
            defer { stop(lane) }
            // The decoder may reuse a stream within 10% of the new size. Two of its larger frames do not fit.
            lane.request(frame: 20, ahead: 0, size: PreviewDecodeSize(width: 68, height: 38))
            try drain(lane)
            let decoded = lane.framesDecoded
            lane.request(frame: 20, ahead: reverse ? 0 : 12, behind: reverse ? 8 : 0, size: size)
            try drain(lane)
            XCTAssertNotNil(lane.cache.frame(lane: lane.key, frame: 20))
            XCTAssertEqual(lane.framesDecoded, decoded)
        }
    }

    func testCompositorAllowsZeroSpeculationWhenCurrentFramesUseTheBudget() throws {
        let comp = PreviewCompositorTests.composition(try PreviewCompositorTests.document())
        let layers = comp.layers(at: 0)
        let bytes = 200 * 100 * 4 * layers.count
        for budget in [1, bytes / 2, bytes] {
            let cx = PreviewCompositor(decodesMedia: false, cacheBudgetBytes: budget)
            XCTAssertEqual(cx.lookahead(layers, comp: comp, scale: 1, backing: 1, speed: 1), 0)
            XCTAssertEqual(cx.reverseChunk(layers, comp: comp, scale: 1, backing: 1, speed: 1), 0)
        }
    }
}
