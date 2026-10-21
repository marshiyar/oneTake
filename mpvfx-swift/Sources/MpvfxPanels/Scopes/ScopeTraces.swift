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
import MpvfxCanvas
import MpvfxScopes
import MpvfxTheme

/// A trace bitmap's size in device pixels.
public struct PixelSize: Hashable, Sendable {
    public let width: Int, height: Int
    public init(_ width: Int, _ height: Int) { self.width = max(1, width); self.height = max(1, height) }
}

/// Trace bitmaps from an analysis, made at the size they are drawn (device pixels), so nothing is scaled after:
/// each pixel sums the bins under it. Its brightness is `1 - exp(-gain x count / ref)`, where `ref` is the count a bin
/// holds when a column's samples (the frame's, for the vectorscope) spread evenly over `spread` levels: the trace
/// keeps its brightness from frame to frame (nothing is scaled to the frame's own peak), sparse detail shows, and a
/// flat colour saturates. Bitmaps are opaque black where nothing landed; the graticule is drawn over them.
public enum ScopeTraces {
    static let waveformSpread = 100.0, vectorSpread = 2000.0

    /// The waveform of `planes` at `size` (level 255 on the top row), each plane in its colour, added.
    public static func waveform(_ a: ScopeAnalysis, planes: [(ScopeChannel, ThemeColor)], gain: Double, size: PixelSize) -> CanvasImage {
        var bitmap = Bitmap(width: size.width, height: size.height)
        let grid = Resampler(columns: a.columns, rows: 256, size: size)
        let ref = max(1, Double(a.samples) / Double(max(1, a.columns)) / waveformSpread)
        for (channel, colour) in planes {
            bitmap.add(colour, columns: 0..<size.width) { x, y in
                let n = grid.sum(x, y) { c, row in a.waveform(channel, column: c, level: 255 - row) }
                return brightness(n, gain: gain, ref: ref * Double(grid.columns[x].count))
            }
        }
        return bitmap.image
    }

    /// The R, G and B waveforms side by side at `size`, a black gap of about 1 % of the width between them.
    public static func parade(_ a: ScopeAnalysis, colours: [ThemeColor], gain: Double, size: PixelSize) -> CanvasImage {
        var bitmap = Bitmap(width: size.width, height: size.height)
        let lanes = paradeLanes(width: size.width)
        let ref = max(1, Double(a.samples) / Double(max(1, a.columns)) / waveformSpread)
        for (i, channel) in [ScopeChannel.red, .green, .blue].enumerated() {
            let lane = lanes[i], grid = Resampler(columns: a.columns, rows: 256, size: PixelSize(lane.count, size.height))
            bitmap.add(colours[i], columns: lane) { x, y in
                let n = grid.sum(x - lane.lowerBound, y) { c, row in a.waveform(channel, column: c, level: 255 - row) }
                return brightness(n, gain: gain, ref: ref * Double(grid.columns[x - lane.lowerBound].count))
            }
        }
        return bitmap.image
    }

    /// The pixel columns of the three parade lanes in a bitmap `width` wide.
    public static func paradeLanes(width: Int) -> [Range<Int>] {
        let gap = max(2, width / 96), lane = max(1, (width - 2 * gap) / 3)
        return (0..<3).map { i in i * (lane + gap)..<min(width, i * (lane + gap) + lane) }
    }

    /// The vectorscope grid at `size` (+Cr on the top row) in `colour`.
    public static func vectorscope(_ a: ScopeAnalysis, colour: ThemeColor, gain: Double, size: PixelSize) -> CanvasImage {
        var bitmap = Bitmap(width: size.width, height: size.height)
        let grid = Resampler(columns: a.vectorSide, rows: a.vectorSide, size: size)
        let ref = max(1, Double(a.samples) / vectorSpread)
        bitmap.add(colour, columns: 0..<size.width) { x, y in
            brightness(grid.sum(x, y) { c, row in a.vector(row: row, col: c) }, gain: gain, ref: ref)
        }
        return bitmap.image
    }

    static func brightness(_ count: UInt32, gain: Double, ref: Double) -> Double {
        count == 0 ? 0 : 1 - exp(-gain * Double(count) / ref)
    }

    /// Which grid cells each output pixel covers: every cell belongs to exactly one pixel when the grid is larger
    /// than the bitmap, and each pixel reads the cell under it when the grid is smaller.
    struct Resampler {
        let columns: [Range<Int>], rows: [Range<Int>]

        init(columns gw: Int, rows gh: Int, size: PixelSize) {
            columns = Self.spans(gw, size.width); rows = Self.spans(gh, size.height)
        }

        static func spans(_ cells: Int, _ pixels: Int) -> [Range<Int>] {
            (0..<pixels).map { p in
                let lo = p * cells / pixels
                return lo..<max(lo + 1, min(cells, (p + 1) * cells / pixels))
            }
        }

        /// The sum of `cell(column, row)` over the cells under pixel (x, y).
        func sum(_ x: Int, _ y: Int, _ cell: (Int, Int) -> UInt32) -> UInt32 {
            var n: UInt32 = 0
            for c in columns[x] { for r in rows[y] { n &+= cell(c, r) } }
            return n
        }
    }

    /// An opaque black RGBA8 bitmap that traces are added into.
    struct Bitmap {
        let width: Int, height: Int
        var px: [UInt8]

        init(width: Int, height: Int) {
            self.width = width; self.height = height
            px = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        }

        var image: CanvasImage { CanvasImage(width: width, height: height, rgba: px) }

        /// Adds `colour` x `level(x, y)` to every pixel of `columns`, clamped to 255.
        mutating func add(_ colour: ThemeColor, columns: Range<Int>, _ level: (Int, Int) -> Double) {
            let rgb = [colour.r, colour.g, colour.b].map { $0 * 255 }, w = width
            for y in 0..<height {
                for x in columns {
                    let v = level(x, y)
                    if v <= 0 { continue }
                    let o = (y * w + x) * 4
                    for c in 0..<3 { px[o + c] = UInt8(min(255, Double(px[o + c]) + rgb[c] * v).rounded()) }
                }
            }
        }
    }
}
