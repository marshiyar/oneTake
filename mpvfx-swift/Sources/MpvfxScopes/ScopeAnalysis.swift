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

/// The planes the waveform and histogram keep, in storage order.
public enum ScopeChannel: Int, CaseIterable, Sendable { case luma, red, green, blue }

/// Counts of one analysed frame. Level 0 is black and 255 is the 8-bit peak; every sample counts 1.
///
/// Storage: `waveform[((plane * columns) + column) * 256 + level]`, `histogram[plane * 256 + level]`,
/// `vectorscope[row * vectorSide + col]` with row 0 at +Cr (top) and col 0 at -Cb (left).
public struct ScopeAnalysis: Sendable, Equatable {
    public static let levels = 256

    /// The options the frame was analysed with, after clamping.
    public let options: ScopeOptions
    public let sourceWidth: Int, sourceHeight: Int
    /// Every `step`-th pixel of every `step`-th row was read (1 = every pixel).
    public let step: Int
    public let columns: Int
    public let vectorSide: Int
    /// Pixels counted (alpha above 0, on the sampling grid).
    public let samples: Int
    /// Samples whose chroma fell outside the zoomed vectorscope grid.
    public let vectorOutside: Int
    public let waveform: [UInt32]
    public let histogram: [UInt32]
    public let vectorscope: [UInt32]

    public func waveform(_ channel: ScopeChannel, column: Int, level: Int) -> UInt32 {
        waveform[(channel.rawValue * columns + column) * Self.levels + level]
    }

    public func histogram(_ channel: ScopeChannel, level: Int) -> UInt32 {
        histogram[channel.rawValue * Self.levels + level]
    }

    public func vector(row: Int, col: Int) -> UInt32 { vectorscope[row * vectorSide + col] }

    /// Samples at level 0 (crushed) and at level 255 (clipped) in `channel`.
    public func clipped(_ channel: ScopeChannel) -> (low: Int, high: Int) {
        (Int(histogram(channel, level: 0)), Int(histogram(channel, level: Self.levels - 1)))
    }

    /// Whether `column` holds a sample at level 0 / level 255 in `channel` (the clipping marks of the waveform).
    public func columnClips(_ channel: ScopeChannel, column: Int) -> (low: Bool, high: Bool) {
        (waveform(channel, column: column, level: 0) > 0, waveform(channel, column: column, level: Self.levels - 1) > 0)
    }

    /// The vectorscope bin a colour difference lands in, by the same rounding the analysis uses; nil outside the grid.
    public func vectorBin(cb: Double, cr: Double) -> (row: Int, col: Int)? {
        ScopeGeometry.vectorBin(cb: cb, cr: cr, radius: options.vectorRadius, zoom: options.vectorZoom)
    }
}

/// Where values land on a scope; one place for the analysis, the tests and the graticule.
public enum ScopeGeometry {
    /// Vectorscope bin of (Cb, Cr): `col = r + round(2 r zoom Cb)`, `row = r - round(2 r zoom Cr)`.
    public static func vectorBin(cb: Double, cr: Double, radius: Int, zoom: Double) -> (row: Int, col: Int)? {
        let k = 2 * Double(radius) * zoom
        let col = radius + Int((cb * k).rounded()), row = radius - Int((cr * k).rounded())
        let side = 2 * radius + 1
        guard (0..<side).contains(col), (0..<side).contains(row) else { return nil }
        return (row, col)
    }

    /// Position of (Cb, Cr) in a unit square (0,0 top left), zoomed about the centre; outside 0...1 when off-scale.
    public static func vectorPoint(cb: Double, cr: Double, zoom: Double) -> (x: Double, y: Double) {
        (0.5 + cb * zoom, 0.5 - cr * zoom)
    }
}
