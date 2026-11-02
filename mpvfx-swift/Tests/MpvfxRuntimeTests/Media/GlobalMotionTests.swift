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
import Foundation
import XCTest
@testable import MpvfxRuntime

/// Deterministic random numbers (SplitMix64) so a failure reproduces.
private struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
}

/// A textured still (value noise, several octaves) shaken by known per-frame translation and rotation.
private struct ShakySequence: GlobalMotionFrameSource {
    let still: LumaImage
    let width: Int, height: Int
    var translations: [(Double, Double)] = []
    var angles: [Double] = []
    var frameCount: Int { angles.count }
    var sourceWidth: Int { width }
    var sourceHeight: Int { height }
    var onFrame: (@Sendable () -> Void)?

    init(width: Int = 640, height: Int = 360, frames: Int, seed: UInt64, maxShift: Double = 6, maxDegrees: Double = 1) {
        self.width = width; self.height = height
        still = Self.makeStill(width: width + 200, height: height + 200, seed: seed)
        var rng = Rng(state: seed ^ 0xABCD)
        for _ in 0..<frames {
            translations.append((rng.range(-maxShift...maxShift), rng.range(-maxShift...maxShift)))
            angles.append(rng.range(-maxDegrees...maxDegrees) * .pi / 180)
        }
    }

    static func makeStill(width: Int, height: Int, seed: UInt64) -> LumaImage {
        var rng = Rng(state: seed)
        var pixels = [Float](repeating: 0, count: width * height)
        for (cell, amplitude) in [(48, 70.0), (20, 45.0), (9, 30.0), (4, 18.0)] {
            let gw = width / cell + 2, gh = height / cell + 2
            let grid = (0..<(gw * gh)).map { _ in Float(rng.unit() * amplitude) }
            for y in 0..<height {
                for x in 0..<width {
                    let fx = Float(x) / Float(cell), fy = Float(y) / Float(cell)
                    let x0 = Int(fx), y0 = Int(fy), tx = fx - Float(x0), ty = fy - Float(y0)
                    let a = grid[y0 * gw + x0] * (1 - tx) + grid[y0 * gw + x0 + 1] * tx
                    let b = grid[(y0 + 1) * gw + x0] * (1 - tx) + grid[(y0 + 1) * gw + x0 + 1] * tx
                    pixels[y * width + x] += a * (1 - ty) + b * ty
                }
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    func luma(at index: Int) throws -> LumaImage {
        onFrame?()
        let (tx, ty) = translations[index], c = cos(angles[index]), s = sin(angles[index])
        let cxs = Double(still.width) / 2, cys = Double(still.height) / 2
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) - Double(width) / 2 + 0.5, py = Double(y) - Double(height) / 2 + 0.5
                let sx = Float(cxs + c * px - s * py + tx - 0.5), sy = Float(cys + s * px + c * py + ty - 0.5)
                out[y * width + x] = still.sample(sx, sy)
            }
        }
        return LumaImage(width: width, height: height, pixels: out)
    }

    /// Truth for frame i against frame i-1: p_cur = R(-a_i) (R(a_prev) p + t_prev - t_i).
    func truth(_ i: Int) -> (tx: Double, ty: Double, rotation: Double) {
        let dx = translations[i - 1].0 - translations[i].0, dy = translations[i - 1].1 - translations[i].1
        let c = cos(-angles[i]), s = sin(-angles[i])
        return (c * dx - s * dy, s * dx + c * dy, angles[i - 1] - angles[i])
    }
}

private final class CountingDurableWrite: DurableWrite, @unchecked Sendable {
    let inner = TestDurableWrite()
    private let lock = NSLock()
    private var _writes: [String] = []
    var writes: [String] { lock.withLock { _writes } }
    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        lock.withLock { _writes.append(path) }
        try inner.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
    }
    func syncDirectory(_ path: String) throws { try inner.syncDirectory(path) }
}

