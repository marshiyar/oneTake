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

/// Pacing and measurement of real-time draws at one draw per frame (issue #94).
///
/// Draw `n` is due on the first instant of frame `n`. The recorded intervals, lateness and repeats show what a slow
/// run suffered from: draw intervals far over one frame (the timer), repeats with on-time draws (sampling phase), or
/// neither with stand-in frames (decode lanes).
public struct DrawCadence {
    public let fps: Double
    /// Seconds from playback start at which each draw began, in order.
    public private(set) var starts: [Double] = []
    /// Seconds each draw began after its deadline (negative: early).
    public private(set) var lateness: [Double] = []
    /// Draws that showed the same frames as the draw before them.
    public private(set) var repeats = 0
    /// Draws that showed different frames from the draw before them (the first draw counts).
    public private(set) var changes = 0
    private var lastFrames: [Int?]?

    /// Nil unless `fps` is a finite rate above zero.
    public init?(fps: Double) {
        guard fps.isFinite, fps > 0 else { return nil }
        self.fps = fps
    }

    /// Seconds from playback start at which draw `index` (0 first) is due: the start of frame `index`.
    public func deadline(_ index: Int) -> Double { Double(max(0, index)) / fps }

    /// Records draw `starts.count`, which began at `start` seconds and showed `frames` (one per layer).
    public mutating func record(start: Double, frames: [Int?]) {
        lateness.append(start - deadline(starts.count))
        starts.append(start)
        if frames == lastFrames {
            repeats += 1
        } else {
            changes += 1
            lastFrames = frames
        }
    }

    /// Seconds between consecutive draw starts.
    public var intervals: [Double] { zip(starts.dropFirst(), starts).map { later, earlier in later - earlier } }

    /// The nearest-rank `fraction` quantile (0...1) of `values`; 0 for none.
    public static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty, fraction.isFinite else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count) * min(1, max(0, fraction))).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    /// The bench's figures in milliseconds: draw interval p95 and max, lateness p95 and max, and the repeat count.
    public func metrics() -> [String: Double] {
        let gaps = intervals
        return [
            "draw_interval_p95_ms": Self.quantile(gaps, 0.95) * 1000,
            "draw_interval_max_ms": Self.quantile(gaps, 1) * 1000,
            "draw_late_p95_ms": Self.quantile(lateness, 0.95) * 1000,
            "draw_late_max_ms": Self.quantile(lateness, 1) * 1000,
            "repeat_draws": Double(repeats)
        ]
    }
}
