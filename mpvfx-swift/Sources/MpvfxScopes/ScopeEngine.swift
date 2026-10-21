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

/// Scope analysis on the CPU: one pass over the frame fills the waveform (Y, R, G, B per column) and the
/// vectorscope; the histograms are the waveform summed over its columns. Rows are split across worker threads, each
/// with its own counters, merged at the end, so the result does not depend on the number of workers. Safe to call
/// from any thread; it never touches the UI.
public enum ScopeEngine {
    public static func analyze(_ frame: ScopeFrame, options: ScopeOptions = ScopeOptions()) -> ScopeAnalysis {
        let plan = ScopePlan(frame: frame, options: options.resolved)
        let workers = max(1, min(plan.options.workers, plan.sampledHeight, plan.sampledWidth * plan.sampledHeight / samplesPerWorker))
        let store = ScopeAccumulators(count: workers, plan: plan)
        defer { store.release() }
        let chunk = (plan.sampledHeight + workers - 1) / workers
        frame.rgba.withUnsafeBufferPointer { px in
            let pixels = ScopePixels(base: px)
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                let lo = w * chunk, hi = min(plan.sampledHeight, lo + chunk)
                guard lo < hi else { return }
                accumulate(plan, pixels, rows: lo..<hi, into: store.block(w))
            }
        }
        return store.merged()
    }

    /// Below this many samples per thread, zeroing and merging another worker's counters costs more than it saves.
    static let samplesPerWorker = 131_072

    /// The smallest step s with ceil(width / s) x ceil(height / s) <= maxSamples (1 when the frame fits).
    public static func samplingStep(width: Int, height: Int, maxSamples: Int) -> Int {
        var s = 1
        while ((width + s - 1) / s) * ((height + s - 1) / s) > max(1, maxSamples) { s += 1 }
        return s
    }

    /// Counts the sampled rows `rows` into `block`. Luma is fixed point (weights sum to 65536, so greys are exact);
    /// the colour difference comes from per-code tables already scaled to vectorscope bins in 1/65536.
    static func accumulate(_ plan: ScopePlan, _ pixels: ScopePixels, rows: Range<Int>, into block: ScopeBlock) {
        let px = pixels.base, step = plan.step, rowBytes = plan.width * 4, stride = step * 4
        let kr = plan.weights.r, kg = plan.weights.g, kb = plan.weights.b
        let radius = plan.radius, side = plan.side
        let wave = block.wave, vec = block.vector
        var samples = 0, outside = 0
        plan.columnStart.withUnsafeBufferPointer { columnStart in plan.tables.withUnsafeBufferPointer { t in
            for sy in rows {
                var o = sy * step * rowBytes
                for sx in 0..<plan.sampledWidth {
                    defer { o += stride }
                    if px[o + 3] == 0 { continue }
                    let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                    let y = (kr * r + kg * g + kb * b + 32768) >> 16, w = columnStart[sx]
                    wave[(w + y) << 2] &+= 1; wave[(w + r) << 2 + 1] &+= 1; wave[(w + g) << 2 + 2] &+= 1; wave[(w + b) << 2 + 3] &+= 1
                    let col = radius + (t[r] + t[256 + g] + t[512 + b] + 32768) >> 16
                    let row = radius - (t[768 + r] + t[1024 + g] + t[1280 + b] + 32768) >> 16
                    if col >= 0, col < side, row >= 0, row < side { vec[row * side + col] &+= 1 } else { outside += 1 }
                    samples += 1
                }
            }
        } }
        block.counters[0] = samples; block.counters[1] = outside
    }
}

/// Everything the pass needs, computed once per frame.
struct ScopePlan: Sendable {
    let options: ScopeOptions
    let width: Int, height: Int, step: Int, sampledWidth: Int, sampledHeight: Int
    let columns: Int, radius: Int, side: Int
    let weights: (r: Int, g: Int, b: Int)
    /// Cb then Cr contribution of each R, G and B code, in vectorscope bins x 65536 (6 x 256 entries).
    let tables: [Int]
    /// Offset of each sampled x's waveform column in the interleaved accumulator (`column x 256`).
    let columnStart: [Int]