final class GlobalMotionTests: XCTestCase {
    var root = ""
    override func setUpWithError() throws { root = try makeMediaTempDir("mpvfx-motion-") }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    // A1
    func testA1SyntheticShakeIsRecoveredWithin03PxAnd01Degree() throws {
        let sequence = ShakySequence(frames: 25, seed: 7)
        let frames = try GlobalMotionAnalysis.analyze(sequence)
        XCTAssertEqual(frames.count, 25)
        XCTAssertEqual(frames[0].confidence, 1)
        var squaredShift = 0.0, squaredAngle = 0.0
        for i in 1..<frames.count {
            let t = sequence.truth(i)
            squaredShift += (frames[i].tx - t.tx) * (frames[i].tx - t.tx) + (frames[i].ty - t.ty) * (frames[i].ty - t.ty)
            let degrees = (frames[i].rotation - t.rotation) * 180 / .pi
            squaredAngle += degrees * degrees
            XCTAssertEqual(frames[i].scale, 1, accuracy: 0.002)
            XCTAssertGreaterThan(frames[i].confidence, 0.5)
        }
        let n = Double(frames.count - 1)
        let rmsShift = (squaredShift / (2 * n)).squareRoot(), rmsAngle = (squaredAngle / n).squareRoot()
        print("GlobalMotion A1: RMS translation \(rmsShift) px, RMS rotation \(rmsAngle) deg over \(frames.count - 1) frames")
        XCTAssertLessThan(rmsShift, 0.3)
        XCTAssertLessThan(rmsAngle, 0.1)
    }

    func testTranslationsAreReportedInSourcePixelsWhenTheAnalysisPictureIsSmaller() throws {
        struct Halved: GlobalMotionFrameSource {
            let base: ShakySequence
            var frameCount: Int { base.frameCount }
            var sourceWidth: Int { base.width * 2 }
            var sourceHeight: Int { base.height * 2 }
            func luma(at index: Int) throws -> LumaImage { try base.luma(at: index) }
        }
        let base = ShakySequence(frames: 6, seed: 3)
        let frames = try GlobalMotionAnalysis.analyze(Halved(base: base))
        for i in 1..<frames.count {
            XCTAssertEqual(frames[i].tx, base.truth(i).tx * 2, accuracy: 0.8)
            XCTAssertEqual(frames[i].ty, base.truth(i).ty * 2, accuracy: 0.8)
        }
    }

    func testAFlatPictureHasNoMotionAndNoConfidence() throws {
        let flat = LumaImage(width: 320, height: 180, pixels: [Float](repeating: 100, count: 320 * 180))
        let m = GlobalMotionEstimator().estimate(from: flat, to: flat)
        XCTAssertEqual(m.confidence, 0)
        XCTAssertEqual(m.tx, 0)
        XCTAssertEqual(m.scale, 1)
    }

    // A2
    func testA2CancellationBetweenFramesStopsAndWritesNothing() throws {
        let cancellation = MediaCancellation()
        XCTAssertThrowsError(try GlobalMotionAnalysis.analyze(ShakySequence(frames: 20, seed: 1), cancellation: cancellation,
                                                              onProgress: { if $0 > 0.2 { cancellation.cancel() } })) {
            XCTAssertTrue($0 is MediaAbortError)
        }
        try writeClip(frames: 6)
        let before = MediaCancellation(); before.cancel()
        let durable = CountingDurableWrite()
        XCTAssertThrowsError(try GlobalMotionAnalysis.run(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.6,
                                                          durableWrite: durable, cancellation: before)) { XCTAssertTrue($0 is MediaAbortError) }
        XCTAssertTrue(durable.writes.isEmpty)
    }

