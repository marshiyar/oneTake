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
// Region tracker on synthetic sequences: a textured square on a known path with noise.
import Foundation
import XCTest
@testable import MpvfxRuntime

final class RegionTrackerTests: XCTestCase {
    /// Deterministic noise in -1...1.
    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFF) / 32768 - 1
        }
    }
    private func texture(_ u: Double, _ v: Double) -> Float {
        // Frequencies below ~0.7 rad/px (periods of 9 px and up), like the soft texture of real footage.
        let t = sin(u * 0.25 + 0.3) * cos(v * 0.21) + 0.6 * sin(u * 0.45 + v * 0.3) + 0.5 * cos(v * 0.55 - u * 0.2) + 0.3 * sin((u + v) * 0.7)
        return 0.5 + 0.2 * Float(t)
    }
    /// Frame with a square of half-size `half * scale` centred at (cx, cy); `occluded` covers it with flat grey.
    private func frame(width: Int = 320, height: Int = 240, cx: Double, cy: Double, scale: Double = 1, half: Double = 32,
                       occluded: Bool = false, seed: UInt64) -> TrackLumaFrame {
        var noise = Noise(state: seed)
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let u = (Double(x) - cx) / scale, v = (Double(y) - cy) / scale
            var value: Float
            if occluded && abs(Double(x) - cx) < half * scale + 6 && abs(Double(y) - cy) < half * scale + 6 { value = 0.45 }
            else if abs(u) <= half && abs(v) <= half { value = texture(u, v) }
            else { value = 0.3 + 0.1 * Float(sin(Double(x) * 0.13) * cos(Double(y) * 0.11)) }
            px[y * width + x] = value + 0.02 * noise.next()
        } }
        return TrackLumaFrame(width: width, height: height, pixels: px)
    }
    private func box(cx: Double, cy: Double, size: Double = 48) -> TrackBox {
        TrackBox(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
    }

    func testA1TracksKnownPathWithinHalfPixelRMS() throws {
        func center(_ k: Int) -> (Double, Double) { (90 + 3.3 * Double(k), 100 + 1.7 * Double(k) + 6 * sin(Double(k) * 0.4)) }
        let n = 30
        let frames = (0...n).map { k -> TrackLumaFrame in let c = center(k); return frame(cx: c.0, cy: c.1, seed: UInt64(k + 1)) }
        let c0 = center(0)
        let r = try RegionTracker.track(box: box(cx: c0.0, cy: c0.1), startFrame: 0, frames: { $0 < frames.count ? frames[$0] : nil })
        XCTAssertNil(r.stoppedAt)
        XCTAssertEqual(r.samples.count, n + 1)
        var sq = 0.0
        for s in r.samples { let c = center(s.frame); sq += (s.x - c.0) * (s.x - c.0) + (s.y - c.1) * (s.y - c.1) }
        let rms = (sq / Double(r.samples.count)).squareRoot()
        XCTAssertLessThan(rms, 0.5, "RMS \(rms)")
    }

    func testA1TracksBackward() throws {
        let frames = (0...10).map { k in frame(cx: 100 + 3 * Double(k), cy: 100, seed: UInt64(k + 7)) }
        let r = try RegionTracker.track(box: box(cx: 130, cy: 100), startFrame: 10, forward: false, frames: { $0 >= 0 && $0 < frames.count ? frames[$0] : nil })
        XCTAssertEqual(r.samples.last?.frame, 0)
        XCTAssertEqual(r.samples.last!.x, 100, accuracy: 0.5)
    }

    func testA2FollowsGrowingSquareWithinTwoPercentScale() throws {
        let n = 30
        func scale(_ k: Int) -> Double { pow(1.01, Double(k)) }
        let frames = (0...n).map { k in frame(cx: 150 + 1.5 * Double(k), cy: 120, scale: scale(k), half: 40, seed: UInt64(k + 100)) }
        var o = RegionTrackerOptions(); o.scaleSearch = true
        let r = try RegionTracker.track(box: box(cx: 150, cy: 120, size: 40), startFrame: 0, options: o, frames: { $0 < frames.count ? frames[$0] : nil })
        XCTAssertNil(r.stoppedAt)
        for s in r.samples {
            XCTAssertEqual(s.scale / scale(s.frame), 1, accuracy: 0.02, "frame \(s.frame) scale \(s.scale) vs \(scale(s.frame))")
        }
    }

    func testA3OcclusionStopsTheTrackAtThatFrame() throws {
        let frames = (0...20).map { k in frame(cx: 100 + 2 * Double(k), cy: 100, occluded: k >= 12, seed: UInt64(k + 50)) }
        let r = try RegionTracker.track(box: box(cx: 100, cy: 100), startFrame: 0, frames: { $0 < frames.count ? frames[$0] : nil })
        XCTAssertEqual(r.stoppedAt, 12)
        XCTAssertEqual(r.samples.last?.frame, 11)
        XCTAssertLessThan(r.stoppedConfidence ?? 1, RegionTrackerOptions().confidenceThreshold)
    }

    func testInvalidBoxAndFlatTextureAreRejected() {
        let flat = TrackLumaFrame(width: 64, height: 64, pixels: [Float](repeating: 0.5, count: 64 * 64))
        XCTAssertThrowsError(try RegionTracker.track(box: TrackBox(x: 0, y: 0, width: 2, height: 2), startFrame: 0, frames: { _ in flat })) {
            XCTAssertEqual($0 as? RegionTrackerError, .invalidBox)
        }
        XCTAssertThrowsError(try RegionTracker.track(box: TrackBox(x: 8, y: 8, width: 32, height: 32), startFrame: 0, frames: { _ in flat })) {
            XCTAssertEqual($0 as? RegionTrackerError, .textureTooLow)
        }
    }

    func testA4CancellationStopsTheTrack() throws {
        let f = frame(cx: 100, cy: 100, seed: 1)
        let cancellation = MediaCancellation()
        XCTAssertThrowsError(try RegionTracker.track(box: box(cx: 100, cy: 100), startFrame: 0, cancellation: cancellation, frames: { n in
            if n == 5 { cancellation.cancel() }
            return f
        })) { XCTAssertTrue($0 is MediaAbortError) }
    }

    func testA4GateCancellationOffTheMainThread() async throws {
        let f = frame(cx: 100, cy: 100, seed: 1)
        let reached = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let cancellation = MediaCancellation()
        let b = box(cx: 100, cy: 100)
        let task = Task {
            try await RegionTracker.trackOffMain(box: b, startFrame: 0, cancellation: cancellation, frames: { n in
                if n == 3 { reached.signal(); gate.wait() }
                return f
            })
        }
        await Task.detached { reached.wait() }.value
        task.cancel()
        gate.signal()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is MediaAbortError) }
    }

    /// Measured against the epic's budget: a 64x64 patch on 1080p at >= 60 frames per second on one core.
    func testA4ThroughputOnA1080pPatch() throws {
        let n = 24
        let frames = (0...n).map { k in frame(width: 1920, height: 1080, cx: 600 + 2.5 * Double(k), cy: 500 + Double(k), half: 40, seed: UInt64(k + 1)) }
        let start = Date()
        let r = try RegionTracker.track(box: box(cx: 600, cy: 500, size: 64), startFrame: 0, frames: { $0 < frames.count ? frames[$0] : nil })
        let elapsed = Date().timeIntervalSince(start)
        let fps = Double(r.samples.count - 1) / elapsed
        print("RegionTracker throughput: \(Int(fps)) frames/s (64x64 patch, 1080p, radius 16)")
        XCTAssertEqual(r.samples.count, n + 1)
        #if !DEBUG
        XCTAssertGreaterThanOrEqual(fps, 60)
        #endif
    }
}