    init(frame: ScopeFrame, options: ScopeOptions) {
        self.options = options
        width = frame.width; height = frame.height
        step = ScopeEngine.samplingStep(width: width, height: height, maxSamples: options.maxSamples)
        sampledWidth = (width + step - 1) / step; sampledHeight = (height + step - 1) / step
        columns = min(options.columns, sampledWidth)
        radius = options.vectorRadius; side = 2 * radius + 1
        weights = options.matrix.fixedPoint
        tables = Self.chromaTables(options.matrix, binsPerUnit: 2 * Double(radius) * options.vectorZoom)
        let (w, c, s) = (width, columns, step)
        columnStart = (0..<sampledWidth).map { min(c - 1, $0 * s * c / w) * 256 }
    }

    /// Cb = (B' - Y') / cbDivisor and Cr = (R' - Y') / crDivisor are linear in the codes, so each is a sum of one
    /// table entry per channel.
    static func chromaTables(_ m: ScopeMatrix, binsPerUnit: Double) -> [Int] {
        let cb = [-m.kr, -m.kg, 1 - m.kb].map { $0 / m.cbDivisor }, cr = [1 - m.kr, -m.kg, -m.kb].map { $0 / m.crDivisor }
        return (cb + cr).flatMap { k in (0..<256).map { Int((k * Double($0) / 255 * binsPerUnit * 65536).rounded()) } }
    }

    var waveCount: Int { 4 * columns * 256 }
    var vectorCount: Int { side * side }
    var blockCount: Int { waveCount + vectorCount }
}

/// The frame's bytes, shared read-only by the workers for the duration of `analyze`.
struct ScopePixels: @unchecked Sendable { let base: UnsafeBufferPointer<UInt8> }

/// One worker's counters inside `ScopeAccumulators`. The waveform is interleaved while counting,
/// `[(column x 256 + level) x 4 + plane]`, so one pixel's four increments share a cache line.
struct ScopeBlock {
    let wave: UnsafeMutablePointer<UInt32>, vector: UnsafeMutablePointer<UInt32>
    let counters: UnsafeMutablePointer<Int>
}

/// Zeroed counters for every worker, one allocation each; each worker writes only its own block.
final class ScopeAccumulators: @unchecked Sendable {
    let plan: ScopePlan, count: Int
    let counts: UnsafeMutablePointer<UInt32>, tallies: UnsafeMutablePointer<Int>

    init(count: Int, plan: ScopePlan) {
        self.plan = plan; self.count = count
        counts = .allocate(capacity: count * plan.blockCount); counts.initialize(repeating: 0, count: count * plan.blockCount)
        tallies = .allocate(capacity: count * 2); tallies.initialize(repeating: 0, count: count * 2)
    }

    func block(_ i: Int) -> ScopeBlock {
        let base = counts + i * plan.blockCount
        return ScopeBlock(wave: base, vector: base + plan.waveCount, counters: tallies + i * 2)
    }

    /// Sums every block into the first, then lays the waveform out by plane and derives the histograms.
    func merged() -> ScopeAnalysis {
        for i in 1..<max(1, count) {
            let src = counts + i * plan.blockCount
            for j in 0..<plan.blockCount { counts[j] &+= src[j] }
        }
        var samples = 0, outside = 0
        for i in 0..<count { samples += tallies[i * 2]; outside += tallies[i * 2 + 1] }
        let (waveform, histogram) = planar(block(0).wave)
        return ScopeAnalysis(options: plan.options, sourceWidth: plan.width, sourceHeight: plan.height, step: plan.step,
                             columns: plan.columns, vectorSide: plan.side, samples: samples, vectorOutside: outside,
                             waveform: waveform, histogram: histogram,
                             vectorscope: Array(UnsafeBufferPointer(start: block(0).vector, count: plan.vectorCount)))
    }

    /// The interleaved waveform as `[plane][column][level]`, and its column sums `[plane][level]`.
    func planar(_ wave: UnsafeMutablePointer<UInt32>) -> ([UInt32], [UInt32]) {
        let cells = plan.columns * 256
        var waveform = [UInt32](repeating: 0, count: 4 * cells), histogram = [UInt32](repeating: 0, count: 4 * 256)
        waveform.withUnsafeMutableBufferPointer { out in
            histogram.withUnsafeMutableBufferPointer { hist in
                for cell in 0..<cells {
                    let level = cell & 255
                    for p in 0..<4 {
                        let v = wave[cell << 2 + p]
                        out[p * cells + cell] = v; hist[p << 8 + level] &+= v
                    }
                }
            }
        }
        return (waveform, histogram)
    }

    func release() { counts.deallocate(); tallies.deallocate() }
}