    func testA2AnalysisRunsOffTheMainThreadAndWritesTheCacheDurably() async throws {
        try writeClip(frames: 8)
        let durable = CountingDurableWrite()
        let threads = LockedBox<[Bool]>([])
        let job = GlobalMotionAnalysis.start(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8,
                                             durableWrite: durable, onProgress: { _ in threads.mutate { $0.append(Thread.isMainThread) } })
        let cache = try await job.value
        XCTAssertFalse(threads.value.isEmpty)
        XCTAssertFalse(threads.value.contains(true), "progress was reported on the main thread")
        XCTAssertEqual(cache.frames.count, 8)
        XCTAssertEqual(durable.writes.count, 1)
        XCTAssertTrue(durable.writes[0].hasSuffix("/.motion-cache/\(cache.key).json"))
        XCTAssertEqual(GlobalMotionAnalysis.loadCache(projectDir: root, key: cache.key), cache)
        // No temporary file is left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: root + "/.motion-cache")
        XCTAssertEqual(files, ["\(cache.key).json"])
        // A second request is answered from the cache: no second write.
        _ = try GlobalMotionAnalysis.run(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8, durableWrite: durable)
        XCTAssertEqual(durable.writes.count, 1)
    }

    func testAJobCanBeCancelledWhileRunning() async throws {
        try writeClip(frames: 8)
        let durable = CountingDurableWrite()
        let job = GlobalMotionAnalysis.start(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8, durableWrite: durable)
        job.cancel()
        do { _ = try await job.value; XCTFail("expected a cancelled job") } catch { XCTAssertTrue(error is MediaAbortError) }
        XCTAssertTrue(durable.writes.isEmpty)
    }

    func testCacheKeyFollowsMediaAndRangeAndBadCachesAreIgnored() throws {
        try writeClip(frames: 8)
        let a = try GlobalMotionAnalysis.cacheKey(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8)
        XCTAssertEqual(a, try GlobalMotionAnalysis.cacheKey(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8))
        XCTAssertNotEqual(a, try GlobalMotionAnalysis.cacheKey(projectDir: root, source: "shake.mov", sourceStart: 0.1, sourceDuration: 0.8))
        XCTAssertNotEqual(a, try GlobalMotionAnalysis.cacheKey(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.5))
        XCTAssertNil(GlobalMotionAnalysis.loadCache(projectDir: root, key: a))
        let durable = TestDurableWrite()
        let cache = try GlobalMotionAnalysis.run(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8, durableWrite: durable)
        let path = root + "/.motion-cache/\(a).json"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(GlobalMotionAnalysis.loadCache(projectDir: root, key: a))
        var future = cache; future.v = 2
        try JSONEncoder().encode(future).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(GlobalMotionAnalysis.loadCache(projectDir: root, key: a))
        // Re-analysis replaces the bad file.
        XCTAssertEqual(try GlobalMotionAnalysis.run(projectDir: root, source: "shake.mov", sourceStart: 0, sourceDuration: 0.8, durableWrite: durable), cache)
        XCTAssertNil(GlobalMotionAnalysis.loadCache(projectDir: root, key: "../escape"))
    }

    // A3: set MPVFX_MOTION_BENCH=1 to print the numbers quoted in the pull request.
    func testA3Throughput() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MPVFX_MOTION_BENCH"] == "1")
        let sequence = ShakySequence(frames: 60, seed: 11)
        let images = try (0..<60).map { try sequence.luma(at: $0) }
        let estimator = GlobalMotionEstimator()
        let start = Date()
        var previous = estimator.pyramid(images[0])
        for i in 1..<60 { let p = estimator.pyramid(images[i]); _ = estimator.estimate(from: previous, to: p); previous = p }
        let seconds = Date().timeIntervalSince(start)
        print("GlobalMotion A3: estimator \(59 / seconds) frames/s at 640x360 (\(seconds / 59 * 1000) ms per frame)")
    }

    private func writeClip(frames count: Int) throws {
        let sequence = ShakySequence(width: 320, height: 180, frames: count, seed: 5, maxShift: 3, maxDegrees: 0.5)
        let rgba = try (0..<count).map { i -> [UInt8] in
            let image = try sequence.luma(at: i)
            return image.pixels.flatMap { v -> [UInt8] in let g = UInt8(max(0, min(255, v))); return [g, g, g, 255] }
        }
        try TestMedia.writeMOV(root + "/shake.mov", frames: rgba, width: 320, height: 180, fps: 10)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
