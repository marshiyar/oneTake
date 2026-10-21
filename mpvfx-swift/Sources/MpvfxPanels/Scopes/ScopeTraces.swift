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

/// Trace bitmaps from an analysis. A bin's brightness is `1 - exp(-gain x count / ref)`, where `ref` is the count a
/// bin holds when a column's samples (the frame's, for the vectorscope) spread evenly over `spread` levels: the
/// trace keeps its brightness from frame to frame (nothing is scaled to the frame's own peak), sparse detail shows,
/// and a flat colour saturates. Bitmaps are opaque black where nothing landed; the graticule is drawn over them.
public enum ScopeTraces {
    static let waveformSpread = 100.0, vectorSpread = 2000.0

    /// The waveform of `planes` (columns wide, 256 tall, level 255 on the top row), each plane in its colour, added.
    public static func waveform(_ a: ScopeAnalysis, planes: [(ScopeChannel, ThemeColor)], gain: Double) -> CanvasImage {
        var bitmap = Bitmap(width: a.columns, height: 256)
        let ref = max(1, Double(a.samples) / Double(max(1, a.columns)) / waveformSpread)
        for (channel, colour) in planes {
            bitmap.add(colour, columns: 0..<a.columns) { x, y in
                brightness(a.waveform(channel, column: x, level: 255 - y), gain: gain, ref: ref)
            }
        }
        return bitmap.image
    }

    /// The R, G and B waveforms side by side, a black gap of 1/32 of a lane between them.
    public static func parade(_ a: ScopeAnalysis, colours: [ThemeColor], gain: Double) -> CanvasImage {
        let lane = a.columns, gap = max(2, lane / 32), width = 3 * lane + 2 * gap
        var bitmap = Bitmap(width: width, height: 256)
        let ref = max(1, Double(a.samples) / Double(max(1, a.columns)) / waveformSpread)
        for (i, channel) in [ScopeChannel.red, .green, .blue].enumerated() {
            let x0 = i * (lane + gap)
            bitmap.add(colours[i], columns: x0..<x0 + lane) { x, y in
                brightness(a.waveform(channel, column: x - x0, level: 255 - y), gain: gain, ref: ref)
            }
        }
        return bitmap.image
    }

    /// The vectorscope grid (side x side, +Cr on the top row) in `colour`.
    public static func vectorscope(_ a: ScopeAnalysis, colour: ThemeColor, gain: Double) -> CanvasImage {
        let side = a.vectorSide
        var bitmap = Bitmap(width: side, height: side)
        let ref = max(1, Double(a.samples) / vectorSpread)
        bitmap.add(colour, columns: 0..<side) { x, y in brightness(a.vector(row: y, col: x), gain: gain, ref: ref) }
        return bitmap.image
    }

    static func brightness(_ count: UInt32, gain: Double, ref: Double) -> Double {
        count == 0 ? 0 : 1 - exp(-gain * Double(count) / ref)
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
