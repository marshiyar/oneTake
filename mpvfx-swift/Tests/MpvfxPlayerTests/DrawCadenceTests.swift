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
import MpvfxPlayer

/// Issue #94: the real-time bench records its draw cadence (`realtime_draw_interval_p95_ms`, `..._max_ms`).
final class DrawCadenceTests: XCTestCase {
    func testARateThatIsNotAFinitePositiveNumberIsRefused() {
        for rate in [0, -30, Double.nan, Double.infinity] { XCTAssertNil(DrawCadence(fps: rate), "\(rate)") }
        XCTAssertNotNil(DrawCadence(fps: 30))
    }

    func testDrawIntervalP95AndMaxAreMeasuredBetweenDrawStarts() throws {
        var cadence = try XCTUnwrap(DrawCadence(fps: 30))
        // 21 draws, 20 gaps: 18 of 30 ms, one of 60 ms and one of 90 ms.
        var start = 0.0
        for index in 0..<21 {
            cadence.record(start: start, frames: [index])
            start += index == 9 ? 0.090 : index == 14 ? 0.060 : 0.030
        }
        XCTAssertEqual(cadence.intervals.count, 20)
        let metrics = cadence.metrics()
        XCTAssertEqual(try XCTUnwrap(metrics["draw_interval_p95_ms"]), 60, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(metrics["draw_interval_max_ms"]), 90, accuracy: 1e-6)
    }

    func testRepeatedPicturesAreCountedApartFromNewOnes() throws {
        var cadence = try XCTUnwrap(DrawCadence(fps: 30))
        let shown: [[Int?]] = [[0], [0], [1], [2], [2], [2], [3]]
        for (index, frames) in shown.enumerated() { cadence.record(start: Double(index) / 30, frames: frames) }
        XCTAssertEqual(cadence.changes, 4)
        XCTAssertEqual(cadence.repeats, 3)
        XCTAssertEqual(cadence.metrics()["repeat_draws"], 3)
    }

    func testLatenessIsMeasuredFromEachDrawsDeadline() throws {
        var cadence = try XCTUnwrap(DrawCadence(fps: 30))
        for index in 0..<4 {
            cadence.record(start: cadence.deadline(index) + (index == 2 ? 0.040 : 0.001), frames: [index])
        }
        XCTAssertEqual(cadence.lateness.count, 4)
        XCTAssertEqual(try XCTUnwrap(cadence.metrics()["draw_late_max_ms"]), 40, accuracy: 1e-6)
        XCTAssertEqual(cadence.lateness[0], 0.001, accuracy: 1e-9)
    }

    /// The frame a draw at `start` seconds samples, as `PreviewComposition.frameIndex(at:)` maps time at 30 fps.
    private func frame(at start: Double) -> Int { Int((start * 30 + 1e-6).rounded(.down)) }

    /// Failed with draws due on frame boundaries (`deadline(n) == n / fps`): a wake 0.5 ms early sampled the frame
    /// before, the draw after it the same frame again, and the frame between was never shown.
    func testMidFrameDeadlinesSampleEveryFrameUnderWakeJitter() throws {
        var cadence = try XCTUnwrap(DrawCadence(fps: 30))
        let jitter = [-0.0005, 0.012, -0.002, 0.015, 0, -0.010, 0.0001, -0.015]   // seconds; all under half a frame
        for index in 0..<150 {
            let start = cadence.deadline(index) + jitter[index % jitter.count]
            cadence.record(start: start, frames: [frame(at: start)])
            XCTAssertEqual(frame(at: start), index, "draw \(index) sampled another frame")
        }
        XCTAssertEqual(cadence.changes, 150)
        XCTAssertEqual(cadence.repeats, 0)
    }

    func testEachDrawIsDueInsideItsOwnFrame() throws {
        let cadence = try XCTUnwrap(DrawCadence(fps: 30))
        for index in [0, 1, 29, 30, 149, 10_000] {
            let due = cadence.deadline(index)
            XCTAssertGreaterThan(due, Double(index) / 30, "\(index)")
            XCTAssertLessThan(due, Double(index + 1) / 30, "\(index)")
        }
        XCTAssertEqual(cadence.deadline(-5), cadence.deadline(0))
    }

    func testNoDrawsGiveZeroesNotATrap() throws {
        let cadence = try XCTUnwrap(DrawCadence(fps: 30))
        XCTAssertEqual(cadence.metrics().values.reduce(0, +), 0)
        XCTAssertEqual(DrawCadence.quantile([], 0.95), 0)
        XCTAssertEqual(DrawCadence.quantile([1, 2], .nan), 0)
        XCTAssertEqual(DrawCadence.quantile([1, 2, 3], 7), 3)
        XCTAssertEqual(DrawCadence.quantile([1, 2, 3], -1), 1)
    }
}
